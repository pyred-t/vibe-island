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

  // Session management
  archiveSession: (sessionId) => ipcRenderer.invoke('archive-session', sessionId),

  // Configuration
  getConfig: () => ipcRenderer.invoke('get-config'),
  setConfig: (key, value) => ipcRenderer.invoke('set-config', key, value),
  addClaudePath: (path) => ipcRenderer.invoke('add-claude-path', path),
  removeClaudePath: (path) => ipcRenderer.invoke('remove-claude-path', path),
  onConfigChanged: (callback) => {
    const handler = (_event, config) => callback(config);
    ipcRenderer.on('config-changed', handler);
    return () => ipcRenderer.removeListener('config-changed', handler);
  },

  // Hook management
  installHooks: () => ipcRenderer.invoke('install-hooks'),
  getHookStatus: () => ipcRenderer.invoke('get-hook-status'),

  // Window controls
  hideWindow: () => ipcRenderer.send('hide-window'),

  // Dialog
  selectDirectory: () => ipcRenderer.invoke('select-directory'),

  // Remote SSH hosts
  getSshHosts: () => ipcRenderer.invoke('get-ssh-hosts'),
  getSshConfigPath: () => ipcRenderer.invoke('get-ssh-config-path'),
  getRemoteHosts: () => ipcRenderer.invoke('get-remote-hosts'),
  getRemoteStatuses: () => ipcRenderer.invoke('get-remote-statuses'),
  connectRemote: (alias, port) => ipcRenderer.invoke('connect-remote', alias, port),
  disconnectRemote: (alias) => ipcRenderer.invoke('disconnect-remote', alias),
  removeRemoteHost: (alias) => ipcRenderer.invoke('remove-remote-host', alias),
  retryRemote: (alias) => ipcRenderer.invoke('retry-remote', alias),

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
  onSshHostsChanged: (callback) => {
    const handler = (_event, hosts) => callback(hosts);
    ipcRenderer.on('ssh-hosts-changed', handler);
    return () => ipcRenderer.removeListener('ssh-hosts-changed', handler);
  },
});
