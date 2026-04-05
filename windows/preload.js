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
});
