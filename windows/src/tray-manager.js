/**
 * System Tray Manager for Claude Island Windows
 * Manages the tray icon with dynamic status indicators
 */
const { Tray, Menu, nativeImage, app } = require('electron');
const path = require('path');
const { SessionPhase } = require('./session-store');

class TrayManager {
  constructor() {
    this._tray = null;
    this._onToggleWindow = null;
    this._onQuit = null;
    this._currentStatus = 'idle';
  }

  /**
   * Create the system tray icon
   */
  create({ onToggleWindow, onQuit, onSettings }) {
    this._onToggleWindow = onToggleWindow;
    this._onQuit = onQuit;

    const iconPath = path.join(__dirname, '..', 'assets', 'tray-idle.png');
    let trayIcon;

    try {
      trayIcon = nativeImage.createFromPath(iconPath);
      if (trayIcon.isEmpty()) throw new Error('Icon empty');
      trayIcon = trayIcon.resize({ width: 16, height: 16 });
    } catch (e) {
      // Create a default icon if file doesn't exist
      trayIcon = this._createDefaultIcon('idle');
    }

    this._tray = new Tray(trayIcon);
    this._tray.setToolTip('Claude Island — No active sessions');

    this._tray.on('click', () => {
      if (this._onToggleWindow) this._onToggleWindow();
    });

    this._updateContextMenu();
  }

  /**
   * Update the tray status based on active sessions
   */
  updateStatus(sessions) {
    if (!this._tray) return;

    const active = sessions.filter(s => s.phase !== SessionPhase.ENDED);
    const pending = active.filter(s =>
      s.phase === SessionPhase.WAITING_FOR_APPROVAL ||
      s.phase === SessionPhase.WAITING_FOR_INPUT
    );
    const processing = active.filter(s => s.phase === SessionPhase.PROCESSING);

    let newStatus;
    let tooltip;

    if (pending.some(s => s.phase === SessionPhase.WAITING_FOR_APPROVAL)) {
      newStatus = 'waiting';
      tooltip = `Claude Island — ⚠️ ${pending.length} permission(s) pending`;
    } else if (processing.length > 0) {
      newStatus = 'active';
      tooltip = `Claude Island — 🔄 ${processing.length} session(s) active`;
    } else if (active.length > 0) {
      newStatus = 'idle';
      tooltip = `Claude Island — ${active.length} session(s)`;
    } else {
      newStatus = 'idle';
      tooltip = 'Claude Island — No active sessions';
    }

    this._tray.setToolTip(tooltip);

    if (newStatus !== this._currentStatus) {
      this._currentStatus = newStatus;
      this._tray.setImage(this._createDefaultIcon(newStatus));
    }
  }

  /**
   * Create a pixel-art style tray icon with a crab silhouette
   * @param {'idle'|'active'|'waiting'} status
   */
  _createDefaultIcon(status) {
    const size = 128;
    const buf = Buffer.alloc(size * size * 4, 0);

    let r, g, b;
    switch (status) {
      case 'active':  r = 99;  g = 102; b = 241; break; // Indigo
      case 'waiting': r = 245; g = 158; b = 11;  break; // Amber
      default:        r = 100; g = 116; b = 139; break; // Slate
    }

    const setpx = (x, y, pr, pg, pb, pa) => {
      if (x < 0 || x >= size || y < 0 || y >= size) return;
      const i = (y * size + x) * 4;
      buf[i] = pr; buf[i+1] = pg; buf[i+2] = pb; buf[i+3] = pa;
    };

    // Rounded-rect background
    const pad = 6, cr = 22;
    for (let y = pad; y < size - pad; y++) {
      for (let x = pad; x < size - pad; x++) {
        const dx = Math.max(0, Math.max(pad + cr - x, x - (size - pad - cr - 1)));
        const dy = Math.max(0, Math.max(pad + cr - y, y - (size - pad - cr - 1)));
        if (Math.hypot(dx, dy) <= cr) setpx(x, y, r, g, b, 255);
      }
    }

    // Pixel ghost — simple silhouette, very readable at 16x16
    // 16x16 logical grid, each cell = 8x8 actual pixels
    const cell = size / 16;
    const block = (gx, gy, pr, pg, pb, pa) => {
      const ox = Math.round(gx * cell);
      const oy = Math.round(gy * cell);
      const cs = Math.round(cell) - 1;
      for (let dy = 0; dy < cs; dy++)
        for (let dx = 0; dx < cs; dx++)
          setpx(ox + dx, oy + dy, pr, pg, pb, pa);
    };

    const W = [255, 255, 255, 240];
    const E = [r, g, b, 255]; // eye = bg color (cutout)

    // Top dome
    block(5,2,...W); block(6,2,...W); block(7,2,...W); block(8,2,...W); block(9,2,...W); block(10,2,...W);
    block(4,3,...W); block(5,3,...W); block(6,3,...W); block(7,3,...W); block(8,3,...W); block(9,3,...W); block(10,3,...W); block(11,3,...W);
    // Body rows 4–9
    for (let row = 4; row <= 9; row++)
      for (let col = 4; col <= 11; col++) block(col, row, ...W);
    // Wavy skirt
    block(4,10,...W); block(5,10,...W);
    block(7,10,...W); block(8,10,...W);
    block(10,10,...W); block(11,10,...W);
    // Eyes (2x2 cutout each)
    block(6,5,...E); block(7,5,...E); block(6,6,...E); block(7,6,...E);
    block(9,5,...E); block(10,5,...E); block(9,6,...E); block(10,6,...E);

    return nativeImage.createFromBuffer(buf, { width: size, height: size, scaleFactor: 4.0 });
  }

  _updateContextMenu() {
    if (!this._tray) return;

    const contextMenu = Menu.buildFromTemplate([
      { label: 'Show / Hide', click: () => this._onToggleWindow?.() },
      { type: 'separator' },
      { label: 'Quit Claude Island', click: () => { this._onQuit?.(); app.quit(); } },
    ]);

    this._tray.setContextMenu(contextMenu);
  }

  destroy() {
    if (this._tray) {
      this._tray.destroy();
      this._tray = null;
    }
  }
}

module.exports = new TrayManager();
