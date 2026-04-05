/**
 * Remote Host Store
 * Persists which remote SSH hosts the user has configured/connected,
 * and restores connections on app startup.
 */
const { EventEmitter } = require('events');

class RemoteHostStore extends EventEmitter {
  constructor() {
    super();
    this._configStore = null; // injected after init
    this._hosts = {};         // { alias: { alias, port, autoConnect, lastConnected } }
  }

  /**
   * Inject config store dependency (call after configStore.load())
   */
  init(configStore) {
    this._configStore = configStore;
    const saved = configStore.get('remoteHosts') || {};
    this._hosts = saved;
  }

  /**
   * Add a remote host to the managed list
   */
  addHost(alias, { port = 51515, autoConnect = true } = {}) {
    this._hosts[alias] = {
      alias,
      port,
      autoConnect,
      lastConnected: null,
    };
    this._save();
    this.emit('changed', this.getAll());
  }

  /**
   * Remove a remote host
   */
  removeHost(alias) {
    delete this._hosts[alias];
    this._save();
    this.emit('changed', this.getAll());
  }

  /**
   * Mark a host as connected (update timestamp)
   */
  markConnected(alias) {
    if (this._hosts[alias]) {
      this._hosts[alias].lastConnected = new Date().toISOString();
      this._save();
    }
  }

  /**
   * Set autoConnect flag
   */
  setAutoConnect(alias, value) {
    if (this._hosts[alias]) {
      this._hosts[alias].autoConnect = value;
      this._save();
    }
  }

  /**
   * Get all managed hosts
   */
  getAll() {
    return Object.values(this._hosts);
  }

  /**
   * Get hosts to auto-connect on startup
   */
  getAutoConnect() {
    return this.getAll().filter(h => h.autoConnect);
  }

  /**
   * Check if alias is managed
   */
  has(alias) {
    return !!this._hosts[alias];
  }

  _save() {
    if (this._configStore) {
      this._configStore.set('remoteHosts', this._hosts);
    }
  }
}

module.exports = new RemoteHostStore();
