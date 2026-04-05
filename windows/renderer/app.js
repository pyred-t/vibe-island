/**
 * Claude Island Windows — Renderer Process
 * Handles UI logic for the popup panel
 */

// ─── State ──────────────────────────────────────────────────────

let currentView = 'sessions'; // 'sessions' | 'settings'
let sessions = [];
let config = {};

// ─── Phase Display Labels ───────────────────────────────────────

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

// ─── Init ───────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', async () => {
  // Load initial data
  sessions = await window.claudeIsland.getSessions();
  config = await window.claudeIsland.getConfig();

  renderSessions();
  updateStatusDot();
  renderSettings();

  // Listen for session changes
  window.claudeIsland.onSessionsChanged((newSessions) => {
    sessions = newSessions;
    renderSessions();
    updateStatusDot();
  });

  // Listen for config changes
  window.claudeIsland.onConfigChanged((newConfig) => {
    config = newConfig;
    renderSettings();
  });

  // UI event handlers
  document.getElementById('settingsBtn').addEventListener('click', toggleSettings);
  document.getElementById('closeBtn').addEventListener('click', () => {
    window.claudeIsland.hideWindow();
  });
  document.getElementById('addPathBtn').addEventListener('click', addPath);
  document.getElementById('installHooksBtn').addEventListener('click', installHooks);

  // Port input
  const portInput = document.getElementById('portInput');
  portInput.value = config.port || 51515;
  portInput.addEventListener('change', () => {
    const port = parseInt(portInput.value);
    if (port >= 1024 && port <= 65535) {
      window.claudeIsland.setConfig('port', port);
    }
  });

  // Notification toggle
  const notifToggle = document.getElementById('notifToggle');
  notifToggle.checked = config.enableNotifications !== false;
  notifToggle.addEventListener('change', () => {
    window.claudeIsland.setConfig('enableNotifications', notifToggle.checked);
  });
});

// ─── View Switching ─────────────────────────────────────────────

function toggleSettings() {
  if (currentView === 'settings') {
    currentView = 'sessions';
  } else {
    currentView = 'settings';
    refreshHookStatus();
  }
  document.getElementById('sessionsView').classList.toggle('hidden', currentView !== 'sessions');
  document.getElementById('settingsView').classList.toggle('hidden', currentView !== 'settings');
}

// ─── Status Dot ─────────────────────────────────────────────────

function updateStatusDot() {
  const dot = document.getElementById('statusDot');
  dot.className = 'logo-dot';

  const active = sessions.filter(s => s.phase !== 'ended');
  const hasApproval = active.some(s => s.phase === 'waiting_for_approval');
  const hasProcessing = active.some(s => s.phase === 'processing');

  if (hasApproval) {
    dot.classList.add('waiting');
  } else if (hasProcessing) {
    dot.classList.add('active');
  } else if (active.length > 0) {
    dot.classList.add('idle-sessions');
  }
}

// ─── Sessions Rendering ────────────────────────────────────────

function renderSessions() {
  const container = document.getElementById('sessionsList');
  const emptyState = document.getElementById('emptyState');

  // Filter out ended sessions older than 30s for cleaner display
  const visibleSessions = sessions.filter(s => {
    if (s.phase === 'ended' && s.endedAt) {
      const age = Date.now() - new Date(s.endedAt).getTime();
      return age < 30000;
    }
    return true;
  });

  if (visibleSessions.length === 0) {
    container.innerHTML = '';
    container.appendChild(createEmptyState());
    return;
  }

  // Keep existing cards and update them to avoid flicker
  const fragment = document.createDocumentFragment();

  for (const session of visibleSessions) {
    fragment.appendChild(createSessionCard(session));
  }

  container.innerHTML = '';
  container.appendChild(fragment);
}

function createEmptyState() {
  const div = document.createElement('div');
  div.className = 'empty-state';
  div.innerHTML = `
    <div class="empty-icon">
      <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" opacity="0.35">
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
      </svg>
    </div>
    <p class="empty-title">No Active Sessions</p>
    <p class="empty-subtitle">Start Claude Code to see sessions here</p>
  `;
  return div;
}

function createSessionCard(session) {
  const card = document.createElement('div');
  card.className = `session-card ${session.phase}`;
  card.dataset.sessionId = session.sessionId;

  const agentName = AGENT_NAMES[session.agentId] || session.agentId;
  const phaseLabel = PHASE_LABELS[session.phase] || session.phase;
  const cwd = shortenPath(session.cwd);
  const timeAgo = formatTimeAgo(session.lastEventAt);

  let toolInfo = '';
  if (session.lastTool && session.phase !== 'ended') {
    toolInfo = `
      <div class="session-tool">
        <span class="session-tool-icon">⚙️</span>
        <span class="session-tool-name">${escapeHtml(session.lastTool)}</span>
      </div>
    `;
  }

  let permissionSection = '';
  if (session.phase === 'waiting_for_approval' && session.activePermission) {
    const perm = session.activePermission;
    const inputStr = perm.toolInput ? truncate(JSON.stringify(perm.toolInput, null, 1), 200) : '';

    permissionSection = `
      <div class="permission-actions-wrapper">
        <div class="permission-tool-info">
          <span class="permission-tool-name">${escapeHtml(perm.toolName)}</span>
          ${inputStr ? `<div class="permission-tool-input">${escapeHtml(inputStr)}</div>` : ''}
        </div>
        <div class="permission-actions">
          <button class="btn btn-success btn-sm" onclick="handleApprove('${session.sessionId}', '${perm.toolUseId}')">
            ✓ Allow
          </button>
          <button class="btn btn-warning btn-sm" onclick="handleAlwaysAllow('${session.sessionId}', '${perm.toolUseId}')">
            ✓ Always
          </button>
          <button class="btn btn-danger btn-sm" onclick="handleDeny('${session.sessionId}', '${perm.toolUseId}')">
            ✗ Deny
          </button>
        </div>
      </div>
    `;
  }

  let interactionSection = '';
  if (session.activeInteraction && session.phase === 'waiting_for_input') {
    const inter = session.activeInteraction;
    const question = inter.toolInput?.question || 'Claude has a question for you';

    interactionSection = `
      <div class="interaction-section">
        <div class="interaction-question">${escapeHtml(question)}</div>
        <div class="interaction-input-row">
          <input type="text" class="interaction-input" id="interaction-${session.sessionId}"
            placeholder="Type your response…"
            onkeydown="if(event.key==='Enter')handleInteraction('${session.sessionId}','${inter.toolUseId}')">
          <button class="btn btn-primary btn-sm" onclick="handleInteraction('${session.sessionId}','${inter.toolUseId}')">
            Send
          </button>
        </div>
      </div>
    `;
  }

  // Archive button for ended sessions
  let archiveBtn = '';
  if (session.phase === 'ended') {
    archiveBtn = `<button class="btn btn-ghost session-archive-btn" onclick="handleArchive('${session.sessionId}')" title="Remove">✕</button>`;
  }

  card.innerHTML = `
    ${archiveBtn}
    <div class="session-header">
      <div class="session-agent">
        <div class="session-agent-dot ${session.phase}"></div>
        <span class="session-agent-name">${escapeHtml(agentName)}</span>
      </div>
      <span class="session-phase-label ${session.phase}">${phaseLabel}</span>
    </div>
    <div class="session-cwd" title="${escapeHtml(session.cwd || '')}">${escapeHtml(cwd)}</div>
    ${toolInfo}
    ${permissionSection}
    ${interactionSection}
    <div class="session-time">${timeAgo}</div>
  `;

  return card;
}

// ─── Actions ────────────────────────────────────────────────────

async function handleApprove(sessionId, toolUseId) {
  await window.claudeIsland.approvePermission(sessionId, toolUseId);
}

async function handleAlwaysAllow(sessionId, toolUseId) {
  await window.claudeIsland.alwaysAllowPermission(sessionId, toolUseId);
}

async function handleDeny(sessionId, toolUseId) {
  await window.claudeIsland.denyPermission(sessionId, toolUseId, 'Denied by user');
}

async function handleInteraction(sessionId, toolUseId) {
  const input = document.getElementById(`interaction-${sessionId}`);
  if (!input || !input.value.trim()) return;

  await window.claudeIsland.submitInteraction(sessionId, toolUseId, {
    question: input.value.trim(),
  });
  input.value = '';
}

async function handleArchive(sessionId) {
  await window.claudeIsland.archiveSession(sessionId);
}

// ─── Settings ───────────────────────────────────────────────────

function renderSettings() {
  renderPaths();
  document.getElementById('portInput').value = config.port || 51515;
  document.getElementById('notifToggle').checked = config.enableNotifications !== false;
}

function renderPaths() {
  const container = document.getElementById('pathsList');
  const paths = config.claudeConfigPaths || [];

  container.innerHTML = paths.map((p, i) => {
    let exists = false;
    try { exists = true; /* We can't check from renderer, but we show it */ } catch {}

    return `
      <div class="path-item">
        <span class="path-text">${escapeHtml(p)}</span>
        <button class="btn btn-ghost btn-sm" onclick="removePath('${escapeHtml(p).replace(/'/g, "\\'")}')" title="Remove">✕</button>
      </div>
    `;
  }).join('');
}

async function addPath() {
  const selected = await window.claudeIsland.selectDirectory();
  if (selected) {
    const paths = await window.claudeIsland.addClaudePath(selected);
    config.claudeConfigPaths = paths;
    renderPaths();
  }
}

async function removePath(p) {
  const paths = await window.claudeIsland.removeClaudePath(p);
  config.claudeConfigPaths = paths;
  renderPaths();
}

async function installHooks() {
  const btn = document.getElementById('installHooksBtn');
  btn.textContent = 'Installing...';
  btn.disabled = true;

  try {
    const results = await window.claudeIsland.installHooks();
    await refreshHookStatus();
  } catch (err) {
    console.error('Hook installation failed:', err);
  } finally {
    btn.textContent = 'Install / Reinstall Hooks';
    btn.disabled = false;
  }
}

async function refreshHookStatus() {
  const status = await window.claudeIsland.getHookStatus();
  const container = document.getElementById('hookStatus');

  container.innerHTML = status.map(s => {
    let badge;
    if (!s.exists) {
      badge = '<span class="hook-badge not-found">Path Not Found</span>';
    } else if (s.installed) {
      badge = '<span class="hook-badge installed">Installed</span>';
    } else {
      badge = '<span class="hook-badge not-installed">Not Installed</span>';
    }

    return `
      <div class="hook-item">
        ${badge}
        <span style="font-family:'Cascadia Code',monospace;font-size:10px;color:var(--text-muted);word-break:break-all;">${escapeHtml(shortenPath(s.path))}</span>
      </div>
    `;
  }).join('');
}

// ─── Utilities ──────────────────────────────────────────────────

function shortenPath(p) {
  if (!p) return '';
  const normalized = p.replace(/\\/g, '/');
  const parts = normalized.split('/').filter(Boolean);
  if (parts.length <= 3) return parts.join('/');
  return '…/' + parts.slice(-3).join('/');
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
  const date = new Date(dateStr);
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ago`;
}
