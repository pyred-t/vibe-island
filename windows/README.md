# Claude Island for Windows

A Windows system tray application that monitors **Claude Code CLI** sessions in real time — showing session status, tool activity, and permission approval dialogs right from your taskbar notification area.

Inspired by the macOS [Vibe Island](https://github.com/anthropics/vibe-island) Dynamic Island experience.

## Features

- 🖥️ **System Tray** — Always-present icon with live status color (gray / purple / amber)
- 📋 **Popup Panel** — Click tray icon to see all active Claude Code sessions with state and tool info
- 🔐 **Permission Approvals** — Allow / Always Allow / Deny tool calls without switching terminal
- 🔔 **Windows Notifications** — Toast alerts when sessions need attention
- 🐧 **WSL Support** — Works with Claude Code running inside WSL (WSL2 localhost forwarding)
- 🌐 **Remote SSH Support** — Monitor Claude Code on remote Linux servers via secure reverse SSH tunnels
- ⚙️ **Machine-Centric Config** — Manage multiple local and remote environments with separate Claude paths
- 🔄 **Auto Hook Sync** — Automatically deploys and configures hook scripts to local and remote machines

## Requirements

| Requirement | Version |
|-------------|---------|
| Windows     | 10 / 11 |
| Node.js     | 18+     |
| Python      | 3.8+    |
| Claude Code | Any     |
| OpenSSH     | Native Windows Client |

## Quick Start

```bat
cd windows
npm install
start.bat
```

On first launch the app will:
1. Start a TCP hook server on port `51515`
2. Auto-detect local Claude Code paths (Windows + WSL)
3. Show a tray icon — click it to open the panel and manage your **Machines**

## How It Works

### Local (Windows / WSL)
```
Claude Code CLI  ──►  Hook Script (Python)  ──►  TCP 127.0.0.1:51515  ──►  Claude Island App
  (Win or WSL)         ~/.claude/hooks/             (background server)       Tray + Popup Panel
```

### Remote (SSH)
```
Remote Claude CLI ──► Hook Script (Python) ──► SSH Reverse Tunnel ──► TCP 127.0.0.1:51515 ──► Claude Island App
 (Linux Server)        ~/.claude/hooks/         (Port 51515 Rwd)       (Windows Host)         Tray + Popup Panel
```

**SSH Tunneling:** The app uses your native `ssh` client to establish a reverse tunnel (`-R`). It automatically cleans up stale remote ports (`fuser -k`) to ensure stable reconnections. TCP Nagle's algorithm is disabled (`NoDelay`) to ensure instantaneous tool approval response times across the network.

## Machine Management

Claude Island organizes configuration by **Machine**:

### 🖥️ Local Machine
Automatically tracks your Windows and WSL environments. You can manually add paths like `\\wsl$\Ubuntu\home\user\.claude`.

### 🌐 Remote SSH Machines
- **Import from SSH Config**: Automatically scans your `~/.ssh/config` for hosts.
- **Custom Add**: Manually add hosts by alias or `user@hostname`.
- **Auto-Sync**: When you click **Connect**, the app automatically:
    1. Uploads the latest Python hook script to the remote machine.
    2. Configures the remote `~/.claude/settings.json` to use the bridge.
    3. Establishes the secure reverse tunnel.

## Configuration

Click the **⚙️** gear icon in the panel to open Settings:

| Setting | Description |
|---------|-------------|
| **Machines** | Add/Remove local paths or connect to remote SSH hosts. |
| **TCP Port** | Port for hook communication (default: `51515`). Remote tunnels use this same port. |
| **Notifications** | Enable/disable Windows toast notifications. |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Tray icon doesn't appear | Use `start.bat`, not `npm start`. Make sure `ELECTRON_RUN_AS_NODE` is not set. |
| Remote SSH Timeout | Ensure your local machine has a functional `ssh` client and can reach the host via terminal. |
| SSH Auth Fails | Use `ssh-add` in a terminal to add your private keys to the SSH agent before connecting. |
| Remote Hook Delay | Fixed: TCP NoDelay is now enforced to eliminate network buffering latency. |
| Empty reply from server | Fixed: Reverse tunnels are now explicitly bound to `127.0.0.1` to avoid IPv6 mismatches. |
| Port 51515 Conflict | The app now automatically kills stale remote listeners before starting a new tunnel. |

## File Structure

```
windows/
├── main.js              # Electron main process & IPC routing
├── src/
│   ├── config-store.js  # Machine-centric settings persistence
│   ├── tunnel-manager.js # SSH reverse tunnel & remote hook deployment
│   ├── hook-server.js   # TCP server with Low-Latency (NoDelay) optimization
│   ├── session-store.js # Session state machine
│   ├── ssh-config-reader.js # Parses ~/.ssh/config for easy host import
│   ├── tray-manager.js  # System tray icon with live status
│   └── hook-installer.js # Local hook deployment (Win/WSL)
├── renderer/
│   ├── index.html       # Popup panel with glassmorphism UI
│   └── app.js           # Machine management & Session UI logic
├── hooks/
│   └── claude-island-state.py  # High-performance Python bridge
└── start.bat            # Clean launch environment
```

## Known Limitations

- **SSH Agent**: Requires consistent use of `ssh-add` if keys are passphrase-protected.
- **ProxyJump**: Fully supported via native SSH config, though requires stable jump host connectivity.
- **WSL1**: Standard localhost mirroring is not available; upgrade to WSL2 is highly recommended.
