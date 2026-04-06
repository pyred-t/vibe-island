/**
 * Claude Island Windows — In-App Notifications Module
 * Floating notification cards with sound support
 * Replaces intrusive Windows toast notifications
 */

const InAppNotifications = (() => {

  // ─── State ────────────────────────────────────────────────────
  let _container = null;
  let _queue = [];
  let _active = [];
  let _audioCtx = null;
  let _mode = 'inapp'; // 'system' | 'inapp' | 'off'
  let _sound = 'pop';  // 'none' | 'pop' | 'ping' | 'bell' | 'chime'

  // ─── Init ─────────────────────────────────────────────────────
  function init() {
    _container = document.getElementById('notificationContainer');
    if (!_container) {
      _container = document.createElement('div');
      _container.id = 'notificationContainer';
      document.body.appendChild(_container);
    }
  }

  function setMode(mode) {
    _mode = mode;
  }

  function setSound(sound) {
    _sound = sound;
  }

  // ─── Audio ────────────────────────────────────────────────────
  function _getAudioCtx() {
    if (!_audioCtx) {
      try { _audioCtx = new (window.AudioContext || window.webkitAudioContext)(); }
      catch (e) { return null; }
    }
    return _audioCtx;
  }

  /**
   * Play a synthesized notification sound.
   * Uses Web Audio API — no external files needed.
   */
  function playSound(type) {
    if (type === 'none') return;
    const ctx = _getAudioCtx();
    if (!ctx) return;

    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);

    switch (type) {
      case 'pop':
        osc.type = 'sine';
        osc.frequency.setValueAtTime(880, now);
        osc.frequency.exponentialRampToValueAtTime(440, now + 0.08);
        gain.gain.setValueAtTime(0.18, now);
        gain.gain.exponentialRampToValueAtTime(0.001, now + 0.12);
        osc.start(now);
        osc.stop(now + 0.12);
        break;

      case 'ping':
        osc.type = 'sine';
        osc.frequency.setValueAtTime(1320, now);
        osc.frequency.exponentialRampToValueAtTime(880, now + 0.2);
        gain.gain.setValueAtTime(0.15, now);
        gain.gain.exponentialRampToValueAtTime(0.001, now + 0.25);
        osc.start(now);
        osc.stop(now + 0.25);
        break;

      case 'bell': {
        osc.type = 'triangle';
        osc.frequency.setValueAtTime(1047, now);
        gain.gain.setValueAtTime(0.2, now);
        gain.gain.exponentialRampToValueAtTime(0.001, now + 0.5);
        osc.start(now);
        osc.stop(now + 0.5);
        break;
      }

      case 'chime': {
        // Two-tone chime
        const osc2 = ctx.createOscillator();
        const gain2 = ctx.createGain();
        osc2.connect(gain2);
        gain2.connect(ctx.destination);

        osc.type = 'sine';
        osc.frequency.setValueAtTime(1047, now);
        gain.gain.setValueAtTime(0.15, now);
        gain.gain.exponentialRampToValueAtTime(0.001, now + 0.4);
        osc.start(now);
        osc.stop(now + 0.4);

        osc2.type = 'sine';
        osc2.frequency.setValueAtTime(1319, now + 0.15);
        gain2.gain.setValueAtTime(0, now);
        gain2.gain.setValueAtTime(0.15, now + 0.15);
        gain2.gain.exponentialRampToValueAtTime(0.001, now + 0.55);
        osc2.start(now + 0.15);
        osc2.stop(now + 0.55);
        break;
      }
    }
  }

  // ─── Show notification ────────────────────────────────────────
  /**
   * Show an in-app notification card.
   * @param {object} opts
   * @param {string} opts.title
   * @param {string} opts.body
   * @param {'info'|'warning'|'success'} [opts.type]
   * @param {number} [opts.duration]  ms before auto-dismiss (default 6000)
   * @param {string} [opts.sessionId] if set, clicking focuses that session
   * @param {Function} [opts.onClick]
   */
  function show(opts) {
    if (_mode === 'off') return;
    if (_mode === 'system') {
      _showSystemNotification(opts);
      return;
    }

    if (!_container) init();

    playSound(_sound);

    const card = _createCard(opts);
    _container.appendChild(card);
    _active.push(card);

    // Animate in
    requestAnimationFrame(() => {
      requestAnimationFrame(() => card.classList.add('visible'));
    });

    // Auto-dismiss
    const duration = opts.duration || 6000;
    const timer = setTimeout(() => _dismiss(card), duration);
    card._dismissTimer = timer;

    // Pause timer on hover
    card.addEventListener('mouseenter', () => {
      clearTimeout(card._dismissTimer);
    });
    card.addEventListener('mouseleave', () => {
      card._dismissTimer = setTimeout(() => _dismiss(card), 2000);
    });
  }

  function _createCard(opts) {
    const card = document.createElement('div');
    card.className = `notif-card notif-${opts.type || 'info'}`;

    const icon = _iconForType(opts.type);
    card.innerHTML = `
      <div class="notif-icon">${icon}</div>
      <div class="notif-body">
        <div class="notif-title">${_esc(opts.title)}</div>
        ${opts.body ? `<div class="notif-text">${_esc(opts.body)}</div>` : ''}
      </div>
      <button class="notif-close" title="Dismiss">✕</button>
    `;

    card.querySelector('.notif-close').addEventListener('click', (e) => {
      e.stopPropagation();
      _dismiss(card);
    });

    if (opts.onClick || opts.sessionId) {
      card.style.cursor = 'pointer';
      card.addEventListener('click', () => {
        _dismiss(card);
        if (opts.onClick) opts.onClick();
      });
    }

    return card;
  }

  function _iconForType(type) {
    switch (type) {
      case 'warning': return '⚠';
      case 'success': return '✓';
      default:        return 'ℹ';
    }
  }

  function _dismiss(card) {
    clearTimeout(card._dismissTimer);
    card.classList.remove('visible');
    card.classList.add('dismissing');
    setTimeout(() => {
      card.remove();
      _active = _active.filter(c => c !== card);
    }, 300);
  }

  function _showSystemNotification(opts) {
    try {
      const { Notification } = require('electron');
      if (Notification.isSupported()) {
        new Notification({ title: opts.title, body: opts.body || '' }).show();
      }
    } catch (e) {
      // Renderer can't directly use electron Notification — handled by main process
    }
  }

  function _esc(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ─── Convenience helpers ──────────────────────────────────────
  function permissionRequired(toolName, cwd, sessionId) {
    const { t } = i18n;
    show({
      title: t('notif_permRequired'),
      body: `${toolName} — ${_shortenPath(cwd)}`,
      type: 'warning',
      duration: 10000,
      sessionId,
    });
  }

  function claudeReady(cwd, sessionId) {
    const { t } = i18n;
    show({
      title: t('notif_claudeReady'),
      body: `${t('notif_waitingInput')} — ${_shortenPath(cwd)}`,
      type: 'success',
      duration: 5000,
      sessionId,
    });
  }

  function compacting(cwd) {
    const { t } = i18n;
    show({
      title: t('notif_compacting'),
      body: _shortenPath(cwd),
      type: 'info',
      duration: 4000,
    });
  }

  function _shortenPath(p) {
    if (!p) return '';
    const parts = p.replace(/\\/g, '/').split('/').filter(Boolean);
    return parts.length <= 2 ? parts.join('/') : '…/' + parts.slice(-2).join('/');
  }

  return {
    init,
    show,
    setMode,
    setSound,
    playSound,
    permissionRequired,
    claudeReady,
    compacting,
  };
})();
