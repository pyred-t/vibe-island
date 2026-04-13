/**
 * Claude Island Windows — Renderer Process
 * Handles UI logic for the popup panel
 */

// ─── State ──────────────────────────────────────────────────────

let currentView = 'sessions';
let sessions = [];
let config = {};
let machines = [];
let sshHosts = [];
let remoteStatuses = {};
let authPendingId = null;
let _prevSessions = []; // for notification diffing

// ─── Constants ──────────────────────────────────────────────────

const STATUS_LABELS_MAP = {
  idle:             { cls: 'status-idle' },
  connecting:       { cls: 'status-connecting' },
  installing_hooks: { cls: 'status-connecting' },
  connected:        { cls: 'status-connected' },
  auth_required:    { cls: 'status-error' },
  port_conflict:    { cls: 'status-error' },
  error:            { cls: 'status-error' },
  disconnecting:    { cls: 'status-idle' },
};

// ─── Init ───────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', async () => {
  // Apply saved language
  const savedLang = localStorage.getItem('ci_lang') || 'zh';
  i18n.setLang(savedLang);

  // Init notification module
  InAppNotifications.init();

  // Load config & data
  sessions = await window.claudeIsland.getSessions();
  config = await window.claudeIsland.getConfig();
  // Apply saved opacity
  if (config.opacity != null) {
    document.documentElement.style.setProperty('--bg-primary', `rgba(18,18,24,${config.opacity})`);
  }
  machines = await window.claudeIsland.getMachines();
  sshHosts = await window.claudeIsland.getSshHosts();
  remoteStatuses = await window.claudeIsland.getRemoteStatuses();

  // Apply notification settings from config
  const notifMode = config.notifMode || 'inapp';
  const notifSound = config.notifSound || 'pop';
  InAppNotifications.setMode(notifMode);
  InAppNotifications.setSound(notifSound);

  // Init crab icon in header
  _initCrabIcon();

  // Render
  applyI18n();
  renderSessions();
  updateCrabStatus();
  renderSettings();

  // Live updates
  window.claudeIsland.onSessionsChanged(s => {
    _prevSessions = sessions;
    sessions = s;
    renderSessions();
    updateCrabStatus();
    _checkNotifications(_prevSessions, sessions);
  });
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
  const pinBtn = document.getElementById('pinBtn');
  if (pinBtn) {
    pinBtn.addEventListener('click', async () => {
      const pinned = await window.claudeIsland.togglePin();
      pinBtn.classList.toggle('active', pinned);
    });
  }

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
    const alias = prompt(i18n.t('addCustomHost') + ':');
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
    if (port >= 1024 && port <= 65535) {
      config.port = port;
      window.claudeIsland.setConfig('port', port);
    }
  });

  // Listen host input
  const listenHostInput = document.getElementById('listenHostInput');
  if (listenHostInput) {
    listenHostInput.value = config.listenHost || '127.0.0.1';
    listenHostInput.addEventListener('change', () => {
      const h = listenHostInput.value.trim();
      if (h) {
        config.listenHost = h;
        window.claudeIsland.setConfig('listenHost', h);
        autoCheckFirewall();
      }
    });
  }

  // Firewall check button
  const firewallBtn = document.getElementById('firewallBtn');
  const firewallStatus = document.getElementById('firewallStatus');
  if (firewallBtn) {
    firewallBtn.addEventListener('click', async () => {
      await runFirewallFix();
    });
  }

  // Notification mode select
  const notifModeSelect = document.getElementById('notifModeSelect');
  if (notifModeSelect) {
    notifModeSelect.value = notifMode;
    notifModeSelect.addEventListener('change', () => {
      const val = notifModeSelect.value;
      InAppNotifications.setMode(val);
      window.claudeIsland.setConfig('notifMode', val);
      // Disable main-process system notifications unless mode is 'system'
      window.claudeIsland.setConfig('enableNotifications', val === 'system');
    });
  }

  // Sync on startup: disable system notifications if mode is inapp/off
  if (notifMode !== 'system') {
    window.claudeIsland.setConfig('enableNotifications', false);
  }

  // Notification sound select
  const notifSoundSelect = document.getElementById('notifSoundSelect');
  if (notifSoundSelect) {
    notifSoundSelect.value = notifSound;
    notifSoundSelect.addEventListener('change', () => {
      const val = notifSoundSelect.value;
      InAppNotifications.setSound(val);
      window.claudeIsland.setConfig('notifSound', val);
      InAppNotifications.playSound(val); // preview
    });
  }

  // Language select
  const langSelect = document.getElementById('langSelect');
  if (langSelect) {
    langSelect.value = savedLang;
    langSelect.addEventListener('change', () => {
      i18n.setLang(langSelect.value);
      applyI18n();
      renderSessions();
      renderSettings();
    });
  }

  // Opacity slider
  const opacitySlider = document.getElementById('opacitySlider');
  const opacityValue = document.getElementById('opacityValue');
  if (opacitySlider) {
    opacitySlider.addEventListener('input', () => {
      const val = parseInt(opacitySlider.value);
      if (opacityValue) opacityValue.textContent = val + '%';
      document.documentElement.style.setProperty('--bg-primary', `rgba(18,18,24,${val/100})`);
      window.claudeIsland.setConfig('opacity', val / 100);
    });
  }

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

// ─── i18n ────────────────────────────────────────────────────────

function applyI18n() {
  const { t } = i18n;

  // Header
  const headerTitle = document.getElementById('headerTitle');
  if (headerTitle) headerTitle.textContent = t('appTitle');

  // Empty state
  const emptyTitle = document.getElementById('emptyTitle');
  if (emptyTitle) emptyTitle.textContent = t('noActiveSessions');
  const emptySubtitle = document.getElementById('emptySubtitle');
  if (emptySubtitle) emptySubtitle.textContent = t('noActiveSessionsHint');

  // Settings section labels
  const sLabels = {
    sLabel_sshConfig: 'sshConfig',
    sLabel_machines: 'machines',
    sLabel_server: 'server',
    sLabel_notifications: 'notifications',
    sLabel_appearance: 'appearance',
    sLabel_tcpPort: 'tcpPort',
    sLabel_listenHost: 'listenHost',
    sLabel_firewallBtn: 'firewallBtn',
    sLabel_notificationMode: 'notificationMode',
    sLabel_notificationSound: 'notificationSound',
    sLabel_language: 'language',
    sLabel_opacity: 'opacity',
    sLabel_importFromSshConfig: 'importFromSshConfig',
    sLabel_addCustomHost: 'addCustomHost',
    // Dialogs
    importDialogTitle: 'importSshHost',
    importDialogBody: 'importSshHostBody',
    importDialogCancelBtn: 'cancel',
    authDialogBody: 'authBody',
    authDialogCopyBtn: 'copy',
    authDialogRetryBtn: 'retryBtn',
    authDialogDismissBtn: 'dismiss',
  };
  for (const [id, key] of Object.entries(sLabels)) {
    const el = document.getElementById(id);
    if (el) el.textContent = t(key);
  }

  // Notification mode options
  const notifModeSelect = document.getElementById('notifModeSelect');
  if (notifModeSelect) {
    notifModeSelect.options[0].text = t('notifModeInApp');
    notifModeSelect.options[1].text = t('notifModeSystem');
    notifModeSelect.options[2].text = t('notifModeOff');
  }

  // Notification sound options
  const notifSoundSelect = document.getElementById('notifSoundSelect');
  if (notifSoundSelect) {
    const soundKeys = ['soundNone', 'soundPop', 'soundPing', 'soundBell', 'soundChime'];
    for (let i = 0; i < notifSoundSelect.options.length; i++) {
      if (soundKeys[i]) notifSoundSelect.options[i].text = t(soundKeys[i]);
    }
  }
}

// ─── Crab Icon ───────────────────────────────────────────────────

function _initCrabIcon() {
  const canvas = document.getElementById('crabIcon');
  if (!canvas) return;
  // drawCrab sets _crabSize, _crabColor etc. on the canvas — must call this first
  PixelIcons.drawCrab(canvas, PixelIcons.COLORS.dim, 20, false);
}

function updateCrabStatus() {
  const canvas = document.getElementById('crabIcon');
  if (!canvas) return;

  const active = sessions.filter(s => s.phase !== 'ended');
  const hasApproval = active.some(s => s.phase === 'waiting_for_approval');
  const hasActive = active.some(s => ['processing', 'compacting'].includes(s.phase));

  let status = 'idle';
  if (hasApproval) status = 'waiting';
  else if (hasActive) status = 'active';

  const color = PixelIcons.crabColorForStatus(status);
  const animateLegs = status === 'active';
  PixelIcons.updateCrabIcon(canvas, color, animateLegs);
}

// ─── Notification diffing ────────────────────────────────────────
// Window already auto-shows when attention is needed, so in-app
// notifications are only sent when the window is NOT visible.
// Since we can't query visibility from renderer, we skip auto-notifications
// by default. The InAppNotifications module is still available for manual use.

function _checkNotifications(prev, next) {
  // No-op: window auto-pops on phase change, no need for redundant banners.
  // To re-enable, uncomment the body below.
  /*
  for (const session of next) {
    const old = prev.find(s => s.sessionId === session.sessionId);
    const prevPhase = old?.phase;
    const newPhase = session.phase;
    if (prevPhase === newPhase) continue;
    if (newPhase === 'waiting_for_approval') {
      InAppNotifications.permissionRequired(
        session.activePermission?.toolName || 'Tool',
        session.cwd,
        session.sessionId
      );
    } else if (newPhase === 'waiting_for_input' && prevPhase === 'processing') {
      InAppNotifications.claudeReady(session.cwd, session.sessionId);
    } else if (newPhase === 'compacting') {
      InAppNotifications.compacting(session.cwd);
    }
  }
  */
}

// ─── Firewall ──────────────────────────────────────────────────

function _showFirewallStatus(color, text, html) {
  const el = document.getElementById('firewallStatus');
  if (!el) return;
  el.style.display = 'block';
  el.style.color = color;
  if (html) el.innerHTML = html;
  else el.textContent = text;
}

function _hideFirewallStatus() {
  const el = document.getElementById('firewallStatus');
  if (el) el.style.display = 'none';
}

/** Check connectivity and show guidance if blocked */
async function autoCheckFirewall() {
  const btn = document.getElementById('firewallBtn');
  try {
    const result = await window.claudeIsland.checkFirewall();
    if (result.status === 'loopback') {
      _showFirewallStatus('var(--color-success, #4caf50)', i18n.t('firewallLoopback'));
      if (btn) btn.style.display = 'none';
    } else if (result.status === 'ok') {
      _showFirewallStatus('var(--color-success, #4caf50)', i18n.t('firewallOk', result.port));
      if (btn) btn.style.display = 'none';
    } else {
      // blocked — show guidance
      _showFirewallStatus('var(--color-warning, #ff9800)', '', i18n.t('firewallBlocked', result.port));
      if (btn) { btn.style.display = ''; btn.textContent = i18n.t('firewallBtn'); }
    }
  } catch {
    _hideFirewallStatus();
    if (btn) btn.style.display = 'none';
  }
}

/** Re-check button click */
async function runFirewallFix() {
  const btn = document.getElementById('firewallBtn');
  if (btn) { btn.disabled = true; btn.textContent = i18n.t('firewallChecking'); }
  await autoCheckFirewall();
  if (btn) btn.disabled = false;
}

// ─── View ────────────────────────────────────────────────────────

function toggleSettings() {
  const sv = document.getElementById('sessionsView');
  const stv = document.getElementById('settingsView');
  if (currentView === 'sessions') {
    sv.classList.add('hidden');
    stv.classList.remove('hidden');
    currentView = 'settings';
    renderSettings();
    autoCheckFirewall();
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
    if (existing) {
      updateSessionCard(existing, session);
    } else {
      const newCard = createSessionCard(session);
      container.insertBefore(newCard, container.firstChild);
    }
  });
}

function updateSessionCard(card, session) {
  const { t } = i18n;
  // Update phase class
  card.className = `session-card ${session.phase}`;

  // Phase label
  const phaseKey = `phase_${session.phase}`;
  const phaseLabel = t(phaseKey) !== phaseKey ? t(phaseKey) : session.phase;
  const labelEl = card.querySelector('.session-phase-label');
  if (labelEl) { labelEl.textContent = phaseLabel; labelEl.className = `session-phase-label ${session.phase}`; }

  // Status icon
  const iconSlot = card.querySelector('.session-status-icon');
  if (iconSlot) {
    iconSlot.innerHTML = '';
    iconSlot.appendChild(PixelIcons.createStatusIcon(session.phase, 14));
  }

  // Tool info
  const timeEl = card.querySelector('.session-time');
  let toolEl = card.querySelector('.session-tool');
  if (session.lastTool && session.phase !== 'ended') {
    const toolHtml = `<span class="session-tool-icon">⚙</span><span class="session-tool-name">${escapeHtml(session.lastTool)}</span>${session.lastToolInput?.file_path ? `<span style="color:var(--text-muted);font-size:10px;margin-left:2px">${escapeHtml(session.lastToolInput.file_path)}</span>` : ''}`;
    if (toolEl) { toolEl.innerHTML = toolHtml; }
    else if (timeEl) {
      toolEl = document.createElement('div');
      toolEl.className = 'session-tool';
      toolEl.innerHTML = toolHtml;
      timeEl.before(toolEl);
    }
  } else if (toolEl) { toolEl.remove(); }

  // Time
  if (timeEl) timeEl.textContent = formatTimeAgo(session.lastEventAt);

  // Permission / interaction sections — only rebuild if phase changed
  const prevPhase = card.dataset.phase;
  if (prevPhase !== session.phase ||
      JSON.stringify(session.activePermission) !== card.dataset.permHash ||
      JSON.stringify(session.activeInteraction) !== card.dataset.interHash) {
    card.dataset.phase = session.phase;
    card.dataset.permHash = JSON.stringify(session.activePermission);
    card.dataset.interHash = JSON.stringify(session.activeInteraction);
    card.querySelectorAll('.permission-section, .interaction-section').forEach(el => el.remove());
    // Re-append permission/interaction using same logic as createSessionCard
    _appendDynamicSections(card, session);
  }
}

function _appendDynamicSections(card, session) {
  const { t } = i18n;

  if (session.phase === 'waiting_for_approval' && session.activePermission) {
    const p = session.activePermission;
    const permSection = document.createElement('div');
    permSection.className = 'permission-section';

    if (p.toolName === 'ExitPlanMode') {
      const planText = (session.activePlan && session.activePlan.plan) || '';
      const content = document.createElement('div');
      content.className = 'interaction-question';
      content.innerHTML = planText ? MarkdownLite.render(planText) : '(no plan content)';
      permSection.appendChild(content);
      card.appendChild(permSection);
      return;
    }

    permSection.appendChild(CodePreview.buildPermissionPreview(p));

    const actions = document.createElement('div');
    actions.className = 'permission-actions';
    actions.innerHTML = `
      <button class="btn btn-success btn-sm" onclick="handleApprove('${session.sessionId}','${p.toolUseId}')">${t('allow')}</button>
      <button class="btn btn-warning btn-sm" onclick="handleAlwaysAllow('${session.sessionId}','${p.toolUseId}')">${t('alwaysAllow')}</button>
      <button class="btn btn-danger btn-sm" onclick="handleDeny('${session.sessionId}','${p.toolUseId}')">${t('deny')}</button>`;
    permSection.appendChild(actions);
    card.appendChild(permSection);
  }
  if (session.phase === 'waiting_for_input' && session.activeInteraction) {
    // delegate to createSessionCard's interaction logic by cloning from a temp card
    const tmp = createSessionCard(session);
    const sec = tmp.querySelector('.interaction-section');
    if (sec) card.appendChild(sec);
  }
}

function createSessionCard(session) {
  const { t } = i18n;
  const card = document.createElement('div');
  card.className = `session-card ${session.phase}`;
  card.dataset.sessionId = session.sessionId;

  const agentKey = `agent_${session.agentId}`;
  const agentName = t(agentKey) !== agentKey ? t(agentKey) : (session.agentId || 'Claude');
  const phaseKey = `phase_${session.phase}`;
  const phaseLabel = t(phaseKey) !== phaseKey ? t(phaseKey) : session.phase;
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

  // Build card shell first
  const archiveBtn = session.phase === 'ended'
    ? `<button class="btn btn-ghost session-archive-btn" onclick="handleArchive('${session.sessionId}')" title="${t('remove')}">✕</button>`
    : '';

  // Status icon (pixel art canvas)
  const iconWrapper = document.createElement('span');
  iconWrapper.className = 'session-status-icon';
  const iconCanvas = PixelIcons.createStatusIcon(session.phase, 14);
  iconWrapper.appendChild(iconCanvas);

  card.innerHTML = `
    ${archiveBtn}
    <div class="session-header">
      <div class="session-agent">
        <span class="session-status-icon-slot"></span>
        <span class="session-agent-name">${escapeHtml(agentName)}</span>
      </div>
      <span class="session-phase-label ${session.phase}">${phaseLabel}</span>
    </div>
    ${hostBadge}
    <div class="session-cwd" title="${escapeHtml(session.cwd || '')}">${escapeHtml(cwd)}</div>
    ${toolInfo}
    <div class="session-time">${timeAgo}</div>`;

  // Insert pixel icon into slot
  const slot = card.querySelector('.session-status-icon-slot');
  if (slot) slot.replaceWith(iconWrapper);

  // Permission section — use CodePreview module
  if (session.phase === 'waiting_for_approval' && session.activePermission) {
    const p = session.activePermission;
    const permSection = document.createElement('div');
    permSection.className = 'permission-section';

    const preview = CodePreview.buildPermissionPreview(p);
    permSection.appendChild(preview);

    const actions = document.createElement('div');
    actions.className = 'permission-actions';
    actions.innerHTML = `
      <button class="btn btn-success btn-sm" onclick="handleApprove('${session.sessionId}','${p.toolUseId}')">${t('allow')}</button>
      <button class="btn btn-warning btn-sm" onclick="handleAlwaysAllow('${session.sessionId}','${p.toolUseId}')">${t('alwaysAllow')}</button>
      <button class="btn btn-danger btn-sm" onclick="handleDeny('${session.sessionId}','${p.toolUseId}')">${t('deny')}</button>`;
    permSection.appendChild(actions);

    card.appendChild(permSection);
  }

  // Interaction section (read-only display of AskUserQuestion)
  if (session.phase === 'waiting_for_input' && session.activeInteraction) {
    let toolInput = session.activeInteraction.toolInput || {};
    // tool_input may arrive as a JSON string — parse it
    if (typeof toolInput === 'string') {
      try { toolInput = JSON.parse(toolInput); } catch (e) { toolInput = {}; }
    }
    const interactionSection = document.createElement('div');
    interactionSection.className = 'interaction-section';

    const questions = toolInput.questions;
    if (questions && Array.isArray(questions) && questions.length > 0) {
      let html = '';
      for (const q of questions) {
        const header = q.header ? `<div class="interaction-header">${escapeHtml(q.header)}</div>` : '';
        const questionText = q.question || '';
        let optionsHtml = '';
        if (q.options && q.options.length > 0) {
          optionsHtml = '<div class="interaction-options">' +
            q.options.map(opt => {
              const desc = opt.description ? `<span class="interaction-opt-desc">${escapeHtml(opt.description)}</span>` : '';
              return `<div class="interaction-opt-chip">${escapeHtml(opt.label)}${desc}</div>`;
            }).join('') + '</div>';
        }
        html += `${header}
          <div class="interaction-question">${typeof MarkdownLite !== 'undefined' ? MarkdownLite.render(questionText) : escapeHtml(questionText)}</div>
          ${optionsHtml}`;
      }
      interactionSection.innerHTML = html;
    } else {
      // Simple text question or raw tool_input — render as readable content
      const q = toolInput.question || '';
      if (q) {
        interactionSection.innerHTML = `<div class="interaction-question">${typeof MarkdownLite !== 'undefined' ? MarkdownLite.render(q) : escapeHtml(q)}</div>`;
      } else {
        // Fallback: render tool_input as formatted JSON
        const json = JSON.stringify(toolInput, null, 2);
        interactionSection.innerHTML = `<pre class="perm-code">${escapeHtml(json)}</pre>`;
      }
    }

    card.appendChild(interactionSection);
  }

  return card;
}

// ─── Session Actions ────────────────────────────────────────────

async function handleApprove(sessionId, toolUseId) {
  await window.claudeIsland.approvePermission(sessionId, toolUseId);
}
async function handleAlwaysAllow(sessionId, toolUseId) {
  await window.claudeIsland.alwaysAllowPermission(sessionId, toolUseId);
}
async function handleDeny(sessionId, toolUseId) {
  await window.claudeIsland.denyPermission(sessionId, toolUseId, 'Denied by user');
}
async function handleArchive(sessionId) {
  await window.claudeIsland.archiveSession(sessionId);
}

// ─── Settings ───────────────────────────────────────────────────

function renderSettings() {
  renderMachines();
  document.getElementById('portInput').value = config.port || 51515;
  const listenHostEl = document.getElementById('listenHostInput');
  if (listenHostEl) listenHostEl.value = config.listenHost || '127.0.0.1';

  // Read live values from localStorage/module state, not stale config snapshot
  const notifModeSelect = document.getElementById('notifModeSelect');
  if (notifModeSelect && !notifModeSelect._userChanged) {
    notifModeSelect.value = config.notifMode || 'inapp';
  }

  const notifSoundSelect = document.getElementById('notifSoundSelect');
  if (notifSoundSelect && !notifSoundSelect._userChanged) {
    notifSoundSelect.value = config.notifSound || 'pop';
  }

  const langSelect = document.getElementById('langSelect');
  if (langSelect) langSelect.value = i18n.getLang();

  const opacitySlider = document.getElementById('opacitySlider');
  const opacityValue = document.getElementById('opacityValue');
  if (opacitySlider) {
    const saved = Math.round((config.opacity ?? 0.9) * 100);
    opacitySlider.value = saved;
    if (opacityValue) opacityValue.textContent = saved + '%';
  }
}

// ─── Machine Cards ───────────────────────────────────────────────

const _hookStatusCache = {};

function renderMachines() {
  const container = document.getElementById('machinesList');
  if (!container) return;
  container.innerHTML = machines.map(renderMachineCard).join('');
}

function renderMachineCard(machine) {
  const { t } = i18n;
  const isLocal = machine.type === 'local';
  const icon = isLocal ? '🖥' : '🌐';
  const status = isLocal ? null : (remoteStatuses[machine.sshAlias] || 'idle');
  const statusKey = `status_${status}`;
  const statusLabel = t(statusKey) !== statusKey ? t(statusKey) : (status || 'Idle');
  const statusCls = (STATUS_LABELS_MAP[status] || STATUS_LABELS_MAP.idle).cls;

  const headerRight = isLocal
    ? '<span class="machine-tag">local</span>'
    : `<span class="remote-status-dot ${statusCls}"></span><span class="remote-status-label ${statusCls}">${statusLabel}</span>`;

  const pathsHtml = machine.claudePaths.map(p => {
    const hookBadge = isLocal ? getMachinePathHookBadge(machine.id, p) : `<span class="hook-badge installed" title="Hooks are automatically synced">${t('autoSynced')}</span>`;
    const encodedP = encodeURIComponent(p);
    return `<div class="machine-path-row">
      <span class="machine-path-text" title="${escapeHtml(p)}">${shortenPath(p)}</span>
      ${hookBadge}
      <button class="btn btn-ghost btn-xs machine-path-remove" onclick="machineRemovePath('${machine.id}', '${encodedP}')" title="${t('remove')}">✕</button>
    </div>`;
  }).join('');

  let actionsHtml = '';
  if (isLocal) {
    actionsHtml = `
      <button class="btn btn-outline btn-sm" onclick="machineAddPath('${machine.id}')">+ ${t('addPath').replace('+ ','')}</button>
      <button class="btn btn-primary btn-sm" onclick="machineInstallHooks('${machine.id}')">${t('installHooks')}</button>`;
  } else {
    const connected = status === 'connected';
    const errored = ['auth_required', 'error', 'port_conflict'].includes(status);
    const connectBtn = connected
      ? `<button class="btn btn-ghost btn-sm" onclick="machineDisconnect('${machine.id}')">${t('disconnect')}</button>`
      : errored
        ? `<button class="btn btn-outline btn-sm" onclick="machineRetry('${machine.id}')">${t('retry')}</button>`
        : `<button class="btn btn-primary btn-sm" onclick="machineConnect('${machine.id}')">${t('connect')}</button>`;
    actionsHtml = `${connectBtn}
      <button class="btn btn-ghost btn-sm" onclick="machineInstallHooks('${machine.id}', this)" ${!connected ? 'disabled title="Connect first"' : ''}>${t('forceSync')}</button>
      <button class="btn btn-ghost btn-sm" onclick="machineAddRemotePath('${machine.id}')">+ ${t('addRemotePath').replace('+ ','')}</button>
      <button class="btn btn-ghost btn-sm machine-remove-btn" onclick="machineRemove('${machine.id}')">${t('remove')}</button>`;
  }

  return `<div class="machine-card" id="machine-${machine.id}">
    <div class="machine-header">
      <div class="machine-title"><span class="machine-icon">${icon}</span><span class="machine-label">${escapeHtml(machine.label)}</span></div>
      <div class="machine-status">${headerRight}</div>
    </div>
    <div class="machine-paths">${pathsHtml || `<span class="settings-hint" style="margin:0">${t('noPathsConfigured')}</span>`}</div>
    <div class="machine-actions">${actionsHtml}</div>
  </div>`;
}

function getMachinePathHookBadge(machineId, p) {
  const { t } = i18n;
  const key = `${machineId}:${p}`;
  const s = _hookStatusCache[key];
  if (!s) {
    window.claudeIsland.getMachineHookStatus(machineId).then(statuses => {
      for (const entry of statuses) _hookStatusCache[`${machineId}:${entry.path}`] = entry;
      renderMachines();
    }).catch(() => {});
    return '';
  }
  if (!s.exists) return `<span class="hook-badge not-found">${t('hooksNotFound')}</span>`;
  if (s.installed) return `<span class="hook-badge installed">${t('hooksInstalled')}</span>`;
  return `<span class="hook-badge not-installed">${t('hooksNotInstalled')}</span>`;
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
  const originalText = btn?.textContent || i18n.t('installHooks');
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
  const { t } = i18n;
  const container = document.getElementById('importHostList');
  if (!container) return;
  const existing = new Set(machines.filter(m => m.type === 'ssh').map(m => m.sshAlias));
  const available = sshHosts.filter(h => !existing.has(h.alias));
  if (available.length === 0) {
    container.innerHTML = `<p class="settings-hint">${t('allHostsAdded')}</p>`;
    return;
  }
  container.innerHTML = available.map(h => `
    <div class="remote-host-row" style="cursor:pointer" onclick="importHost('${escapeHtml(h.alias)}')">
      <div class="remote-host-info">
        <span class="remote-status-dot status-idle"></span>
        <span class="remote-host-alias">${escapeHtml(h.alias)}</span>
        <span class="settings-hint" style="margin:0">${escapeHtml(h.hostname)}</span>
      </div>
      <button class="btn btn-primary btn-sm">${t('add')}</button>
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
  document.getElementById('authDialogTitle').textContent = `${machine?.label || machineId} — ${i18n.t('authRequired')}`;
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
  const { t } = i18n;
  if (!dateStr) return '';
  const seconds = Math.floor((Date.now() - new Date(dateStr).getTime()) / 1000);
  if (seconds < 5) return t('justNow');
  if (seconds < 60) return t('secondsAgo', seconds);
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return t('minutesAgo', minutes);
  return t('hoursAgo', Math.floor(minutes / 60));
}
