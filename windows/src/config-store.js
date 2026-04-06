/**
 * Configuration store for Claude Island Windows
 * Persists settings to a JSON file in the user's app data directory
 *
 * Config schema:
 * {
 *   port: number,
 *   sshConfigPath: string | null,   // null = auto-detect
 *   enableNotifications: boolean,
 *   machines: [
 *     {
 *       id: string,              // 'local' or UUID
 *       type: 'local' | 'ssh',
 *       label: string,           // display name
 *       claudePaths: string[],   // local Windows/WSL paths or remote Linux paths
 *       // SSH-only:
 *       sshAlias: string,
 *       port: number,            // reverse-tunnel port (default 51515)
 *       autoConnect: boolean,
 *       lastConnected: string | null,
 *     }
 *   ],
 *   hooksInstalled: {},          // { path: { installedAt, command } }
 * }
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { EventEmitter } = require('events');

const APP_NAME = 'ClaudeIsland';
const CONFIG_DIR = path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), APP_NAME);
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');

// Default local machine entry
const defaultLocalMachine = () => ({
  id: 'local',
  type: 'local',
  label: 'This PC',
  claudePaths: [path.join(os.homedir(), '.claude')],
});

const DEFAULT_CONFIG = {
  port: 51515,
  listenHost: '127.0.0.1',      // bind address; set to 0.0.0.0 for WSL2 non-mirror mode
  sshConfigPath: null,          // null = auto-detect from VSCode or ~/.ssh/config
  enableNotifications: true,
  notificationSound: true,
  autoStart: false,
  theme: 'dark',
  machines: [defaultLocalMachine()],
  hooksInstalled: {},
};

class ConfigStore extends EventEmitter {
  constructor() {
    super();
    this._config = null;
  }

  _ensureDir() {
    if (!fs.existsSync(CONFIG_DIR)) {
      fs.mkdirSync(CONFIG_DIR, { recursive: true });
    }
  }

  load() {
    this._ensureDir();
    try {
      if (fs.existsSync(CONFIG_FILE)) {
        const data = fs.readFileSync(CONFIG_FILE, 'utf-8');
        const saved = JSON.parse(data);
        // Merge with defaults (shallow for top-level keys)
        this._config = { ...DEFAULT_CONFIG, ...saved };
        // Migrate old claudeConfigPaths → machines local entry
        if (saved.claudeConfigPaths && !saved.machines) {
          this._migrateFromLegacy(saved.claudeConfigPaths);
        }
        // Migrate old remoteHosts → machines ssh entries
        if (saved.remoteHosts && typeof saved.remoteHosts === 'object') {
          this._migrateRemoteHosts(saved.remoteHosts);
        }
      } else {
        this._config = { ...DEFAULT_CONFIG, machines: [defaultLocalMachine()] };
        this._detectWSLPaths();
        this.save();
      }
    } catch (err) {
      console.error('Failed to load config:', err);
      this._config = { ...DEFAULT_CONFIG, machines: [defaultLocalMachine()] };
    }
    return this._config;
  }

  /**
   * Migrate old claudeConfigPaths array → local machine's claudePaths
   */
  _migrateFromLegacy(claudeConfigPaths) {
    console.log('[Config] Migrating legacy claudeConfigPaths →machines');
    const local = this._config.machines.find(m => m.id === 'local');
    if (local) {
      // Merge without duplicates
      const merged = Array.from(new Set([...local.claudePaths, ...claudeConfigPaths]));
      local.claudePaths = merged;
    } else {
      this._config.machines.unshift({
        ...defaultLocalMachine(),
        claudePaths: claudeConfigPaths,
      });
    }
    // Remove legacy key
    delete this._config.claudeConfigPaths;
    this.save();
  }

  /**
   * Migrate old remoteHosts object → SSH machine entries
   */
  _migrateRemoteHosts(remoteHosts) {
    console.log('[Config] Migrating legacy remoteHosts → machines');
    for (const [alias, host] of Object.entries(remoteHosts)) {
      if (!this._config.machines.find(m => m.sshAlias === alias)) {
        this._config.machines.push({
          id: alias,
          type: 'ssh',
          label: alias,
          sshAlias: alias,
          claudePaths: ['~/.claude'],
          port: host.port || 51515,
          autoConnect: host.autoConnect || false,
          lastConnected: host.lastConnected || null,
        });
      }
    }
    delete this._config.remoteHosts;
    this.save();
  }

  save() {
    this._ensureDir();
    try {
      fs.writeFileSync(CONFIG_FILE, JSON.stringify(this._config, null, 2), 'utf-8');
    } catch (err) {
      console.error('Failed to save config:', err);
    }
  }

  get(key) {
    if (!this._config) this.load();
    return this._config[key];
  }

  set(key, value) {
    if (!this._config) this.load();
    this._config[key] = value;
    this.save();
    this.emit('changed', key, value);
  }

  getAll() {
    if (!this._config) this.load();
    return { ...this._config };
  }

  // ─── Machine Management ───────────────────────────────────────

  getMachines() {
    if (!this._config) this.load();
    return this._config.machines || [];
  }

  getLocalMachine() {
    return this.getMachines().find(m => m.type === 'local');
  }

  getSSHMachines() {
    return this.getMachines().filter(m => m.type === 'ssh');
  }

  getMachine(id) {
    return this.getMachines().find(m => m.id === id);
  }

  getMachineBySSHAlias(alias) {
    return this.getMachines().find(m => m.sshAlias === alias);
  }

  /**
   * Add a new SSH machine (from SSH config import or manual)
   * Won't add if alias already exists.
   */
  addSSHMachine(alias, { claudePaths = ['~/.claude'], port = 51515, autoConnect = false, label = null } = {}) {
    if (!this._config) this.load();
    if (this._config.machines.find(m => m.sshAlias === alias)) {
      return false; // already exists
    }
    this._config.machines.push({
      id: alias,
      type: 'ssh',
      label: label || alias,
      sshAlias: alias,
      claudePaths,
      port,
      autoConnect,
      lastConnected: null,
    });
    this.save();
    this.emit('changed', 'machines', this._config.machines);
    return true;
  }

  /**
   * Update a machine's properties
   */
  updateMachine(id, updates) {
    if (!this._config) this.load();
    const idx = this._config.machines.findIndex(m => m.id === id);
    if (idx < 0) return false;
    this._config.machines[idx] = { ...this._config.machines[idx], ...updates };
    this.save();
    this.emit('changed', 'machines', this._config.machines);
    return true;
  }

  /**
   * Remove a machine (cannot remove local)
   */
  removeMachine(id) {
    if (id === 'local') return false;
    if (!this._config) this.load();
    this._config.machines = this._config.machines.filter(m => m.id !== id);
    this.save();
    this.emit('changed', 'machines', this._config.machines);
    return true;
  }

  /**
   * Add a claude path to a machine
   */
  addClaudePathToMachine(machineId, newPath) {
    if (!this._config) this.load();
    const machine = this.getMachine(machineId);
    if (!machine) return false;
    if (!machine.claudePaths.includes(newPath)) {
      machine.claudePaths.push(newPath);
      this.save();
      this.emit('changed', 'machines', this._config.machines);
    }
    return true;
  }

  /**
   * Remove a claude path from a machine
   */
  removeClaudePathFromMachine(machineId, pathToRemove) {
    if (!this._config) this.load();
    const machine = this.getMachine(machineId);
    if (!machine) return false;
    machine.claudePaths = machine.claudePaths.filter(p => p !== pathToRemove);
    this.save();
    this.emit('changed', 'machines', this._config.machines);
    return true;
  }

  // ─── Legacy helpers (used by hook-installer) ─────────────────

  /**
   * Get all Windows/WSL claude paths from the local machine
   */
  getValidClaudePaths() {
    const local = this.getLocalMachine();
    if (!local) return [];
    return local.claudePaths.filter(p => {
      try { return require('fs').existsSync(p); } catch { return false; }
    });
  }

  // ─── WSL Auto-detection ──────────────────────────────────────

  _detectWSLPaths() {
    try {
      const local = this._config.machines.find(m => m.id === 'local');
      if (!local) return;

      const tryBases = ['\\\\wsl$', '\\\\wsl.localhost'];
      for (const base of tryBases) {
        try {
          if (!fs.existsSync(base)) continue;
          for (const distro of fs.readdirSync(base)) {
            const homeDir = path.join(base, distro, 'home');
            if (!fs.existsSync(homeDir)) continue;
            for (const user of fs.readdirSync(homeDir)) {
              const p = path.join(homeDir, user, '.claude');
              if (fs.existsSync(p) && !local.claudePaths.includes(p)) {
                local.claudePaths.push(p);
                console.log(`[Config] Detected WSL Claude path: ${p}`);
              }
            }
          }
        } catch { /* skip */ }
      }
    } catch { /* WSL not available */ }
  }
}

module.exports = new ConfigStore();
