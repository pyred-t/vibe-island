/**
 * Claude Island Windows — Renderer Process
 * Handles UI logic for the popup panel
 */

// ─── State ──────────────────────────────────────────────────────

let currentView = 'sessions';
let sessions = [];
let config = {};
let machines = [];       // configStore.machines
let sshHosts = [];       // parsed SSH config hosts (for import dialog)
let remoteStatuses = {}; // { sshAlias: status }
let authPendingId = null;

// ─── Constants ──────────────────────────────────────────────────

const PHASE_LABELS = {
  idle: 'Idle',
  processing: 'Processing',
  waiting_for_input: 'Ready',
  waiting_for_approval: 'Needs Approval',
  compacting: 'Compacting',
  ended: 'Ended',
};

const AGENT_NAMES = {
  claude: 'Claude Code',
  codex: 'Codex',
  gemini: 'Gemini CLI',
};

const STATUS_LABELS = {
  idle:             { label: 'Idle',          cls: 'status-idle' },
  connecting:       { label: 'Connecting…',   cls: 'status-connecting' },
  installing_hooks: { label: 'Installing…',   cls: 'status-connecting' },
  connected:        { label: 'Connected',     cls: 'status-connected' },
  auth_required:    { label: 'Auth Required', cls: 'status-error' },
  port_conflict:    { label: 'Port Conflict', cls: 'status-error' },
  error:            { label: 'Error',         cls: 'status-error' },
  disconnecting:    { label: 'Disconnecting', cls: 'status-idle' },
};

// ─── Init ───────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', async () => {
  sessions = await window.claudeIsland.getSessions();
  config = await window.claudeIsland.getConfig();
  machines = await window.claudeIsland.getMachines();
  sshHosts = await window.claudeIsland.getSshHosts();
  remoteStatuses = await window.claudeIsland.getRemoteStatuses();

  renderSessions();
  updateStatusDot();
  renderSettings();

  // Live updates
  window.claudeIsland.onSessionsChanged(s => { sessions = s; renderSessions(); updateStatusDot(); });
  window.claudeIsland.onMachinesChanged(m => { machines = m; renderMachines(); });
  window.claudeIsland.onRemoteStatusChanged(({ alias, status }) => {
    remoteStatuses[alias] = status;
    renderMachines();
  });
  window.claudeIsland.onRemoteAuthRequired(({ alias }) => {
    const m = machines.find(x => x.sshAlias === alias);
    if (m) showAuthDialog(m.id);
  });
  window.claudeIsland.onSshHostsChanged(hosts => { sshHosts = hosts; renderImportList(); });

  // SSH config path display
  const sshPath = await window.claudeIsland.getSshConfigPath();
  const display = document.getElementById('sshConfigPathDisplay');
  if (display) display.textContent = sshPath || 'auto-detect';

  // Header buttons
  document.getElementById('settingsBtn').addEventListener('click', toggleSettings);
  document.getElementById('closeBtn').addEventListener('click', () => window.claudeIsland.hideWindow());

  // SSH config browse / reset
  document.getElementById('sshConfigBrowseBtn')?.addEventListener('click', async () => {
    const p = await window.claudeIsland.selectSshConfigFile();
    if (p) {
      document.getElementById('sshConfigPathDisplay').textContent = p;
      sshHosts = await window.claudeIsland.getSshHosts();
      renderImportList();
    }
  });
  document.getElementById('sshConfigResetBtn')?.addEventListener('click', async () => {
    await window.claudeIsland.setConfig('sshConfigPath', null);
    const p = await window.claudeIsland.getSshConfigPath();
    document.getElementById('sshConfigPathDisplay').textContent = p || 'auto-detect';
    sshHosts = await window.claudeIsland.getSshHosts();
    renderImportList();
  });

  // Import SSH host dialog
  document.getElementById('importSshHostBtn')?.addEventListener('click', () => {
    renderImportList();
    document.getElementById('importDialog').classList.remove('hidden');
  });
  document.getElementById('addCustomHostBtn')?.addEventListener('click', async () => {
    const alias = prompt('Enter SSH host alias (e.g. user@hostname or an alias from SSH config):');
    if (alias && alias.trim()) {
      await window.claudeIsland.addSSHMachine(alias.trim(), { claudePaths: ['~/.claude'], port: 51515, autoConnect: false });
      machines = await window.claudeIsland.getMachines();
      renderMachines();
    }
  });
  document.getElementById('importDialogCancelBtn')?.addEventListener('click', () => {
    document.getElementById('importDialog').classList.add('hidden');
  });

  // Port input
  const portInput = document.getElementById('portInput');
  portInput.value = config.port || 51515;
  portInput.addEventListener('change', () => {
    const port = parseInt(portInput.value);
    if (port >= 1024 && port <= 65535) window.claudeIsland.setConfig('port', port);
  });

  // Notification toggle
  const notifToggle = document.getElementById('notifToggle');
  notifToggle.checked = config.enableNotifications !== false;
  notifToggle.addEventListener('change', () => {
    window.claudeIsland.setConfig('enableNotifications', notifToggle.checked);
  });

  // Auth dialog buttons
  document.getElementById('authDialogCopyBtn')?.addEventListener('click', () => {
    navigator.clipboard.writeText('ssh-add').catch(() => {});
  });
  document.getElementById('authDialogRetryBtn')?.addEventListener('click', async () => {
    const id = authPendingId;
    hideAuthDialog();
    if (id) await window.claudeIsland.retryMachine(id);
  });
  document.getElementById('authDialogDismissBtn')?.addEventListener('click', hideAuthDialog);
});

// ─── View ────────────────────────────────────────────────────────

function toggleSettings() {
  const sv = document.getElementById('sessionsView');
  const stv = document.getElementById('settingsView');
  if (currentView === 'sessions') {
    sv.classList.add('hidden');
    stv.classList.remove('hidden');
    currentView = 'settings';
    renderSettings();
  } else {
    stv.classList.add('hidden');
    sv.classList.remove('hidden');
    currentView = 'sessions';
  }
}

// ─── Sessions ───────────────────────────────────────────────────

function renderSessions() {
  const container = document.getElementById('sessionsList');
  const emptyState = document.getElementById('emptyState');

  const sorted = [...sessions].sort((a, b) => {
    const order = { waiting_for_approval: 0, waiting_for_input: 1, processing: 2, compacting: 3, idle: 4, ended: 5 };
    const d = (order[a.phase] ?? 6) - (order[b.phase] ?? 6);
    return d !== 0 ? d : new Date(b.lastEventAt) - new Date(a.lastEventAt);
  });

  const nonEnded = sorted.filter(s => s.phase !== 'ended');
  const ended = sorted.filter(s => s.phase === 'ended');
  const display = [...nonEnded, ...ended].slice(0, 10);

  if (display.length === 0) {
    emptyState.style.display = 'flex';
    Array.from(container.children).forEach(c => { if (c.id !== 'emptyState') c.remove(); });
    return;
  }
  emptyState.style.display = 'none';

  const existingCards = Array.from(container.querySelectorAll('.session-card'));
  existingCards.forEach(card => {
    if (!display.find(s => s.sessionId === card.dataset.sessionId)) card.remove();
  });
  display.forEach(session => {
    const existing = container.querySelector(`[data-session-id="${session.sessionId}"]`);
    const newCard = createSessionCard(session);
    if (existing) container.replaceChild(newCard, existing);
    else container.insertBefore(newCard, container.firstChild);
  });
}

function updateStatusDot() {
  const dot = document.getElementById('statusDot');
  const active = sessions.filter(s => s.phase !== 'ended');
  const hasApproval = active.some(s => s.phase === 'waiting_for_approval');
  const hasActive = active.some(s => ['processing', 'compacting'].includes(s.phase));
  dot.className = 'logo-dot';
  if (hasApproval) dot.classList.add('waiting');
  else if (hasActive) dot.classList.add('active');
  else if (active.length > 0) dot.classList.add('idle-sessions');
}

function createSessionCard(session) {
  const card = document.createElement('div');
  card.className = `session-card ${session.phase}`;
  card.dataset.sessionId = session.sessionId;

  const agentName = AGENT_NAMES[session.agentId] || session.agentId;
  const phaseLabel = PHASE_LABELS[session.phase] || session.phase;
  const cwd = shortenPath(session.cwd);
  const timeAgo = formatTimeAgo(session.lastEventAt);

  const hostBadge = session.hostname && session.isRemote
    ? `<div class="session-host">🌐 ${escapeHtml(session.hostname)}</div>` : '';

  let toolInfo = '';
  if (session.lastTool && session.phase !== 'ended') {
    toolInfo = `<div class="session-tool">
      <span class="session-tool-icon">⚙</span>
      <span class="session-tool-name">${escapeHtml(session.lastTool)}</span>
      ${session.lastToolInput?.file_path ? `<span style="color:var(--text-muted);font-size:10px;margin-left:2px">${escapeHtml(session.lastToolInput.file_path)}</span>` : ''}
    </div>`;
  }

  let permissionSection = '';
  if (session.phase === 'waiting_for_approval' && session.activePermission) {
    const p = session.activePermission;
    const preview = p.toolInput ? truncate(JSON.stringify(p.toolInput), 120) : '';
    permissionSection = `
      <div class="permission-tool-info">
        <div>Allow <span class="permission-tool-name">${escapeHtml(p.toolName)}</span>?</div>
        ${preview ? `<div class="permission-tool-input">${escapeHtml(preview)}</div>` : ''}
      </div>
      <div class="permission-actions">
        <button class="btn btn-success btn-sm" onclick="handleApprove('${session.sessionId}','${p.toolUseId}', this)">Allow</button>
        <button class="btn btn-warning btn-sm" onclick="handleAlwaysAllow('${session.sessionId}','${p.toolUseId}', this)">Always</button>
        <button class="btn btn-danger btn-sm" onclick="handleDeny('${session.sessionId}','${p.toolUseId}', this)">Deny</button>
      </div>`;
  }

  let interactionSection = '';
  if (session.phase === 'waiting_for_input' && session.activeInteraction) {
    const q = session.activeInteraction.toolInput?.question || 'Input required';
    interactionSection = `
      <div class="interaction-section">
        <div class="interaction-question">${escapeHtml(q)}</div>
        <div class="interaction-input-row">
          <input type="text" class="interaction-input" id="interaction-${session.sessionId}"
            onkeydown="if(event.key==='Enter')handleInteraction('${session.sessionId}','${session.activeInteraction.toolUseId}', event.target.nextElementSibling)">
          <button class="btn btn-primary btn-sm" onclick="handleInteraction('${session.sessionId}','${session.activeInteraction.toolUseId}', this)">Send</button>
        </div>
      </div>`;
  }

  const archiveBtn = session.phase === 'ended'
    ? `<button class="btn btn-ghost session-archive-btn" onclick="handleArchive('${session.sessionId}')" title="Remove">✕</button>`
    : '';

  card.innerHTML = `
    ${archiveBtn}
    <div class="session-header">
      <div class="session-agent">
        <div class="session-agent-dot ${session.phase}"></div>
        <span class="session-agent-name">${escapeHtml(agentName)}</span>
      </div>
      <span class="session-phase-label ${session.phase}">${phaseLabel}</span>
    </div>
    ${hostBadge}
    <div class="session-cwd" title="${escapeHtml(session.cwd || '')}">${escapeHtml(cwd)}</div>
    ${toolInfo}${permissionSection}${interactionSection}
    <div class="session-time">${timeAgo}</div>`;

  return card;
}

// ─── Session Actions ────────────────────────────────────────────

async function handleApprove(sessionId, toolUseId, btn) {
  if (btn) { btn.disabled = true; btn.innerText = 'Allowing...'; }
  await window.claudeIsland.approvePermission(sessionId, toolUseId);
}
async function handleAlwaysAllow(sessionId, toolUseId, btn) {
  if (btn) { btn.disabled = true; btn.innerText = 'Allowing...'; }
  await window.claudeIsland.alwaysAllowPermission(sessionId, toolUseId);
}
async function handleDeny(sessionId, toolUseId, btn) {
  if (btn) { btn.disabled = true; btn.innerText = 'Denying...'; }
  await window.claudeIsland.denyPermission(sessionId, toolUseId, 'Denied by user');
}
async function handleInteraction(sessionId, toolUseId, btn) {
  const input = document.getElementById(`interaction-${sessionId}`);
  if (!input || !input.value.trim()) return;
  const val = input.value.trim();
  if (btn) { btn.disabled = true; btn.innerText = 'Sending...'; }
  input.disabled = true;
  await window.claudeIsland.submitInteraction(sessionId, toolUseId, { question: val });
}
async function handleArchive(sessionId) {
  await window.claudeIsland.archiveSession(sessionId);
}

// ─── Settings ───────────────────────────────────────────────────

function renderSettings() {
  renderMachines();
  document.getElementById('portInput').value = config.port || 51515;
  document.getElementById('notifToggle').checked = config.enableNotifications !== false;
}

// ─── Machine Cards ───────────────────────────────────────────────

const _hookStatusCache = {};

function renderMachines() {
  const container = document.getElementById('machinesList');
  if (!container) return;
  container.innerHTML = machines.map(renderMachineCard).join('');
}

function renderMachineCard(machine) {
  const isLocal = machine.type === 'local';
  const icon = isLocal ? '🖥' : '🌐';
  const status = isLocal ? null : (remoteStatuses[machine.sshAlias] || 'idle');
  const { label: statusLabel, cls: statusCls } = STATUS_LABELS[status] || STATUS_LABELS.idle;

  const headerRight = isLocal
    ? '<span class="machine-tag">local</span>'
    : `<span class="remote-status-dot ${statusCls}"></span><span class="remote-status-label ${statusCls}">${statusLabel}</span>`;

  const pathsHtml = machine.claudePaths.map(p => {
    const hookBadge = isLocal ? getMachinePathHookBadge(machine.id, p) : '<span class="hook-badge installed" title="Hooks are automatically synced to this remote path on connect">Auto Synced ✓</span>';
    const encodedP = encodeURIComponent(p);
    return `<div class="machine-path-row">
      <span class="machine-path-text" title="${escapeHtml(p)}">${shortenPath(p)}</span>
      ${hookBadge}
      <button class="btn btn-ghost btn-xs machine-path-remove" onclick="machineRemovePath('${machine.id}', '${encodedP}')" title="Remove">✕</button>
    </div>`;
  }).join('');

  let actionsHtml = '';
  if (isLocal) {
    actionsHtml = `
      <button class="btn btn-outline btn-sm" onclick="machineAddPath('${machine.id}')">+ Add Path</button>
      <button class="btn btn-primary btn-sm" onclick="machineInstallHooks('${machine.id}')">Install Hooks</button>`;
  } else {
    const connected = status === 'connected';
    const errored = ['auth_required', 'error', 'port_conflict'].includes(status);
    const connectBtn = connected
      ? `<button class="btn btn-ghost btn-sm" onclick="machineDisconnect('${machine.id}')">Disconnect</button>`
      : errored
        ? `<button class="btn btn-outline btn-sm" onclick="machineRetry('${machine.id}')">Retry</button>`
        : `<button class="btn btn-primary btn-sm" onclick="machineConnect('${machine.id}')">Connect</button>`;
    actionsHtml = `${connectBtn}
      <button class="btn btn-ghost btn-sm" onclick="machineInstallHooks('${machine.id}', this)" ${!connected ? 'disabled title="Connect first"' : ''}>Force Sync</button>
      <button class="btn btn-ghost btn-sm" onclick="machineAddRemotePath('${machine.id}')">+ Path</button>
      <button class="btn btn-ghost btn-sm machine-remove-btn" onclick="machineRemove('${machine.id}')">Remove</button>`;
  }

  return `<div class="machine-card" id="machine-${machine.id}">
    <div class="machine-header">
      <div class="machine-title"><span class="machine-icon">${icon}</span><span class="machine-label">${escapeHtml(machine.label)}</span></div>
      <div class="machine-status">${headerRight}</div>
    </div>
    <div class="machine-paths">${pathsHtml || '<span class="settings-hint" style="margin:0">No paths configured</span>'}</div>
    <div class="machine-actions">${actionsHtml}</div>
  </div>`;
}

function getMachinePathHookBadge(machineId, p) {
  const key = `${machineId}:${p}`;
  const s = _hookStatusCache[key];
  if (!s) {
    window.claudeIsland.getMachineHookStatus(machineId).then(statuses => {
      for (const entry of statuses) _hookStatusCache[`${machineId}:${entry.path}`] = entry;
      renderMachines();
    }).catch(() => {});
    return '';
  }
  if (!s.exists) return '<span class="hook-badge not-found">Not Found</span>';
  if (s.installed) return '<span class="hook-badge installed">Hooks ✓</span>';
  return '<span class="hook-badge not-installed">Hooks ✗</span>';
}

// ─── Machine Actions ─────────────────────────────────────────────

async function machineAddPath(machineId) {
  const selected = await window.claudeIsland.selectDirectory();
  if (selected) {
    await window.claudeIsland.addClaudePathToMachine(machineId, selected);
    machines = await window.claudeIsland.getMachines();
    renderMachines();
  }
}

async function machineAddRemotePath(machineId) {
  const p = prompt('Enter remote Claude config path (e.g. ~/.claude):');
  if (p?.trim()) {
    await window.claudeIsland.addClaudePathToMachine(machineId, p.trim());
    machines = await window.claudeIsland.getMachines();
    renderMachines();
  }
}

async function machineRemovePath(machineId, encodedPath) {
  const p = decodeURIComponent(encodedPath);
  await window.claudeIsland.removeClaudePathFromMachine(machineId, p);
  machines = await window.claudeIsland.getMachines();
  renderMachines();
}

async function machineInstallHooks(machineId, btnArg) {
  const btn = btnArg || event?.target;
  const originalText = btn?.textContent || 'Install Hooks';
  if (btn) { btn.textContent = 'Syncing…'; btn.disabled = true; }
  try {
    const res = await window.claudeIsland.installHooksForMachine(machineId);
    if (res?.error) alert('Sync failed:\n' + res.error);
    const machine = machines.find(m => m.id === machineId);
    if (machine) machine.claudePaths.forEach(p => delete _hookStatusCache[`${machineId}:${p}`]);
    renderMachines();
  } finally {
    if (btn) { btn.textContent = originalText; btn.disabled = false; }
  }
}

async function machineConnect(machineId) {
  const machine = machines.find(m => m.id === machineId);
  if (machine) remoteStatuses[machine.sshAlias] = 'connecting';
  renderMachines();
  await window.claudeIsland.connectMachine(machineId);
}

async function machineDisconnect(machineId) {
  await window.claudeIsland.disconnectMachine(machineId);
  const machine = machines.find(m => m.id === machineId);
  if (machine) remoteStatuses[machine.sshAlias] = 'idle';
  renderMachines();
}

async function machineRetry(machineId) {
  const machine = machines.find(m => m.id === machineId);
  if (machine) remoteStatuses[machine.sshAlias] = 'connecting';
  renderMachines();
  await window.claudeIsland.retryMachine(machineId);
}

async function machineRemove(machineId) {
  await window.claudeIsland.removeMachine(machineId);
  machines = await window.claudeIsland.getMachines();
  renderMachines();
}

// ─── Import Dialog ───────────────────────────────────────────────

function renderImportList() {
  const container = document.getElementById('importHostList');
  if (!container) return;
  const existing = new Set(machines.filter(m => m.type === 'ssh').map(m => m.sshAlias));
  const available = sshHosts.filter(h => !existing.has(h.alias));
  if (available.length === 0) {
    container.innerHTML = '<p class="settings-hint">All SSH config hosts are already added.</p>';
    return;
  }
  container.innerHTML = available.map(h => `
    <div class="remote-host-row" style="cursor:pointer" onclick="importHost('${escapeHtml(h.alias)}')">
      <div class="remote-host-info">
        <span class="remote-status-dot status-idle"></span>
        <span class="remote-host-alias">${escapeHtml(h.alias)}</span>
        <span class="settings-hint" style="margin:0">${escapeHtml(h.hostname)}</span>
      </div>
      <button class="btn btn-primary btn-sm">Add</button>
    </div>`).join('');
}

async function importHost(alias) {
  document.getElementById('importDialog').classList.add('hidden');
  await window.claudeIsland.addSSHMachine(alias, { claudePaths: ['~/.claude'], port: 51515, autoConnect: false });
  machines = await window.claudeIsland.getMachines();
  renderMachines();
}

// ─── Auth Dialog ────────────────────────────────────────────────

function showAuthDialog(machineId) {
  authPendingId = machineId;
  const machine = machines.find(m => m.id === machineId);
  document.getElementById('authDialogTitle').textContent = `${machine?.label || machineId} — Authentication Required`;
  document.getElementById('authDialog').classList.remove('hidden');
}

function hideAuthDialog() {
  authPendingId = null;
  document.getElementById('authDialog').classList.add('hidden');
}

// ─── Utilities ──────────────────────────────────────────────────

function shortenPath(p) {
  if (!p) return '';
  const parts = p.replace(/\\/g, '/').split('/').filter(Boolean);
  return parts.length <= 3 ? parts.join('/') : '…/' + parts.slice(-3).join('/');
}

function escapeHtml(str) {
  if (!str) return '';
  const map = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' };
  return String(str).replace(/[&<>"']/g, m => map[m]);
}

function truncate(str, maxLen) {
  if (!str) return '';
  return str.length > maxLen ? str.substring(0, maxLen) + '…' : str;
}

function formatTimeAgo(dateStr) {
  if (!dateStr) return '';
  const seconds = Math.floor((Date.now() - new Date(dateStr).getTime()) / 1000);
  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.floor(minutes / 60)}h ago`;
}
