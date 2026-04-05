/**
 * Configuration store for Claude Island Windows
 * Persists settings to a JSON file in the user's app data directory
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { EventEmitter } = require('events');

const APP_NAME = 'ClaudeIsland';
const CONFIG_DIR = path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), APP_NAME);
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');

const DEFAULT_CONFIG = {
  // TCP server port for hook communication
  port: 51515,

  // Claude Code configuration directory paths
  // Supports multiple paths for different environments
  claudeConfigPaths: [
    // Windows native default
    path.join(os.homedir(), '.claude'),
  ],

  // Notification settings
  enableNotifications: true,
  notificationSound: true,

  // Auto-start with Windows
  autoStart: false,

  // UI preferences
  theme: 'dark',

  // Hook installation status
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
        this._config = { ...DEFAULT_CONFIG, ...JSON.parse(data) };
      } else {
        this._config = { ...DEFAULT_CONFIG };
        this._detectWSLPaths();
        this.save();
      }
    } catch (err) {
      console.error('Failed to load config:', err);
      this._config = { ...DEFAULT_CONFIG };
    }
    return this._config;
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

  /**
   * Auto-detect WSL distributions and add their .claude paths
   */
  _detectWSLPaths() {
    try {
      const wslBasePath = '\\\\wsl$';
      // Also try \\wsl.localhost which is used in newer Windows versions
      const wslLocalhostPath = '\\\\wsl.localhost';

      const tryPaths = [wslBasePath, wslLocalhostPath];

      for (const basePath of tryPaths) {
        try {
          if (!fs.existsSync(basePath)) continue;
          const distros = fs.readdirSync(basePath);
          for (const distro of distros) {
            // Try common home directories
            const homeDir = path.join(basePath, distro, 'home');
            if (fs.existsSync(homeDir)) {
              const users = fs.readdirSync(homeDir);
              for (const user of users) {
                const claudePath = path.join(homeDir, user, '.claude');
                if (fs.existsSync(claudePath)) {
                  if (!this._config.claudeConfigPaths.includes(claudePath)) {
                    this._config.claudeConfigPaths.push(claudePath);
                    console.log(`Detected WSL Claude path: ${claudePath}`);
                  }
                }
              }
            }
          }
        } catch (e) {
          // Skip inaccessible paths
        }
      }
    } catch (err) {
      // WSL not available, that's fine
    }
  }

  /**
   * Get all valid Claude config directories (that actually exist)
   */
  getValidClaudePaths() {
    if (!this._config) this.load();
    return this._config.claudeConfigPaths.filter(p => {
      try { return fs.existsSync(p); } catch { return false; }
    });
  }

  /**
   * Add a new Claude config path
   */
  addClaudePath(newPath) {
    if (!this._config) this.load();
    const normalized = path.resolve(newPath);
    if (!this._config.claudeConfigPaths.includes(normalized)) {
      this._config.claudeConfigPaths.push(normalized);
      this.save();
      this.emit('changed', 'claudeConfigPaths', this._config.claudeConfigPaths);
    }
  }

  /**
   * Remove a Claude config path
   */
  removeClaudePath(pathToRemove) {
    if (!this._config) this.load();
    this._config.claudeConfigPaths = this._config.claudeConfigPaths.filter(p => p !== pathToRemove);
    this.save();
    this.emit('changed', 'claudeConfigPaths', this._config.claudeConfigPaths);
  }
}

module.exports = new ConfigStore();
