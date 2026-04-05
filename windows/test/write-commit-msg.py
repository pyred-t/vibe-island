import pathlib

msg = """feat(windows/remote): add SSH remote host support via reverse port tunnel

- New SSHConfigReader: auto-detects VSCode custom SSH config or system
  ~/.ssh/config, parses Host entries, watches for live changes
- New TunnelManager: manages independent ssh -N -R reverse port forward
  per remote host using system OpenSSH binary (no ssh2 lib dependency)
  - Installs/syncs hook script on connect via heredoc over SSH
  - Detects auth failures from stderr, emits authRequired for UI guidance
  - Auto-reconnects with exponential backoff (5s->10s->20s->40s->60s)
  - Syncs hook script on every reconnect to keep remote up-to-date
- New RemoteHostStore: persists managed hosts in ConfigStore, restores
  autoConnect hosts on app startup
- Hook script: adds hostname and is_remote fields to all events
- Session store: store and update hostname/isRemote per session
- Main process: wires TunnelManager events, adds IPC for remote hosts
- Preload: exposes getSshHosts, connectRemote, disconnectRemote, retry,
  onRemoteStatusChanged, onRemoteAuthRequired, onSshHostsChanged
- Settings UI: Remote Hosts panel shows SSH config hosts with live
  connect/disconnect status and one-click tunnel management
- Session cards: remote sessions show globe icon + hostname badge
- Auth Required dialog: guides user to run ssh-add with copy + Retry

Tests written and verified:
- test-ssh-config.js: config path detection, host parsing (4 hosts found)
- test-tunnel-manager.js: init, SSH binary availability check
- test-remote-store.js: addHost, autoConnect filter, markConnected, remove
- test-remote-event.js: hostname/is_remote correctly propagated end-to-end
- send-test-event.js all: full session lifecycle incl. permission approve
"""

pathlib.Path(r"C:/Users/pangy/AppData/Local/Temp/cm.txt").write_text(msg, encoding="utf-8")
print("Written.")
