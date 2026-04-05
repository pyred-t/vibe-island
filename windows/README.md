# Claude Island for Windows

A Windows system tray application that monitors **Claude Code CLI** sessions in real time — showing session status, tool activity, and permission approval dialogs right from your taskbar notification area.

Inspired by the macOS [Vibe Island](https://github.com/anthropics/vibe-island) Dynamic Island experience.

## Features

- 🖥️ **System Tray** — Always-present icon with live status color (gray / purple / amber)
- 📋 **Popup Panel** — Click tray icon to see all active Claude Code sessions with state and tool info
- 🔐 **Permission Approvals** — Allow / Always Allow / Deny tool calls without switching terminal
- 🔔 **Windows Notifications** — Toast alerts when sessions need attention
- 🐧 **WSL Support** — Works with Claude Code running inside WSL (WSL2 localhost forwarding)
- 📁 **Configurable Paths** — Add any `.claude` directory, including WSL paths like `\\wsl$\Ubuntu\home\user\.claude`
- ⚙️ **Auto Hook Install** — Automatically installs Python hook scripts into Claude Code's `settings.json`

## Requirements

| Requirement | Version |
|-------------|---------|
| Windows     | 10 / 11 |
| Node.js     | 18+     |
| Python      | 3.8+    |
| Claude Code | Any     |

## Quick Start

```bat
cd windows
npm install
start.bat
```

On first launch the app will:
1. Start a TCP hook server on port `51515`
2. Auto-detect Claude Code paths (Windows + WSL)
3. Install hook scripts into all detected `~/.claude/` directories
4. Show a tray icon — click it to open the panel

## How It Works

```
Claude Code CLI  ──►  Hook Script (Python)  ──►  TCP 127.0.0.1:51515  ──►  Claude Island App
  (Win or WSL)         ~/.claude/hooks/             (background server)       Tray + Popup Panel
```

### Hook Script

The hook script `hooks/claude-island-state.py` is installed to `~/.claude/hooks/` and called by Claude Code for every event (session start/end, tool use, permission requests, etc.). It communicates back to the app via TCP instead of a Unix socket, making it compatible with both Windows native and WSL environments.

**WSL note:** WSL2 automatically mirrors `localhost` to the Windows host, so Claude Code running in WSL connects to the Windows app transparently via `127.0.0.1:51515`.

## Configuration

Click the **⚙️** gear icon in the panel to open Settings:

| Setting | Description |
|---------|-------------|
| **Claude Code Paths** | Directories where Claude Code stores its config. Add WSL paths here. |
| **TCP Port** | Port for hook communication (default: `51515`) |
| **Notifications** | Enable/disable Windows toast notifications |

### Adding a WSL Path

1. Open Settings → click **Add Path**
2. Browse to `\\wsl$\<DistroName>\home\<username>\.claude`
3. Click **Install / Reinstall Hooks**

The app converts the path to a WSL-internal path when writing the hook command, so Claude Code inside WSL sees the script at `/home/<username>/.claude/hooks/claude-island-state.py`.

## Launching

The app must be started via `start.bat` (not `npm start`) because the `ELECTRON_RUN_AS_NODE` environment variable — set by some tools — breaks Electron API loading.

```bat
windows\start.bat
```

## Development & Testing

```bat
# Start the app
start.bat

# Simulate a full session lifecycle (in another terminal)
node test/send-test-event.js all

# Test a specific event type
node test/send-test-event.js permission   # waits for your Approve/Deny click
node test/send-test-event.js processing
node test/send-test-event.js waiting

# Test Windows encoding handling (Chinese paths, non-ASCII content)
python test/test-encoding.py
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Tray icon doesn't appear | Use `start.bat`, not `npm start`. Make sure `ELECTRON_RUN_AS_NODE` is not set. |
| Sessions don't show up | Open Settings → Hooks → click **Install / Reinstall Hooks** |
| Wrong status on Windows | Already fixed: the hook script now forces UTF-8 stdin/stdout to handle Chinese paths and non-ASCII tool output |
| WSL sessions not connecting | Confirm you're on WSL2 (not WSL1). WSL1 doesn't forward localhost. |
| Port conflict | Change the port in Settings; it updates `settings.json` on next hook install |

## File Structure

```
windows/
├── main.js              # Electron main process
├── preload.js           # Secure IPC bridge (contextBridge)
├── start.bat            # Launch script (clears ELECTRON_RUN_AS_NODE)
├── src/
│   ├── config-store.js  # Settings persistence (~AppData/Roaming/ClaudeIsland/)
│   ├── hook-server.js   # TCP server — receives hook events, holds permission sockets
│   ├── session-store.js # Session state machine
│   ├── hook-installer.js # Installs hook scripts into Claude Code settings.json
│   ├── tray-manager.js  # System tray icon with programmatic status indicator
│   └── notification.js  # Windows toast notifications
├── renderer/
│   ├── index.html       # Popup panel HTML
│   ├── styles.css       # Dark theme with glassmorphism & animations
│   └── app.js           # Frontend: session list, permissions, settings UI
├── hooks/
│   └── claude-island-state.py  # TCP hook script (Windows + WSL compatible)
└── test/
    ├── send-test-event.js  # Simulate hook events via TCP
    ├── diag-connection.py  # Connectivity diagnostic
    └── test-encoding.py    # Verify Windows GBK→UTF-8 encoding fix
```

## Known Limitations

- Permission approval UI auto-shows the window, but if you miss it, the hook times out after 5 minutes and lets the tool proceed without approval
- The app must be running before Claude Code starts a session for hooks to connect
- Auto-start with Windows is not yet implemented (planned)
