/**
 * Tunnel Manager
 * Manages reverse SSH tunnels for remote Claude Code monitoring.
 *
 * For each remote machine, spawns:
 *   ssh -N -v -R <port>:localhost:<port> <sshAlias>
 *
 * Also handles:
 * - Hook script installation/update to each of machine.claudePaths
 * - Authentication failure detection → UI guidance
 * - Auto-reconnect with exponential backoff
 */
const { spawn, exec } = require('child_process');
const { EventEmitter } = require('events');
const fs = require('fs');
const path = require('path');
const { promisify } = require('util');

const execAsync = promisify(exec);

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
const RECONNECT_DELAYS = [5000, 10000, 20000, 40000, 60000];

class TunnelManager extends EventEmitter {
  constructor() {
    super();
    this._tunnels = new Map(); // sshAlias → TunnelState
  }

  // ─── Public API ──────────────────────────────────────────────────

  /**
   * Connect tunnel for a machine config object.
   * machine must have: { sshAlias, port, claudePaths }
   */
  async connect(machine) {
    const hostAlias = machine.sshAlias;
    if (!hostAlias) throw new Error('machine.sshAlias is required');

    if (this._tunnels.has(hostAlias)) {
      const t = this._tunnels.get(hostAlias);
      if (t.status === TunnelStatus.CONNECTED || t.status === TunnelStatus.CONNECTING) {
        return;
      }
    }

    this._initTunnel(machine);
    await this._doConnect(hostAlias);
  }

  /**
   * Force manually synchronize hooks for a connected tunnel.
   */
  async forceInstallHooks(hostAlias) {
    if (!this._tunnels.has(hostAlias)) throw new Error('Machine not initialzed. Connect first.');
    await this._installHooks(hostAlias);
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
    for (const alias of [...this._tunnels.keys()]) {
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

  // ─── Internal ────────────────────────────────────────────────────

  _initTunnel(machine) {
    const hostAlias = machine.sshAlias;
    const port = machine.port || 51515;

    if (!this._tunnels.has(hostAlias)) {
      this._tunnels.set(hostAlias, {
        hostAlias,
        machine,
        port,
        status: TunnelStatus.IDLE,
        process: null,
        retryTimer: null,
        retryCount: 0,
        manualDisconnect: false,
      });
    } else {
      const t = this._tunnels.get(hostAlias);
      t.machine = machine;
      t.port = port;
      t.manualDisconnect = false;
    }
  }

  async _doConnect(hostAlias) {
    const tunnel = this._tunnels.get(hostAlias);
    if (!tunnel || tunnel.manualDisconnect) return;

    this._setStatus(hostAlias, TunnelStatus.CONNECTING);

    if (!(await this._checkSSH())) {
      this._setStatus(hostAlias, TunnelStatus.ERROR, 'SSH not found. Please install OpenSSH.');
      this.emit('sshNotFound', hostAlias);
      return;
    }

    this._setStatus(hostAlias, TunnelStatus.INSTALLING_HOOKS);
    try {
      await this._installHooks(hostAlias);
    } catch (err) {
      console.warn(`[TunnelManager] Hook install failed for ${hostAlias}:`, err.message);
      if (err.message.includes('settings.json') || err.message.includes('at least once')) {
        this._setStatus(hostAlias, TunnelStatus.ERROR, err.message);
        return;
      }
      // Auth error will be detected by the tunnel stderr — proceed anyway
    }

    // Kill any stale process on the remote port (left over from previous sessions)
    try {
      await this._sshExec(hostAlias,
        `fuser -k ${port}/tcp 2>/dev/null; sleep 0.3; true`);
    } catch { /* ignore if fuser not available */ }

    this._startTunnel(hostAlias);
  }

  async _checkSSH() {
    try {
      await execAsync('ssh -V', { timeout: 5000 });
      return true;
    } catch (e) {
      if (e.stderr && e.stderr.includes('OpenSSH')) return true;
      return false;
    }
  }

  async _sshExec(hostAlias, command) {
    return new Promise((resolve, reject) => {
      const args = [
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=10',
        hostAlias,
        command,
      ];

      const proc = spawn('ssh', args);
      let stdout = '';
      let stderr = '';

      proc.stdout.on('data', d => { stdout += d.toString(); });
      proc.stderr.on('data', d => { stderr += d.toString(); });

      proc.on('close', code => {
        if (code === 0) resolve(stdout.trim());
        else reject(new Error(stderr.trim() || `Exit code ${code}`));
      });

      proc.on('error', reject);
    });
  }

  async _installHooks(hostAlias) {
    const tunnel = this._tunnels.get(hostAlias);
    const machine = tunnel?.machine;
    const port = tunnel?.port ?? 51515;
    const hookScript = fs.readFileSync(HOOK_SCRIPT_PATH, 'utf8');

    // Default to ~/.claude if no paths configured
    const claudePaths = machine?.claudePaths?.length ? machine.claudePaths : ['~/.claude'];

    for (const claudePath of claudePaths) {
      const delimiter = 'CLAUDE_ISLAND_HOOK_EOF';
      const uploadCmd = [
        `mkdir -p ${claudePath}/hooks`,
        `cat > ${claudePath}/hooks/claude-island-state.py << '${delimiter}'`,
        hookScript,
        delimiter,
        `chmod +x ${claudePath}/hooks/claude-island-state.py`,
      ].join('\n');

      await this._sshExec(hostAlias, uploadCmd);
      console.log(`[TunnelManager] Hook script synced to ${hostAlias}:${claudePath}`);

      // Check settings.json exists (don't create it)
      let settingsExist = false;
      try {
        const r = await this._sshExec(hostAlias, `test -f ${claudePath}/settings.json && echo yes || echo no`);
        settingsExist = r.trim() === 'yes';
      } catch { /* ignore */ }

      if (!settingsExist) {
        throw new Error(
          `Claude Code config not found at ${claudePath}/settings.json on ${hostAlias}.\n` +
          `Please run 'claude' on the remote machine at least once first.`
        );
      }

      // Update settings.json hooks using Python (preserves other config)
      const hookCmd = `python3 ${claudePath}/hooks/claude-island-state.py --port ${port}`;
      const py = [
        'import json,os',
        `p=os.path.expanduser("${claudePath}/settings.json")`,
        'with open(p) as f: cfg=json.load(f)',
        "h=cfg.setdefault('hooks',{})",
        // Blocking events (timeout)
        `h['PreToolUse']=[{'matcher':'*','hooks':[{'type':'command','command':'${hookCmd}','timeout':86400}]}]`,
        `h['PermissionRequest']=[{'matcher':'*','hooks':[{'type':'command','command':'${hookCmd}','timeout':86400}]}]`,
        // Fire-and-forget events
        `h['PostToolUse']=[{'matcher':'*','hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['Notification']=[{'matcher':'*','hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['UserPromptSubmit']=[{'hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['Stop']=[{'hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['SubagentStop']=[{'hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['SessionStart']=[{'hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['SessionEnd']=[{'hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        `h['PreCompact']=[{'matcher':'auto','hooks':[{'type':'command','command':'${hookCmd}'}]},{'matcher':'manual','hooks':[{'type':'command','command':'${hookCmd}'}]}]`,
        "with open(p,'w') as f: json.dump(cfg,f,indent=2)",
      ].join('\n');

      // Use heredoc to pass the python script — avoids quoting hell
      const pyDelimiter = 'CLAUDE_ISLAND_PY_EOF';
      const pyCmd = `python3 << '${pyDelimiter}'\n${py}\n${pyDelimiter}`;
      await this._sshExec(hostAlias, pyCmd);
      console.log(`[TunnelManager] Hooks configured in ${claudePath}/settings.json on ${hostAlias}`);
    }
  }

  _startTunnel(hostAlias) {
    const tunnel = this._tunnels.get(hostAlias);
    if (!tunnel) return;

    const { port } = tunnel;

    const args = [
      '-N', '-v',
      '-R', `${port}:127.0.0.1:${port}`,
      '-o', 'BatchMode=yes',
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', 'ServerAliveInterval=30',
      '-o', 'ServerAliveCountMax=3',
      hostAlias,
    ];

    const proc = spawn('ssh', args);
    tunnel.process = proc;

    let stderrBuf = '';

    proc.stderr.on('data', data => {
      stderrBuf += data.toString();

      if (stderrBuf.includes('Entering interactive session') ||
          stderrBuf.includes('remote forward success') ||
          stderrBuf.includes('Allocated port')) {
        tunnel.retryCount = 0;
        this._setStatus(hostAlias, TunnelStatus.CONNECTED);
      }

      if (stderrBuf.includes('Permission denied') ||
          stderrBuf.includes('Authentication failed')) {
        this._setStatus(hostAlias, TunnelStatus.AUTH_REQUIRED,
          'SSH authentication failed. Add your key to SSH Agent.');
        this.emit('authRequired', hostAlias);
      }

      if (stderrBuf.includes('remote port forwarding failed') ||
          stderrBuf.includes('Warning: remote port forwarding')) {
        this._setStatus(hostAlias, TunnelStatus.PORT_CONFLICT,
          `Port ${port} already in use on ${hostAlias}.`);
      }
    });

    proc.on('close', code => {
      tunnel.process = null;
      if (tunnel.manualDisconnect) return;

      if (tunnel.status === TunnelStatus.AUTH_REQUIRED) return; // Wait for user action

      const delay = RECONNECT_DELAYS[Math.min(tunnel.retryCount, RECONNECT_DELAYS.length - 1)];
      tunnel.retryCount++;

      console.log(`[TunnelManager] ${hostAlias} disconnected (code=${code}), retry in ${delay}ms`);
      if (stderrBuf.trim()) {
        // Print last 10 lines of SSH stderr to help diagnose
        const lines = stderrBuf.trim().split('\n');
        const tail = lines.slice(-10).join('\n');
        console.log(`[TunnelManager] SSH stderr (last 10 lines):\n${tail}`);
      }

      this._setStatus(hostAlias, TunnelStatus.CONNECTING,
        `Reconnecting in ${Math.round(delay / 1000)}s...`);

      tunnel.retryTimer = setTimeout(() => this._doConnect(hostAlias), delay);
    });

    proc.on('error', err => {
      console.error(`[TunnelManager] SSH error for ${hostAlias}:`, err.message);
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
