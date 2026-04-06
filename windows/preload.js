/**
 * Preload script for Claude Island Windows
 * Exposes safe IPC bridge between renderer and main process
 */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('claudeIsland', {
  // Session data
  getSessions: () => ipcRenderer.invoke('get-sessions'),
  onSessionsChanged: (callback) => {
    const handler = (_event, sessions) => callback(sessions);
    ipcRenderer.on('sessions-changed', handler);
    return () => ipcRenderer.removeListener('sessions-changed', handler);
  },

  // Permission actions
  approvePermission: (sessionId, toolUseId) =>
    ipcRenderer.invoke('approve-permission', sessionId, toolUseId),
  denyPermission: (sessionId, toolUseId, reason) =>
    ipcRenderer.invoke('deny-permission', sessionId, toolUseId, reason),
  alwaysAllowPermission: (sessionId, toolUseId) =>
    ipcRenderer.invoke('always-allow-permission', sessionId, toolUseId),

  // Interaction actions
  submitInteraction: (sessionId, toolUseId, input) =>
    ipcRenderer.invoke('submit-interaction', sessionId, toolUseId, input),
  denyInteraction: (sessionId, toolUseId, reason) =>
    ipcRenderer.invoke('deny-interaction', sessionId, toolUseId, reason),

  // Session management
  archiveSession: (sessionId) => ipcRenderer.invoke('archive-session', sessionId),

  // Configuration
  getConfig: () => ipcRenderer.invoke('get-config'),
  setConfig: (key, value) => ipcRenderer.invoke('set-config', key, value),
  onConfigChanged: (callback) => {
    const handler = (_event, config) => callback(config);
    ipcRenderer.on('config-changed', handler);
    return () => ipcRenderer.removeListener('config-changed', handler);
  },

  // ─── Machines (per-machine config) ───────────────────────────
  getMachines: () => ipcRenderer.invoke('get-machines'),
  addSSHMachine: (alias, options) => ipcRenderer.invoke('add-ssh-machine', alias, options),
  updateMachine: (id, updates) => ipcRenderer.invoke('update-machine', id, updates),
  removeMachine: (id) => ipcRenderer.invoke('remove-machine', id),
  addClaudePathToMachine: (machineId, path) =>
    ipcRenderer.invoke('add-claude-path-to-machine', machineId, path),
  removeClaudePathFromMachine: (machineId, path) =>
    ipcRenderer.invoke('remove-claude-path-from-machine', machineId, path),

  onMachinesChanged: (callback) => {
    const handler = (_event, config) => callback(config.machines);
    ipcRenderer.on('config-changed', handler);
    return () => ipcRenderer.removeListener('config-changed', handler);
  },

  // ─── Hook management ──────────────────────────────────────────
  installHooksForMachine: (machineId) =>
    ipcRenderer.invoke('install-hooks-for-machine', machineId),
  getMachineHookStatus: (machineId) =>
    ipcRenderer.invoke('get-machine-hook-status', machineId),

  // ─── SSH Config ───────────────────────────────────────────────
  getSshHosts: () => ipcRenderer.invoke('get-ssh-hosts'),
  getSshConfigPath: () => ipcRenderer.invoke('get-ssh-config-path'),
  selectSshConfigFile: () => ipcRenderer.invoke('select-ssh-config-file'),
  onSshHostsChanged: (callback) => {
    const handler = (_event, hosts) => callback(hosts);
    ipcRenderer.on('ssh-hosts-changed', handler);
    return () => ipcRenderer.removeListener('ssh-hosts-changed', handler);
  },

  // ─── Tunnel management ────────────────────────────────────────
  getRemoteStatuses: () => ipcRenderer.invoke('get-remote-statuses'),
  connectMachine: (machineId) => ipcRenderer.invoke('connect-machine', machineId),
  disconnectMachine: (machineId) => ipcRenderer.invoke('disconnect-machine', machineId),
  retryMachine: (machineId) => ipcRenderer.invoke('retry-machine', machineId),
  onRemoteStatusChanged: (callback) => {
    const handler = (_event, data) => callback(data);
    ipcRenderer.on('remote-status-changed', handler);
    return () => ipcRenderer.removeListener('remote-status-changed', handler);
  },
  onRemoteAuthRequired: (callback) => {
    const handler = (_event, data) => callback(data);
    ipcRenderer.on('remote-auth-required', handler);
    return () => ipcRenderer.removeListener('remote-auth-required', handler);
  },

  // ─── Window controls ──────────────────────────────────────────
  hideWindow: () => ipcRenderer.send('hide-window'),
  selectDirectory: () => ipcRenderer.invoke('select-directory'),
});
