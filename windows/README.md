# Claude Island for Windows

A Windows system tray application that monitors **Claude Code CLI** sessions in real time — showing session status, tool activity, and permission approval dialogs right from your taskbar notification area.

Inspired by the macOS [Vibe Island](https://github.com/aczeccssa/vibe-island) Dynamic Island experience.

## Features

- 🖥️ **System Tray** — Pixel-art ghost icon with live status color (slate / indigo / amber)
- 📋 **Popup Panel** — Click tray icon to open/close; auto-shows when attention is needed; click outside to dismiss
- 🎨 **Pixel-Art Icons** — Canvas-drawn status icons (speech bubble / hand / hourglass / dash) with animations
- 🦀 **Claude Crab** — Animated pixel-art crab mascot in the header, color-coded by session state
- 🔐 **Permission Approvals** — Allow / Always Allow / Deny tool calls with structured code preview
- 💬 **AskUserQuestion** — Read-only display of Claude's questions and options (non-blocking, answer in terminal)
- 📝 **Markdown Rendering** — Lightweight renderer for questions and descriptions (code blocks, bold, links, lists)
- 🔔 **In-App Notifications** — Floating notification cards with synthesized sound effects (optional)
- 🌐 **Remote SSH Support** — Monitor Claude Code on remote Linux servers via secure reverse SSH tunnels
- 🏷️ **Correct Remote Labels** — Remote sessions show the SSH alias name, not the machine's raw hostname
- 🐧 **WSL Support** — Works with Claude Code running inside WSL (WSL2 localhost forwarding)
- 🌍 **中文 / English** — Switch UI language in Settings
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

**SSH Tunneling:** The app uses your native `ssh` client to establish a reverse tunnel (`-R`). It automatically cleans up stale remote ports (`fuser -k`) to ensure stable reconnections. TCP Nagle's algorithm is disabled (`NoDelay`) for instantaneous tool approval response times. The hook script is injected with `--machine <alias>` so remote sessions always display the correct SSH alias name.

## Notification Modes

Open **Settings → Notifications** to choose:

| Mode | Behavior |
|------|----------|
| **In-app** | Floating cards slide in from the top of the panel with optional sound |
| **System** | Windows toast notifications (legacy behavior) |
| **Off** | Silent — window still auto-shows when approval is needed |

Available sounds: None / Pop / Ping / Bell / Chime (synthesized via Web Audio API).

The panel auto-shows when a session needs your attention (`waiting_for_approval`, `waiting_for_input`, `compacting`, `idle`). It does **not** pop up during `processing`.

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
| **Machines** | Add/Remove local paths or connect to remote SSH hosts |
| **TCP Port** | Port for hook communication (default: `51515`) |
| **Notification mode** | In-app / System / Off |
| **Sound** | Notification sound effect |
| **Language** | 中文 / English |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Tray icon doesn't appear | Use `start.bat`, not `npm start`. Make sure `ELECTRON_RUN_AS_NODE` is not set. |
| Remote SSH Timeout | Ensure your local machine has a functional `ssh` client and can reach the host via terminal. |
| SSH Auth Fails | Use `ssh-add` in a terminal to add your private keys to the SSH agent before connecting. |
| Remote session shows wrong name | Click **Force Sync** to re-deploy the hook script with the correct `--machine` flag. |
| Remote Hook Delay | TCP NoDelay is enforced; remaining latency is Python hook process startup (~100-300ms). |
| Empty reply from server | Reverse tunnels are explicitly bound to `127.0.0.1` to avoid IPv6 mismatches. |
| Port 51515 Conflict | The app automatically kills stale remote listeners before starting a new tunnel. |

## File Structure

```
windows/
├── main.js                  # Electron main process & IPC routing
├── preload.js               # Context-isolated IPC bridge
├── src/
│   ├── config-store.js      # Machine-centric settings persistence
│   ├── tunnel-manager.js    # SSH reverse tunnel & remote hook deployment
│   ├── hook-server.js       # TCP server with NoDelay optimization
│   ├── session-store.js     # Session state machine
│   ├── ssh-config-reader.js # Parses ~/.ssh/config for easy host import
│   ├── tray-manager.js      # Pixel-art ghost tray icon with live status
│   ├── notification.js      # System notification handler
│   └── hook-installer.js    # Local hook deployment (Win/WSL)
├── renderer/
│   ├── index.html           # Popup panel HTML
│   ├── styles.css           # Glassmorphism UI styles
│   ├── i18n.js              # Chinese / English translations
│   ├── pixel-icons.js       # Canvas pixel-art status icons + crab mascot
│   ├── notifications.js     # In-app floating notification cards
│   ├── code-preview.js      # Structured permission preview (Bash/Edit/Read/Web)
│   ├── markdown-lite.js     # Lightweight Markdown renderer (no dependencies)
│   └── app.js               # Main renderer logic
├── hooks/
│   └── claude-island-state.py  # Python hook bridge (supports --machine flag)
└── start.bat                # Clean launch environment
```

## Known Limitations

- **SSH Agent**: Requires consistent use of `ssh-add` if keys are passphrase-protected.
- **ProxyJump**: Fully supported via native SSH config, though requires stable jump host connectivity.
- **WSL1**: Standard localhost mirroring is not available; upgrade to WSL2 is highly recommended.
- **Chat History**: Full conversation history view requires a backend file-reading API (not yet implemented).
