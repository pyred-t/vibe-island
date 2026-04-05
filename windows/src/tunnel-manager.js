/**
 * Tunnel Manager
 * Manages reverse SSH tunnels for remote Claude Code monitoring.
 *
 * For each remote host, spawns:
 *   ssh -N -v -R <port>:localhost:<port> <hostAlias>
 *
 * Also handles:
 * - Hook script installation/update on remote
 * - Authentication failure detection → UI guidance
 * - Auto-reconnect with exponential backoff
 */
const { spawn, exec } = require('child_process');
const { EventEmitter } = require('events');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Status values emitted to the UI
const TunnelStatus = {
  IDLE: 'idle',
  CONNECTING: 'connecting',
  INSTALLING_HOOKS: 'installing_hooks',
  CONNECTED: 'connected',
  AUTH_REQUIRED: 'auth_required',
  PORT_CONFLICT: 'port_conflict',
  ERROR: 'error',
  DISCONNECTING: 'disconnecting',
};

const HOOK_SCRIPT_PATH = path.join(__dirname, '..', 'hooks', 'claude-island-state.py');
// Reconnect delays: 5s, 10s, 20s, 40s, 60s (cap)
const RECONNECT_DELAYS = [5000, 10000, 20000, 40000, 60000];

class TunnelManager extends EventEmitter {
  constructor() {
    super();
    this._tunnels = new Map(); // hostAlias → TunnelState
  }

  // ─── Public API ─────────────────────────────────────────────────

  async connect(hostAlias, port = 51515) {
    if (this._tunnels.has(hostAlias)) {
      const t = this._tunnels.get(hostAlias);
      if (t.status === TunnelStatus.CONNECTED || t.status === TunnelStatus.CONNECTING) {
        return; // Already connected
      }
    }

    this._initTunnel(hostAlias, port);
    await this._doConnect(hostAlias);
  }

  disconnect(hostAlias) {
    const tunnel = this._tunnels.get(hostAlias);
    if (!tunnel) return;

    tunnel.manualDisconnect = true;
    this._setStatus(hostAlias, TunnelStatus.DISCONNECTING);
    clearTimeout(tunnel.retryTimer);

    if (tunnel.process) {
      tunnel.process.kill();
      tunnel.process = null;
    }

    this._tunnels.delete(hostAlias);
    this.emit('disconnected', hostAlias);
  }

  disconnectAll() {
    for (const alias of this._tunnels.keys()) {
      this.disconnect(alias);
    }
  }

  getStatus(hostAlias) {
    return this._tunnels.get(hostAlias)?.status ?? TunnelStatus.IDLE;
  }

  getAllStatuses() {
    const result = {};
    for (const [alias, state] of this._tunnels) {
      result[alias] = state.status;
    }
    return result;
  }

  // ─── Internal ───────────────────────────────────────────────────

  _initTunnel(hostAlias, port) {
    if (!this._tunnels.has(hostAlias)) {
      this._tunnels.set(hostAlias, {
        hostAlias,
        port,
        status: TunnelStatus.IDLE,
        process: null,
        retryTimer: null,
        retryCount: 0,
        manualDisconnect: false,
      });
    }
    const t = this._tunnels.get(hostAlias);
    t.port = port;
    t.manualDisconnect = false;
  }

  async _doConnect(hostAlias) {
    const tunnel = this._tunnels.get(hostAlias);
    if (!tunnel || tunnel.manualDisconnect) return;

    this._setStatus(hostAlias, TunnelStatus.CONNECTING);

    // 1. Check SSH availability
    if (!(await this._checkSSH())) {
      this._setStatus(hostAlias, TunnelStatus.ERROR, 'SSH not found. Please install OpenSSH.');
      this.emit('sshNotFound', hostAlias);
      return;
    }

    // 2. Install/update hook script on remote
    this._setStatus(hostAlias, TunnelStatus.INSTALLING_HOOKS);
    try {
      await this._installHooks(hostAlias);
    } catch (err) {
      // Non-fatal if we can guess it's an auth error — tunnel attempt will reveal it
      console.warn(`[TunnelManager] Hook install failed for ${hostAlias}:`, err.message);
      if (err.message.includes('settings.json')) {
        // Claude Code not initialized on remote
        this._setStatus(hostAlias, TunnelStatus.ERROR, err.message);
        return;
      }
    }

    // 3. Start the reverse tunnel
    this._startTunnel(hostAlias);
  }

  async _checkSSH() {
    try {
      await execAsync('ssh -V', { timeout: 5000 });
      return true;
    } catch (e) {
      // ssh -V writes to stderr but exits 0 on success; handle both
      if (e.stderr && e.stderr.includes('OpenSSH')) return true;
      return false;
    }
  }

  async _sshExec(hostAlias, command) {
    return new Promise((resolve, reject) => {
      // Use a separate ssh connection for exec (not the tunnel connection)
      const args = [
        '-o', 'BatchMode=yes',           // Don't prompt for passwords
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=10',
        hostAlias,
        command
      ];

      const proc = spawn('ssh', args);
      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', d => { stdout += d.toString(); });
      proc.stderr.on('data', d => { stderr += d.toString(); });

      proc.on('close', (code) => {
        if (code === 0) {
          resolve(stdout.trim());
        } else {
          const msg = stderr.trim() || `Exit code ${code}`;
          reject(new Error(msg));
        }
      });

      proc.on('error', reject);
    });
  }

  async _installHooks(hostAlias) {
    const hookScript = fs.readFileSync(HOOK_SCRIPT_PATH, 'utf8');
    const port = this._tunnels.get(hostAlias)?.port ?? 51515;

    // 1. Upload hook script (heredoc)
    // Use a unique delimiter unlikely to appear in the Python script
    const delimiter = 'CLAUDE_ISLAND_HOOK_SCRIPT_EOF';
    const uploadCmd = [
      'mkdir -p ~/.claude/hooks',
      `cat > ~/.claude/hooks/claude-island-state.py << '${delimiter}'`,
      hookScript,
      delimiter,
      'chmod +x ~/.claude/hooks/claude-island-state.py',
    ].join('\n');

    await this._sshExec(hostAlias, uploadCmd);
    console.log(`[TunnelManager] Hook script synced to ${hostAlias}`);

    // 2. Check settings.json exists (don't create it)
    let settingsExist;
    try {
      const result = await this._sshExec(
        hostAlias,
        'test -f ~/.claude/settings.json && echo yes || echo no'
      );
      settingsExist = result.trim() === 'yes';
    } catch (e) {
      settingsExist = false;
    }

    if (!settingsExist) {
      throw new Error(
        'Claude Code config not found on remote.\n' +
        `Please run 'claude' on ${hostAlias} at least once first.`
      );
    }

    // 3. Update hooks in settings.json (Python one-liner, preserve other config)
    const hookEntry = JSON.stringify({
      type: 'command',
      command: `python3 ~/.claude/hooks/claude-island-state.py --port ${port}`,
    });

    const hookEntryWithTimeout = JSON.stringify({
      type: 'command',
      command: `python3 ~/.claude/hooks/claude-island-state.py --port ${port}`,
      timeout: 86400,
    });

    // Events that need to block (have timeout) vs fire-and-forget
    const blockingEvents = ['PreToolUse', 'PermissionRequest'];
    const fireEvents = [
      'UserPromptSubmit', 'PostToolUse', 'Notification',
      'Stop', 'SubagentStop', 'SessionStart', 'SessionEnd', 'PreCompact',
    ];

    const pyLines = [
      'import json,os',
      "p=os.path.expanduser('~/.claude/settings.json')",
      "f=open(p);cfg=json.load(f);f.close()",
      "h=cfg.setdefault('hooks',{})",
    ];

    // Write blocking events (timeout 86400)
    for (const ev of blockingEvents) {
      pyLines.push(
        `h['${ev}']=[{'matcher':'*','hooks':[${hookEntryWithTimeout}]}]`
      );
    }
    // Write fire-and-forget events
    for (const ev of fireEvents) {
      const entry = ev === 'UserPromptSubmit' || ev === 'Stop' || ev === 'SessionStart' || ev === 'SessionEnd'
        ? `[{'hooks':[${hookEntry}]}]`
        : `[{'matcher':'*','hooks':[${hookEntry}]}]`;
      pyLines.push(`h['${ev}']=${entry}`);
    }
    pyLines.push(
      "f=open(p,'w');json.dump(cfg,f,indent=2);f.close()"
    );

    const pyScript = pyLines.join(';');
    await this._sshExec(hostAlias, `python3 -c "${pyScript.replace(/"/g, '\\"')}"`);
    console.log(`[TunnelManager] Hooks configured in settings.json on ${hostAlias}`);
  }

  _startTunnel(hostAlias) {
    const tunnel = this._tunnels.get(hostAlias);
    if (!tunnel) return;

    const { port } = tunnel;

    const args = [
      '-N',                                  // No remote command
      '-v',                                  // Verbose (parse stderr for status)
      '-R', `${port}:localhost:${port}`,     // Reverse forward
      '-o', 'BatchMode=yes',                 // No interactive prompts
      '-o', 'ExitOnForwardFailure=yes',      // Fail fast on port conflict
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', 'ServerAliveInterval=30',
      '-o', 'ServerAliveCountMax=3',
      hostAlias,
    ];

    const proc = spawn('ssh', args);
    tunnel.process = proc;

    let stderrBuf = '';

    proc.stderr.on('data', (data) => {
      stderrBuf += data.toString();

      // Detect connected: reverse tunnel established
      if (stderrBuf.includes('Entering interactive session') ||
          stderrBuf.includes('remote forward success') ||
          stderrBuf.includes('Allocated port')) {
        tunnel.retryCount = 0;
        this._setStatus(hostAlias, TunnelStatus.CONNECTED);
      }

      // Detect auth failure
      if (stderrBuf.includes('Permission denied') ||
          stderrBuf.includes('Authentication failed') ||
          stderrBuf.includes('publickey,')) {
        this._setStatus(hostAlias, TunnelStatus.AUTH_REQUIRED,
          'SSH authentication failed. Add your key to SSH Agent.');
        this.emit('authRequired', hostAlias);
      }

      // Detect port conflict
      if (stderrBuf.includes('remote port forwarding failed') ||
          stderrBuf.includes('Warning: remote port forwarding')) {
        this._setStatus(hostAlias, TunnelStatus.PORT_CONFLICT,
          `Port ${port} already in use on ${hostAlias}.`);
      }
    });

    proc.on('close', (code) => {
      tunnel.process = null;
      if (tunnel.manualDisconnect) return;

      const isAuthError = tunnel.status === TunnelStatus.AUTH_REQUIRED;
      if (isAuthError) return; // Don't auto-retry auth errors; wait for user action

      // Auto-reconnect with backoff
      const delay = RECONNECT_DELAYS[Math.min(tunnel.retryCount, RECONNECT_DELAYS.length - 1)];
      tunnel.retryCount++;

      console.log(`[TunnelManager] ${hostAlias} disconnected (code=${code}), retry in ${delay}ms`);
      this._setStatus(hostAlias, TunnelStatus.CONNECTING,
        `Reconnecting in ${Math.round(delay / 1000)}s...`);

      tunnel.retryTimer = setTimeout(() => {
        this._doConnect(hostAlias);
      }, delay);
    });

    proc.on('error', (err) => {
      console.error(`[TunnelManager] SSH process error for ${hostAlias}:`, err.message);
      this._setStatus(hostAlias, TunnelStatus.ERROR, err.message);
    });
  }

  _setStatus(hostAlias, status, message = '') {
    const tunnel = this._tunnels.get(hostAlias);
    if (tunnel) tunnel.status = status;
    this.emit('statusChanged', hostAlias, status, message);
  }
}

module.exports = { TunnelManager: new TunnelManager(), TunnelStatus };
