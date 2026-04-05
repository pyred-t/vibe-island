/**
 * SSH Config Reader
 * Reads SSH host list from:
 *   1. VSCode's custom SSH config file (if configured)
 *   2. System default ~/.ssh/config
 *
 * Also watches for file changes so the UI updates live.
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { EventEmitter } = require('events');

class SSHConfigReader extends EventEmitter {
  constructor() {
    super();
    this._hosts = [];
    this._watcher = null;
    this._configPath = null;
  }

  /**
   * Get path to VSCode's SSH config (or system default or user-configured)
   * Priority: user config (configStore.sshConfigPath) > VSCode setting > ~/.ssh/config
   */
  _resolveConfigPath() {
    // 1. User-explicitly configured path (highest priority)
    try {
      const configStore = require('./config-store');
      const custom = configStore.get('sshConfigPath');
      if (custom && require('fs').existsSync(custom)) {
        return custom;
      }
    } catch { /* configStore not ready yet */ }

    // 2. VSCode's custom SSH config file setting
    try {
      const vscodeSettingsPath = path.join(
        process.env.APPDATA || os.homedir(),
        'Code', 'User', 'settings.json'
      );
      if (fs.existsSync(vscodeSettingsPath)) {
        const raw = fs.readFileSync(vscodeSettingsPath, 'utf8');
        const stripped = raw.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
        const settings = JSON.parse(stripped);
        const customPath = settings['remote.SSH.configFile'];
        if (customPath && fs.existsSync(customPath)) {
          return customPath;
        }
      }
    } catch { /* VSCode not installed or settings unreadable */ }

    // 3. Default: ~/.ssh/config
    return path.join(os.homedir(), '.ssh', 'config');
  }

  /**
   * Parse SSH config file into a list of host entries
   */
  _parseConfig(content) {
    const hosts = [];
    let current = null;

    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;

      const match = trimmed.match(/^(\S+)\s+(.*)$/);
      if (!match) continue;

      const [, key, value] = match;
      const keyLower = key.toLowerCase();

      if (keyLower === 'host') {
        // Start of a new Host block
        // Skip wildcard-only entries
        const aliases = value.trim().split(/\s+/);
        for (const alias of aliases) {
          if (alias && !alias.includes('*') && !alias.includes('?')) {
            current = { alias, hostname: alias, user: os.userInfo().username, port: 22 };
            hosts.push(current);
          }
        }
      } else if (current) {
        if (keyLower === 'hostname') current.hostname = value.trim();
        else if (keyLower === 'user') current.user = value.trim();
        else if (keyLower === 'port') current.port = parseInt(value.trim()) || 22;
        else if (keyLower === 'identityfile') current.identityFile = value.trim();
        else if (keyLower === 'proxyjump') current.proxyJump = value.trim();
      }
    }

    return hosts;
  }

  /**
   * Load (or reload) the SSH config
   */
  load() {
    this._configPath = this._resolveConfigPath();

    if (!fs.existsSync(this._configPath)) {
      this._hosts = [];
      return [];
    }

    try {
      const content = fs.readFileSync(this._configPath, 'utf8');
      this._hosts = this._parseConfig(content);
      return this._hosts;
    } catch (e) {
      console.warn('[SSHConfigReader] Failed to read config:', e.message);
      this._hosts = [];
      return [];
    }
  }

  /**
   * Start watching the config file for changes
   */
  watch() {
    this._configPath = this._resolveConfigPath();
    this.load();

    if (this._watcher) this._watcher.close();

    if (fs.existsSync(this._configPath)) {
      this._watcher = fs.watch(this._configPath, () => {
        // Debounce
        clearTimeout(this._reloadTimer);
        this._reloadTimer = setTimeout(() => {
          this.load();
          this.emit('changed', this._hosts);
        }, 300);
      });
    }
  }

  /**
   * Stop watching
   */
  unwatch() {
    if (this._watcher) {
      this._watcher.close();
      this._watcher = null;
    }
  }

  /**
   * Get the list of SSH hosts
   */
  getHosts() {
    return this._hosts;
  }

  /**
   * Get the current config file path being used
   */
  getConfigPath() {
    return this._configPath || this._resolveConfigPath();
  }
}

module.exports = new SSHConfigReader();
