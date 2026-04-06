/**
 * Claude Island for Windows — Main Process
 * System tray app with popup panel for Claude Code session monitoring
 */

// Electron's built-in modules should be available at this point
// when running via electron.exe
const { app, BrowserWindow, ipcMain, screen, dialog } = require('electron');
const path = require('path');
const net = require('net');

let configStore, hookServer, SessionStore, SessionPhase, hookInstaller, trayManager, notification;
let sshConfigReader, tunnelManager, TunnelStatus, remoteHostStore;

let mainWindow = null;
let isQuitting = false;

// ─── App Setup ───────────────────────────────────────────────

app.setAppUserModelId('com.claudeisland.windows');

// Single instance lock
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      showWindow();
    }
  });
}

// ─── Window Creation ─────────────────────────────────────────

function createWindow() {
  const { width: screenWidth, height: screenHeight } = screen.getPrimaryDisplay().workAreaSize;

  const winWidth = 420;
  const winHeight = 560;

  // Position at bottom-right, above the taskbar
  const x = screenWidth - winWidth - 12;
  const y = screenHeight - winHeight - 12;

  mainWindow = new BrowserWindow({
    width: winWidth,
    height: winHeight,
    x,
    y,
    frame: false,
    transparent: true,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  // Use 'pop-up-menu' level so blur fires reliably when clicking outside
  mainWindow.setAlwaysOnTop(true, 'pop-up-menu');

  mainWindow.on('blur', () => {
    if (!isQuitting && mainWindow && mainWindow.isVisible()) {
      // Small delay so clicking tray icon doesn't instantly hide
      setTimeout(() => {
        if (mainWindow && !mainWindow.isFocused()) mainWindow.hide();
      }, 200);
    }
  });

  mainWindow.on('close', (e) => {
    if (!isQuitting) {
      e.preventDefault();
      mainWindow.hide();
    }
  });
}

function showWindow() {
  if (!mainWindow) return;

  // Reposition near tray area (bottom-right)
  const { width: screenWidth, height: screenHeight } = screen.getPrimaryDisplay().workAreaSize;
  const [winWidth, winHeight] = mainWindow.getSize();
  mainWindow.setPosition(screenWidth - winWidth - 12, screenHeight - winHeight - 12);

  mainWindow.show();
  // On Windows, force focus so blur event fires when clicking outside
  mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
  mainWindow.moveTop();
  mainWindow.focus();
  mainWindow.setAlwaysOnTop(true, 'pop-up-menu');
}

function toggleWindow() {
  if (!mainWindow) return;
  if (mainWindow.isVisible()) {
    mainWindow.hide();
  } else {
    showWindow();
  }
}

// ─── IPC Handlers ────────────────────────────────────────────

function setupIPC() {
  ipcMain.handle('get-sessions', () => SessionStore.getAllSessions());

  ipcMain.handle('approve-permission', (_event, sessionId, toolUseId) => {
    const success = hookServer.respondToPermission(toolUseId, 'allow');
    if (success) SessionStore.permissionApproved(sessionId, toolUseId);
    return success;
  });

  ipcMain.handle('deny-permission', (_event, sessionId, toolUseId, reason) => {
    const success = hookServer.respondToPermission(toolUseId, 'deny', reason || 'Denied by user via Claude Island');
    if (success) SessionStore.permissionDenied(sessionId, toolUseId);
    return success;
  });

  ipcMain.handle('always-allow-permission', (_event, sessionId, toolUseId) => {
    const success = hookServer.respondToPermission(toolUseId, 'always_allow');
    if (success) SessionStore.permissionApproved(sessionId, toolUseId);
    return success;
  });

  ipcMain.handle('submit-interaction', (_event, sessionId, toolUseId, input) => {
    const success = hookServer.respondToInteraction(toolUseId, input);
    if (success) SessionStore.interactionSubmitted(sessionId, toolUseId);
    return success;
  });

  ipcMain.handle('deny-interaction', (_event, sessionId, toolUseId, reason) => {
    const success = hookServer.denyInteraction(toolUseId, reason || 'Dismissed by user');
    if (success) SessionStore.interactionSubmitted(sessionId, toolUseId);
    return success;
  });

  ipcMain.handle('archive-session', (_event, sessionId) => {
    SessionStore.removeSession(sessionId);
    return true;
  });

  ipcMain.handle('get-config', () => configStore.getAll());

  ipcMain.handle('check-firewall', async () => {
    const port = configStore.get('port') || 51515;
    const listenHost = configStore.get('listenHost') || '127.0.0.1';

    if (listenHost === '127.0.0.1') {
      return { status: 'loopback' };
    }

    // Try a quick TCP self-connect to see if the port is reachable
    const net = require('net');
    const reachable = await new Promise((resolve) => {
      const sock = net.createConnection({ host: listenHost, port }, () => {
        sock.destroy();
        resolve(true);
      });
      sock.on('error', () => resolve(false));
      sock.setTimeout(2000, () => { sock.destroy(); resolve(false); });
    });

    return { status: reachable ? 'ok' : 'blocked', port, listenHost };
  });

  ipcMain.handle('set-config', (_event, key, value) => {
    configStore.set(key, value);
    // If SSH config path changed, reload the reader
    if (key === 'sshConfigPath') {
      sshConfigReader.watch();
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('ssh-hosts-changed', sshConfigReader.getHosts());
      }
    }
    // If port or listenHost changed, restart the hook server and reinstall hooks
    if (key === 'port' || key === 'listenHost') {
      hookServer.stop();
      const newPort = configStore.get('port') || 51515;
      const newHost = configStore.get('listenHost') || '127.0.0.1';
      hookServer.start(newPort, newHost);
      // Reinstall hooks so settings.json gets the updated --host / --port args
      hookInstaller.installAll();
    }
    return true;
  });

  // ─── Machine CRUD ──────────────────────────────────────────────

  ipcMain.handle('get-machines', () => configStore.getMachines());

  ipcMain.handle('add-ssh-machine', (_event, alias, options) => {
    return configStore.addSSHMachine(alias, options || {});
  });

  ipcMain.handle('update-machine', (_event, id, updates) => {
    return configStore.updateMachine(id, updates);
  });

  ipcMain.handle('remove-machine', (_event, id) => {
    tunnelManager.disconnect(id);
    return configStore.removeMachine(id);
  });

  ipcMain.handle('add-claude-path-to-machine', (_event, machineId, newPath) => {
    return configStore.addClaudePathToMachine(machineId, newPath);
  });

  ipcMain.handle('remove-claude-path-from-machine', (_event, machineId, p) => {
    return configStore.removeClaudePathFromMachine(machineId, p);
  });

  // ─── Hook Management ───────────────────────────────────────────

  ipcMain.handle('install-hooks-for-machine', async (_event, machineId) => {
    const machine = configStore.getMachine(machineId);
    if (!machine) return { error: 'Machine not found' };
    if (machine.type === 'local') {
      return hookInstaller.installForMachine(machine);
    }
    // Remote SSH machine
    if (!machine.sshAlias) return { error: 'Missing sshAlias' };
    try {
      await tunnelManager.forceInstallHooks(machine.sshAlias);
      return { success: true };
    } catch (e) {
      return { error: e.message };
    }
  });

  ipcMain.handle('get-machine-hook-status', (_event, machineId) => {
    const machine = configStore.getMachine(machineId);
    if (!machine) return [];
    return hookInstaller.getMachineHookStatus(machine);
  });

  // ─── SSH Config ─────────────────────────────────────────────────

  ipcMain.handle('get-ssh-hosts', () => sshConfigReader.getHosts());
  ipcMain.handle('get-ssh-config-path', () => sshConfigReader.getConfigPath());

  ipcMain.handle('select-ssh-config-file', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openFile'],
      title: 'Select SSH Config File',
      filters: [{ name: 'All Files', extensions: ['*'] }],
      defaultPath: require('path').join(require('os').homedir(), '.ssh'),
    });
    if (result.canceled || result.filePaths.length === 0) return null;
    const chosen = result.filePaths[0];
    configStore.set('sshConfigPath', chosen);
    sshConfigReader.watch();
    return chosen;
  });

  // ─── Tunnel Management ──────────────────────────────────────────

  ipcMain.handle('get-remote-statuses', () => tunnelManager.getAllStatuses());

  ipcMain.handle('connect-machine', async (_event, machineId) => {
    const machine = configStore.getMachine(machineId);
    if (!machine || machine.type !== 'ssh') return { ok: false, error: 'Not an SSH machine' };
    configStore.updateMachine(machineId, { autoConnect: true });
    try {
      await tunnelManager.connect(machine);
      return { ok: true };
    } catch (err) {
      return { ok: false, error: err.message };
    }
  });

  ipcMain.handle('disconnect-machine', (_event, machineId) => {
    const machine = configStore.getMachine(machineId);
    if (machine?.sshAlias) tunnelManager.disconnect(machine.sshAlias);
    configStore.updateMachine(machineId, { autoConnect: false });
    return true;
  });

  ipcMain.handle('retry-machine', async (_event, machineId) => {
    const machine = configStore.getMachine(machineId);
    if (!machine || machine.type !== 'ssh') return { ok: false, error: 'Not an SSH machine' };
    try {
      await tunnelManager.connect(machine);
      return { ok: true };
    } catch (err) {
      return { ok: false, error: err.message };
    }
  });

  // ─── Window ─────────────────────────────────────────────────────

  ipcMain.on('hide-window', () => {
    if (mainWindow) mainWindow.hide();
  });

  ipcMain.handle('select-directory', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory'],
      title: 'Select Claude Code Configuration Directory',
    });
    if (result.canceled || result.filePaths.length === 0) return null;
    return result.filePaths[0];
  });
}

// ─── Event Wiring ────────────────────────────────────────────

function wireEvents() {
  // Hook server → Session store
  hookServer.on('hookEvent', (event) => {
    SessionStore.processHookEvent(event);

    // Cancel stale permissions on Stop events
    if (event.event === 'Stop') {
      hookServer.cancelPendingPermissions(event.session_id);
    }

    // Cancel specific permission on PostToolUse
    if (event.event === 'PostToolUse' && event.tool_use_id) {
      hookServer.cancelPendingPermission(event.tool_use_id);
    }
  });

  // Session store → Window updates
  SessionStore.on('changed', (sessions) => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('sessions-changed', sessions);
    }
    trayManager.updateStatus(sessions);
  });

  // Session store → Notifications
  SessionStore.on('sessionCreated', (session) => {
    const hostLabel = session.isRemote ? session.hostname : 'local';
    console.log(`[Session] New session: ${session.sessionId} host=${hostLabel} cwd=${session.cwd}`);
  });

  SessionStore.on('phaseChanged', (session, prevPhase, newPhase) => {
    console.log(`[Session] ${session.sessionId} phase: ${prevPhase} -> ${newPhase}`);
    notification.onPhaseChanged(session, prevPhase, newPhase);

    // Show window for all phases except processing/ended
    if (
      newPhase !== SessionPhase.PROCESSING &&
      newPhase !== SessionPhase.ENDED
    ) {
      showWindow();
    }
  });

  // Config changes → Window
  configStore.on('changed', (key, value) => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('config-changed', configStore.getAll());
    }

    if (key === 'enableNotifications') {
      notification.setEnabled(value);
    }
  });

  // Tunnel manager → Window
  tunnelManager.on('statusChanged', (alias, status, message) => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('remote-status-changed', { alias, status, message });
    }
    if (status === TunnelStatus.AUTH_REQUIRED) {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('remote-auth-required', { alias, message });
      }
      showWindow();
    }
    if (status === TunnelStatus.CONNECTED) {
      // Mark connected timestamp in configStore
      const machine = configStore.getMachineBySSHAlias(alias);
      if (machine) configStore.updateMachine(machine.id, { lastConnected: new Date().toISOString() });
    }
  });

  // SSH config changes → Window
  sshConfigReader.on('changed', (hosts) => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('ssh-hosts-changed', hosts);
    }
  });
}

// ─── App Lifecycle ───────────────────────────────────────────

app.whenReady().then(() => {
  // Load modules
  configStore = require('./src/config-store');
  hookServer = require('./src/hook-server');
  const sessionModule = require('./src/session-store');
  SessionStore = sessionModule.SessionStore;
  SessionPhase = sessionModule.SessionPhase;
  hookInstaller = require('./src/hook-installer');
  trayManager = require('./src/tray-manager');
  notification = require('./src/notification');
  sshConfigReader = require('./src/ssh-config-reader');
  const tunnelModule = require('./src/tunnel-manager');
  tunnelManager = tunnelModule.TunnelManager;
  TunnelStatus = tunnelModule.TunnelStatus;

  // Load configuration
  configStore.load();

  // Start watching SSH config for host list updates
  sshConfigReader.watch();

  // Setup notification preferences
  notification.setEnabled(configStore.get('enableNotifications'));

  // Create window
  createWindow();

  // Setup IPC
  setupIPC();

  // Create system tray
  trayManager.create({
    onToggleWindow: toggleWindow,
    onQuit: () => { isQuitting = true; },
  });

  // Wire events
  wireEvents();

  // Start hook server
  const port = configStore.get('port') || 51515;
  const listenHost = configStore.get('listenHost') || '127.0.0.1';
  hookServer.start(port, listenHost);

  // Install hooks on local paths
  hookInstaller.installAll();

  // Auto-connect SSH machines that had autoConnect set
  const autoMachines = configStore.getSSHMachines().filter(m => m.autoConnect);
  for (const machine of autoMachines) {
    tunnelManager.connect(machine).catch(err => {
      console.warn(`[Remote] Auto-connect failed for ${machine.sshAlias}:`, err.message);
    });
  }

  // Periodic session cleanup (remove ended sessions after 5 minutes)
  setInterval(() => SessionStore.cleanup(300000), 60000);
});

app.on('before-quit', () => {
  isQuitting = true;
});

app.on('will-quit', () => {
  tunnelManager.disconnectAll();
  sshConfigReader.unwatch();
  hookServer.stop();
  trayManager.destroy();
});

app.on('window-all-closed', (e) => {
  // Don't quit when window is closed - keep tray running
  e.preventDefault?.();
});
