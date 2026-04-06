/**
 * Claude Island Windows — Pixel Icons Module
 * Canvas-based pixel-art status icons + Claude crab character
 * Mirrors the macOS ClaudeIsland StatusIcons.swift implementation
 */

const PixelIcons = (() => {

  // ─── Color palette ────────────────────────────────────────────
  const COLORS = {
    green:  '#16a34a',  // deeper green
    amber:  '#d97706',  // deeper amber
    cyan:   '#0284c7',  // deeper cyan/blue
    dim:    '#52525b',  // darker gray
    accent: '#6366f1',  // deeper indigo
    white:  '#f0f0f5',
  };

  /**
   * Draw a pixel-art icon onto a canvas element.
   * @param {HTMLCanvasElement} canvas
   * @param {Array<[number,number]>} solidDots  - grid coords (0-30 range)
   * @param {Array<[number,number]>} fadedDots  - grid coords at 0.4 opacity
   * @param {string} color  - CSS color string
   * @param {number} size   - canvas logical size in px
   */
  function drawPixelIcon(canvas, solidDots, fadedDots, color, size) {
    const dpr = window.devicePixelRatio || 1;
    canvas.width  = size * dpr;
    canvas.height = size * dpr;
    canvas.style.width  = size + 'px';
    canvas.style.height = size + 'px';

    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, size, size);

    // Rounded background pill
    const pad = 2;
    const r = size * 0.28;
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = color;
    _roundRect(ctx, pad, pad, size - pad * 2, size - pad * 2, r);
    ctx.fill();
    ctx.globalAlpha = 1.0;

    const scale   = size / 30;
    const dotSize = Math.max(2, Math.round(3.5 * scale));

    function dot(x, y, alpha) {
      ctx.globalAlpha = alpha;
      ctx.fillStyle = color;
      const px = Math.round(x * scale - dotSize / 2);
      const py = Math.round(y * scale - dotSize / 2);
      ctx.fillRect(px, py, dotSize, dotSize);
    }

    for (const [x, y] of solidDots) dot(x, y, 1.0);
    for (const [x, y] of (fadedDots || [])) dot(x, y, 0.45);
    ctx.globalAlpha = 1.0;
  }

  function _roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  // ─── WaitingForInput — speech bubble (green) ──────────────────
  function createWaitingForInputIcon(size = 18) {
    const canvas = document.createElement('canvas');
    const solid = [
      [3,3],[7,3],[11,3],[15,3],[19,3],[23,3],[27,3],
      [3,7],[3,11],[3,15],[3,19],[3,23],[3,27],
      [27,7],[27,11],[27,15],[27,19],
      [7,23],
      [11,19],[15,19],[19,19],[23,19],
    ];
    const faded = [
      [7,11],[7,15],[7,19],
      [11,11],[11,15],
      [15,11],[15,15],
      [19,15],
    ];
    drawPixelIcon(canvas, solid, faded, COLORS.green, size);
    return canvas;
  }

  // ─── WaitingForApproval — hand/stop (amber) ───────────────────
  function createWaitingForApprovalIcon(size = 18) {
    const canvas = document.createElement('canvas');
    const solid = [
      [7,7],[7,11],
      [11,3],
      [15,3],[19,3],
      [23,7],[23,11],
      [15,19],[15,27],
      [19,15],
    ];
    drawPixelIcon(canvas, solid, [], COLORS.amber, size);
    return canvas;
  }

  // ─── Running — hourglass (cyan, animated) ─────────────────────
  function createRunningIcon(size = 18) {
    const canvas = document.createElement('canvas');
    const solid = [
      [15,3],
      [7,7],[15,7],[23,7],
      [15,11],[15,19],
      [3,15],[7,15],[11,15],[19,15],[23,15],[27,15],
      [7,23],[15,23],[23,23],
      [15,27],
    ];
    const faded = [
      [11,11],[19,11],
      [11,19],[19,19],
    ];
    drawPixelIcon(canvas, solid, faded, COLORS.cyan, size);

    // Spin animation via CSS
    canvas.style.animation = 'spin-icon 2s linear infinite';
    return canvas;
  }

  // ─── Idle — horizontal dash (dim) ─────────────────────────────
  function createIdleIcon(size = 18) {
    const canvas = document.createElement('canvas');
    drawPixelIcon(canvas, [[11,15],[15,15],[19,15]], [], COLORS.dim, size);
    return canvas;
  }

  // ─── Compacting — vertical bars (cyan, pulsing) ───────────────
  function createCompactingIcon(size = 18) {
    const canvas = document.createElement('canvas');
    const solid = [
      [7,7],[7,11],[7,15],[7,19],[7,23],
      [15,11],[15,15],[15,19],
      [23,15],[23,19],[23,23],
    ];
    drawPixelIcon(canvas, solid, [], COLORS.cyan, size);
    canvas.style.animation = 'pulse-icon 1.5s ease-in-out infinite';
    return canvas;
  }

  /**
   * Create the appropriate icon canvas for a given session phase.
   * @param {string} phase
   * @param {number} size
   * @returns {HTMLCanvasElement}
   */
  function createStatusIcon(phase, size = 18) {
    switch (phase) {
      case 'waiting_for_input':    return createWaitingForInputIcon(size);
      case 'waiting_for_approval': return createWaitingForApprovalIcon(size);
      case 'processing':           return createRunningIcon(size);
      case 'compacting':           return createCompactingIcon(size);
      default:                     return createIdleIcon(size);
    }
  }

  // ─── Claude Crab Icon ─────────────────────────────────────────
  /**
   * Draw the Claude crab pixel character onto a canvas.
   * @param {HTMLCanvasElement} canvas
   * @param {string} color
   * @param {number} size
   * @param {boolean} animateLegs
   */
  function drawCrab(canvas, color, size, animateLegs) {
    const dpr = window.devicePixelRatio || 1;
    canvas.width  = size * dpr;
    canvas.height = size * dpr;
    canvas.style.width  = size + 'px';
    canvas.style.height = size + 'px';

    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);

    // Store for animation
    canvas._crabColor = color;
    canvas._crabSize  = size;
    canvas._crabAnim  = animateLegs;
    canvas._crabFrame = 0;

    _renderCrab(ctx, color, size, 0);

    if (animateLegs) {
      _startCrabAnimation(canvas);
    }
  }

  function _renderCrab(ctx, color, size, frame) {
    ctx.clearRect(0, 0, size, size);

    // Rounded background
    const pad = 1;
    const r = size * 0.28;
    ctx.globalAlpha = 0.18;
    ctx.fillStyle = color;
    _roundRect(ctx, pad, pad, size - pad * 2, size - pad * 2, r);
    ctx.fill();
    ctx.globalAlpha = 1.0;

    const s = size / 32;
    const d = Math.max(2, Math.round(3 * s)); // bigger dots

    function dot(x, y, alpha) {
      ctx.globalAlpha = alpha || 1;
      ctx.fillStyle = color;
      ctx.fillRect(Math.round(x * s - d / 2), Math.round(y * s - d / 2), d, d);
    }

    // Body (center mass)
    const body = [
      [10,12],[14,12],[18,12],[22,12],
      [8,16],[12,16],[16,16],[20,16],[24,16],
      [10,20],[14,20],[18,20],[22,20],
    ];

    // Eyes
    const eyes = [[10,8],[22,8]];

    // Claws (left and right)
    const clawsL = [[4,12],[4,16],[6,10]];
    const clawsR = [[28,12],[28,16],[26,10]];

    // Legs — two frames for walking animation
    const legsFrame0 = [
      [6,20],[4,22],[4,26],   // left legs
      [26,20],[28,22],[28,26], // right legs
    ];
    const legsFrame1 = [
      [6,22],[4,24],[4,28],
      [26,22],[28,24],[28,28],
    ];

    const legs = (frame % 2 === 0) ? legsFrame0 : legsFrame1;

    for (const [x, y] of body)   dot(x, y, 1.0);
    for (const [x, y] of eyes)   dot(x, y, 1.0);
    for (const [x, y] of clawsL) dot(x, y, 0.85);
    for (const [x, y] of clawsR) dot(x, y, 0.85);
    for (const [x, y] of legs)   dot(x, y, 0.7);

    ctx.globalAlpha = 1;
  }

  function _startCrabAnimation(canvas) {
    if (canvas._crabTimer) return;
    canvas._crabTimer = setInterval(() => {
      if (!canvas.isConnected) {
        clearInterval(canvas._crabTimer);
        canvas._crabTimer = null;
        return;
      }
      canvas._crabFrame++;
      const ctx = canvas.getContext('2d');
      ctx.setTransform(window.devicePixelRatio || 1, 0, 0, window.devicePixelRatio || 1, 0, 0);
      _renderCrab(ctx, canvas._crabColor, canvas._crabSize, canvas._crabFrame);
    }, 400);
  }

  /**
   * Create a crab icon element.
   * @param {number} size
   * @param {string} color
   * @param {boolean} animateLegs
   * @returns {HTMLCanvasElement}
   */
  function createCrabIcon(size = 20, color = COLORS.accent, animateLegs = false) {
    const canvas = document.createElement('canvas');
    canvas.className = 'crab-icon';
    drawCrab(canvas, color, size, animateLegs);
    return canvas;
  }

  /**
   * Update an existing crab canvas (e.g. when phase changes).
   * @param {HTMLCanvasElement} canvas
   * @param {string} color
   * @param {boolean} animateLegs
   */
  function updateCrabIcon(canvas, color, animateLegs) {
    if (canvas._crabTimer) {
      clearInterval(canvas._crabTimer);
      canvas._crabTimer = null;
    }
    canvas._crabColor = color;
    canvas._crabAnim  = animateLegs;
    canvas._crabFrame = 0;
    const ctx = canvas.getContext('2d');
    ctx.setTransform(window.devicePixelRatio || 1, 0, 0, window.devicePixelRatio || 1, 0, 0);
    _renderCrab(ctx, color, canvas._crabSize, 0);
    if (animateLegs) _startCrabAnimation(canvas);
  }

  /**
   * Get the crab color for a given overall app status.
   * @param {'idle'|'active'|'waiting'} status
   * @returns {string}
   */
  function crabColorForStatus(status) {
    switch (status) {
      case 'waiting': return COLORS.amber;
      case 'active':  return COLORS.accent;
      default:        return COLORS.dim;
    }
  }

  return {
    createStatusIcon,
    createCrabIcon,
    updateCrabIcon,
    drawCrab,
    crabColorForStatus,
    COLORS,
  };
})();
