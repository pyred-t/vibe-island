/**
 * Hook Installer for Claude Island Windows
 * Installs Python hook scripts into Claude Code's settings.json
 * Supports both Windows native and WSL paths.
 *
 * Now works per-machine using machines[].claudePaths
 */
const fs = require('fs');
const path = require('path');
const configStore = require('./config-store');

const HOOK_SCRIPT_NAME = 'claude-island-state.py';

class HookInstaller {
  constructor() {
    this._hookScriptSource = path.join(__dirname, '..', 'hooks', HOOK_SCRIPT_NAME);
  }

  /**
   * Install hooks for all paths in the local machine
   */
  installAll() {
    const local = configStore.getLocalMachine();
    if (!local) return [];
    return this.installForMachine(local);
  }

  /**
   * Install hooks for all claude paths in a machine object
   * Only works for local/WSL paths (not SSH — that's handled by TunnelManager)
   */
  installForMachine(machine) {
    const results = [];
    for (const claudePath of machine.claudePaths) {
      try {
        const result = this.install(claudePath);
        results.push({ path: claudePath, ...result });
      } catch (err) {
        results.push({ path: claudePath, success: false, error: err.message });
      }
    }
    return results;
  }

  /**
   * Install hooks for a specific Claude Code configuration path (Windows/WSL)
   */
  install(claudeConfigPath) {
    if (!fs.existsSync(claudeConfigPath)) {
      return { success: false, error: `Path does not exist: ${claudeConfigPath}` };
    }

    // 1. Copy hook script to <claudeConfigPath>/hooks/
    const hooksDir = path.join(claudeConfigPath, 'hooks');
    if (!fs.existsSync(hooksDir)) {
      fs.mkdirSync(hooksDir, { recursive: true });
    }

    const destScript = path.join(hooksDir, HOOK_SCRIPT_NAME);
    try {
      fs.copyFileSync(this._hookScriptSource, destScript);
    } catch (err) {
      return { success: false, error: `Failed to copy hook script: ${err.message}` };
    }

    // 2. Update settings.json with hook configuration
    const settingsPath = path.join(claudeConfigPath, 'settings.json');
    let settings = {};
    try {
      if (fs.existsSync(settingsPath)) {
        settings = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
      }
    } catch (err) {
      console.warn(`Failed to parse existing settings.json: ${err.message}`);
    }

    const port = configStore.get('port') || 51515;
    const isWSL = this._isWSLPath(claudeConfigPath);

    let commandPath;
    if (isWSL) {
      const wslScriptPath = this._windowsToWSLPath(destScript);
      commandPath = `python3 ${wslScriptPath} --port ${port}`;
    } else {
      commandPath = `python "${destScript}" --port ${port}`;
    }

    const hookConfig = this._buildHookConfig(commandPath);

    if (!settings.hooks) settings.hooks = {};
    settings.hooks = this._stripManagedHooks(settings.hooks);

    for (const config of hookConfig) {
      const event = config.event;
      if (!settings.hooks[event]) settings.hooks[event] = [];
      settings.hooks[event].push(...config.config);
    }

    try {
      fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
    } catch (err) {
      return { success: false, error: `Failed to write settings.json: ${err.message}` };
    }

    // Track installation
    const installed = configStore.get('hooksInstalled') || {};
    installed[claudeConfigPath] = { installedAt: new Date().toISOString(), command: commandPath };
    configStore.set('hooksInstalled', installed);

    return { success: true, command: commandPath };
  }

  /**
   * Uninstall hooks from a specific path
   */
  uninstall(claudeConfigPath) {
    const destScript = path.join(claudeConfigPath, 'hooks', HOOK_SCRIPT_NAME);
    try {
      if (fs.existsSync(destScript)) fs.unlinkSync(destScript);
    } catch { /* ignore */ }

    const settingsPath = path.join(claudeConfigPath, 'settings.json');
    try {
      if (fs.existsSync(settingsPath)) {
        const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
        if (settings.hooks) {
          settings.hooks = this._stripManagedHooks(settings.hooks);
          for (const key of Object.keys(settings.hooks)) {
            if (Array.isArray(settings.hooks[key]) && settings.hooks[key].length === 0) {
              delete settings.hooks[key];
            }
          }
          if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
          fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
        }
      }
    } catch { /* ignore */ }

    const installed = configStore.get('hooksInstalled') || {};
    delete installed[claudeConfigPath];
    configStore.set('hooksInstalled', installed);
  }

  /**
   * Check if hooks are installed for a given path
   */
  isInstalled(claudeConfigPath) {
    const settingsPath = path.join(claudeConfigPath, 'settings.json');
    try {
      if (!fs.existsSync(settingsPath)) return false;
      const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
      if (!settings.hooks) return false;
      const requiredEvents = ['PreToolUse', 'PermissionRequest', 'Stop', 'SessionStart', 'SessionEnd'];
      return requiredEvents.every(event => {
        const entries = settings.hooks[event];
        if (!Array.isArray(entries)) return false;
        return entries.some(entry => {
          const hooks = entry.hooks || [entry];
          return hooks.some(h => this._isManagedCommand(h.command || ''));
        });
      });
    } catch {
      return false;
    }
  }

  /**
   * Get hook status for all paths in a machine
   */
  getMachineHookStatus(machine) {
    return machine.claudePaths.map(p => ({
      path: p,
      exists: (() => { try { return fs.existsSync(p); } catch { return false; } })(),
      installed: (() => { try { return this.isInstalled(p); } catch { return false; } })(),
    }));
  }

  // ─── Private helpers ──────────────────────────────────────────

  _buildHookConfig(commandPath) {
    const hookEntry = [{ type: 'command', command: commandPath }];
    const hookEntryWithTimeout = [{ type: 'command', command: commandPath, timeout: 86400 }];
    const withMatcher = [{ matcher: '*', hooks: hookEntry }];
    const withMatcherAndTimeout = [{ matcher: '*', hooks: hookEntryWithTimeout }];
    const withoutMatcher = [{ hooks: hookEntry }];
    const preCompactConfig = [
      { matcher: 'auto', hooks: hookEntry },
      { matcher: 'manual', hooks: hookEntry },
    ];

    return [
      { event: 'UserPromptSubmit', config: withoutMatcher },
      { event: 'PreToolUse', config: withMatcherAndTimeout },
      { event: 'PostToolUse', config: withMatcher },
      { event: 'PermissionRequest', config: withMatcherAndTimeout },
      { event: 'Notification', config: withMatcher },
      { event: 'Stop', config: withoutMatcher },
      { event: 'SubagentStop', config: withoutMatcher },
      { event: 'SessionStart', config: withoutMatcher },
      { event: 'SessionEnd', config: withoutMatcher },
      { event: 'PreCompact', config: preCompactConfig },
    ];
  }

  _stripManagedHooks(hooks) {
    const cleaned = {};
    for (const [event, entries] of Object.entries(hooks)) {
      if (!Array.isArray(entries)) { cleaned[event] = entries; continue; }
      const filteredEntries = entries.filter(entry => {
        const entryHooks = entry.hooks || [entry];
        if (!Array.isArray(entryHooks)) return true;
        const remaining = entryHooks.filter(h => !this._isManagedCommand(h.command || ''));
        if (remaining.length === 0) return false;
        if (entry.hooks) entry.hooks = remaining;
        return true;
      });
      if (filteredEntries.length > 0) cleaned[event] = filteredEntries;
    }
    return cleaned;
  }

  _isManagedCommand(command) {
    return command.includes(HOOK_SCRIPT_NAME) || command.includes('claude-island');
  }

  _isWSLPath(p) {
    const n = p.replace(/\\/g, '/').toLowerCase();
    return n.startsWith('//wsl$') || n.startsWith('//wsl.localhost');
  }

  _windowsToWSLPath(windowsPath) {
    const normalized = windowsPath.replace(/\\/g, '/');
    const match = normalized.match(/^\/(\/)(wsl\$|wsl\.localhost)\/[^/]+(\/.*)/i);
    if (match) return match[3];
    return windowsPath;
  }
}

module.exports = new HookInstaller();
