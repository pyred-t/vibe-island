/**
 * Hook Installer for Claude Island Windows
 * Installs Python hook scripts into Claude Code's settings.json
 * Supports both Windows native and WSL paths.
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
   * Install hooks for all configured Claude Code paths
   */
  installAll() {
    const results = [];
    const paths = configStore.get('claudeConfigPaths') || [];

    for (const claudePath of paths) {
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
   * Install hooks for a specific Claude Code configuration path
   */
  install(claudeConfigPath) {
    // Ensure the path exists
    if (!fs.existsSync(claudeConfigPath)) {
      return { success: false, error: `Path does not exist: ${claudeConfigPath}` };
    }

    // 1. Copy hook script to ~/.claude/hooks/
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

    // Build the hook command
    // Determine appropriate Python command and script path
    const port = configStore.get('port') || 51515;
    const isWSL = this._isWSLPath(claudeConfigPath);

    let commandPath;
    if (isWSL) {
      // For WSL, the script is accessed from WSL filesystem
      // Convert Windows UNC path to WSL path
      const wslScriptPath = this._windowsToWSLPath(destScript, claudeConfigPath);
      commandPath = `python3 ${wslScriptPath} --port ${port}`;
    } else {
      commandPath = `python "${destScript}" --port ${port}`;
    }

    // Build hook config entries
    const hookConfig = this._buildHookConfig(commandPath);

    // Merge hooks into settings
    if (!settings.hooks) settings.hooks = {};

    // Remove any existing Claude Island hooks first
    settings.hooks = this._stripManagedHooks(settings.hooks);

    // Add our hooks
    for (const config of hookConfig) {
      const event = config.event;
      if (!settings.hooks[event]) settings.hooks[event] = [];
      settings.hooks[event].push(...config.config);
    }

    // Write settings back
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
   * Uninstall hooks from a specific Claude Code config path
   */
  uninstall(claudeConfigPath) {
    // Remove the hook script
    const destScript = path.join(claudeConfigPath, 'hooks', HOOK_SCRIPT_NAME);
    try {
      if (fs.existsSync(destScript)) fs.unlinkSync(destScript);
    } catch (err) { /* ignore */ }

    // Clean settings.json
    const settingsPath = path.join(claudeConfigPath, 'settings.json');
    try {
      if (fs.existsSync(settingsPath)) {
        const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
        if (settings.hooks) {
          settings.hooks = this._stripManagedHooks(settings.hooks);

          // Remove empty hook arrays
          for (const key of Object.keys(settings.hooks)) {
            if (Array.isArray(settings.hooks[key]) && settings.hooks[key].length === 0) {
              delete settings.hooks[key];
            }
          }
          if (Object.keys(settings.hooks).length === 0) {
            delete settings.hooks;
          }

          fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf-8');
        }
      }
    } catch (err) { /* ignore */ }

    // Update tracking
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

      // Check if at least the main events have our hooks
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
   * Check if all configured paths have hooks installed
   */
  areAllInstalled() {
    const paths = configStore.getValidClaudePaths();
    if (paths.length === 0) return false;
    return paths.every(p => this.isInstalled(p));
  }

  /**
   * Build hook configuration matching Claude Code's format
   */
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

  /**
   * Strip any Claude Island managed hooks from a hooks config
   */
  _stripManagedHooks(hooks) {
    const cleaned = {};

    for (const [event, entries] of Object.entries(hooks)) {
      if (!Array.isArray(entries)) {
        cleaned[event] = entries;
        continue;
      }

      const filteredEntries = entries.filter(entry => {
        const entryHooks = entry.hooks || [entry];
        if (!Array.isArray(entryHooks)) return true;

        const remaining = entryHooks.filter(h => !this._isManagedCommand(h.command || ''));
        if (remaining.length === 0) return false;

        if (entry.hooks) {
          entry.hooks = remaining;
        }
        return true;
      });

      if (filteredEntries.length > 0) {
        cleaned[event] = filteredEntries;
      }
    }

    return cleaned;
  }

  /**
   * Check if a command string is managed by Claude Island
   */
  _isManagedCommand(command) {
    return command.includes(HOOK_SCRIPT_NAME) || command.includes('claude-island');
  }

  /**
   * Check if a path is a WSL network path
   */
  _isWSLPath(p) {
    const normalized = p.replace(/\\/g, '/').toLowerCase();
    return normalized.startsWith('//wsl$') || normalized.startsWith('//wsl.localhost');
  }

  /**
   * Convert a Windows UNC WSL path to a WSL-internal path
   * \\wsl$\Ubuntu\home\user\.claude → /home/user/.claude
   * \\wsl.localhost\Ubuntu\home\user\.claude → /home/user/.claude
   */
  _windowsToWSLPath(windowsPath, contextPath) {
    const normalized = windowsPath.replace(/\\/g, '/');
    // Match \\wsl$\<distro>\... or \\wsl.localhost\<distro>\...
    const match = normalized.match(/^\/\/(wsl\$|wsl\.localhost)\/[^/]+(\/.*)$/i);
    if (match) {
      return match[2]; // Return the path after the distro name
    }
    // Fallback: just use the path as-is
    return windowsPath;
  }
}

module.exports = new HookInstaller();
