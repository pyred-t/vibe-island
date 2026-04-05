/**
 * Claude Island for Windows — Main Process
 * System tray app with popup panel for Claude Code session monitoring
 */

// Electron's built-in modules should be available at this point
// when running via electron.exe
const { app, BrowserWindow, ipcMain, screen, dialog } = require('electron');
const path = require('path');

let configStore, hookServer, SessionStore, SessionPhase, hookInstaller, trayManager, notification;

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
  const winHeight = 520;

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
  mainWindow.focus();
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

  ipcMain.handle('archive-session', (_event, sessionId) => {
    SessionStore.removeSession(sessionId);
    return true;
  });

  ipcMain.handle('get-config', () => configStore.getAll());

  ipcMain.handle('set-config', (_event, key, value) => {
    configStore.set(key, value);
    return true;
  });

  ipcMain.handle('add-claude-path', (_event, newPath) => {
    configStore.addClaudePath(newPath);
    return configStore.get('claudeConfigPaths');
  });

  ipcMain.handle('remove-claude-path', (_event, pathToRemove) => {
    configStore.removeClaudePath(pathToRemove);
    return configStore.get('claudeConfigPaths');
  });

  ipcMain.handle('install-hooks', () => {
    return hookInstaller.installAll();
  });

  ipcMain.handle('get-hook-status', () => {
    const paths = configStore.get('claudeConfigPaths') || [];
    return paths.map(p => ({
      path: p,
      installed: hookInstaller.isInstalled(p),
      exists: (() => { try { return require('fs').existsSync(p); } catch { return false; } })(),
    }));
  });

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
    console.log(`[Session] New session: ${session.sessionId} cwd=${session.cwd}`);
    // Auto-show window when a new session is created
    showWindow();
  });

  SessionStore.on('phaseChanged', (session, prevPhase, newPhase) => {
    console.log(`[Session] ${session.sessionId} phase: ${prevPhase} -> ${newPhase}`);
    notification.onPhaseChanged(session, prevPhase, newPhase);

    // Auto-show window on permission request
    if (newPhase === SessionPhase.WAITING_FOR_APPROVAL) {
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

  // Load configuration
  configStore.load();

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
  hookServer.start(port);

  // Install hooks on first launch
  hookInstaller.installAll();

  // Periodic session cleanup (remove ended sessions after 5 minutes)
  setInterval(() => SessionStore.cleanup(300000), 60000);
});

app.on('before-quit', () => {
  isQuitting = true;
});

app.on('will-quit', () => {
  hookServer.stop();
  trayManager.destroy();
});

app.on('window-all-closed', (e) => {
  // Don't quit when window is closed - keep tray running
  e.preventDefault?.();
});
