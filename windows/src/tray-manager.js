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
   * Create a programmatic tray icon with status indicator
   */
  _createDefaultIcon(status) {
    // Create a 32x32 icon with a colored circle
    const size = 32;
    const canvas = Buffer.alloc(size * size * 4, 0);

    let r, g, b;
    switch (status) {
      case 'active':
        r = 99; g = 102; b = 241; // Indigo
        break;
      case 'waiting':
        r = 245; g = 158; b = 11; // Amber
        break;
      default:
        r = 148; g = 163; b = 184; // Gray
    }

    // Draw a filled circle
    const cx = size / 2, cy = size / 2, radius = size / 2 - 2;
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx = x - cx, dy = y - cy;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist <= radius) {
          const idx = (y * size + x) * 4;
          // Anti-aliasing at edges
          const alpha = dist > radius - 1 ? Math.max(0, (radius - dist)) * 255 : 255;
          canvas[idx] = r;       // R
          canvas[idx + 1] = g;   // G
          canvas[idx + 2] = b;   // B
          canvas[idx + 3] = Math.round(alpha); // A
        }
      }
    }

    // Add a subtle inner highlight for depth
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx = x - cx + 3, dy = y - cy + 3;
        const dist = Math.sqrt(dx * dx + dy * dy);

        if (dist <= radius * 0.5) {
          const idx = (y * size + x) * 4;
          if (canvas[idx + 3] > 0) {
            const blend = 0.15 * (1 - dist / (radius * 0.5));
            canvas[idx] = Math.min(255, canvas[idx] + 255 * blend);
            canvas[idx + 1] = Math.min(255, canvas[idx + 1] + 255 * blend);
            canvas[idx + 2] = Math.min(255, canvas[idx + 2] + 255 * blend);
          }
        }
      }
    }

    return nativeImage.createFromBuffer(canvas, { width: size, height: size });
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
