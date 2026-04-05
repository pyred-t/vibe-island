/**
 * Notification handler for Claude Island Windows
 * Sends Windows toast notifications for session events
 */
const { Notification } = require('electron');
const { SessionPhase } = require('./session-store');

class NotificationHandler {
  constructor() {
    this._enabled = true;
    this._lastNotifications = new Map(); // Prevent rapid duplicates
  }

  setEnabled(enabled) {
    this._enabled = enabled;
  }

  /**
   * Called when a session phase changes
   */
  onPhaseChanged(session, prevPhase, newPhase) {
    if (!this._enabled) return;
    if (!Notification.isSupported()) return;

    const dedupKey = `${session.sessionId}-${newPhase}`;
    const now = Date.now();
    const lastTime = this._lastNotifications.get(dedupKey);
    if (lastTime && now - lastTime < 3000) return; // Dedup within 3s
    this._lastNotifications.set(dedupKey, now);

    // Clean old entries
    if (this._lastNotifications.size > 100) {
      for (const [key, time] of this._lastNotifications) {
        if (now - time > 30000) this._lastNotifications.delete(key);
      }
    }

    const cwd = session.cwd ? this._shortenPath(session.cwd) : 'Unknown';

    switch (newPhase) {
      case SessionPhase.WAITING_FOR_APPROVAL:
        this._show({
          title: '🔐 Permission Required',
          body: `${session.activePermission?.toolName || 'Tool'} needs approval\n${cwd}`,
          urgency: 'critical',
        });
        break;

      case SessionPhase.WAITING_FOR_INPUT:
        if (prevPhase === SessionPhase.PROCESSING) {
          this._show({
            title: '✅ Claude is ready',
            body: `Waiting for your input\n${cwd}`,
          });
        }
        break;

      case SessionPhase.COMPACTING:
        this._show({
          title: '📦 Compacting context',
          body: cwd,
        });
        break;
    }
  }

  /**
   * Called for explicit notification events
   */
  onNotification(session) {
    if (!this._enabled) return;
    if (!Notification.isSupported()) return;
    if (!session.lastNotification) return;

    const cwd = session.cwd ? this._shortenPath(session.cwd) : '';

    this._show({
      title: `Claude Code`,
      body: session.lastNotification.message || session.lastNotification.type || 'Notification',
    });
  }

  _show(options) {
    try {
      const notification = new Notification({
        title: options.title,
        body: options.body,
        silent: false,
        urgency: options.urgency || 'normal',
      });
      notification.show();
    } catch (err) {
      console.error('Failed to show notification:', err);
    }
  }

  _shortenPath(p) {
    if (!p) return '';
    // Show last 2 path components
    const parts = p.replace(/\\/g, '/').split('/').filter(Boolean);
    if (parts.length <= 2) return parts.join('/');
    return '…/' + parts.slice(-2).join('/');
  }
}

module.exports = new NotificationHandler();
