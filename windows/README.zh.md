# Claude Island for Windows（Windows 版）

一个 Windows 系统托盘应用，实时监控 **Claude Code CLI** 会话状态——在任务栏通知区直接查看会话状态、工具调用、权限审批，无需切换终端。

灵感来自 macOS 版 [Vibe Island](https://github.com/anthropics/vibe-island) 灵动岛体验。

## 功能特性

- 🖥️ **系统托盘** — 常驻图标，动态颜色指示状态（灰色空闲 / 紫色活跃 / 琥珀色待审批）
- 📋 **弹出面板** — 点击托盘图标展示所有活跃会话的状态和工具信息
- 🔐 **权限审批** — 直接点击 Allow / Always Allow / Deny，无需切回终端
- 🔔 **Windows 通知** — 会话需要关注时弹出 Toast 提醒
- 🐧 **WSL 支持** — 支持在 WSL 中运行的 Claude Code（通过 WSL2 localhost 转发）
- 🌐 **远程 SSH 支持** — 通过安全的反向 SSH 隧道监控远程 Linux 服务器上的 Claude Code
- ⚙️ **机器中心化配置** — 统一管理多个本地和远程环境，支持独立的 Claude 路径配置
- 🔄 **自动 Hook 同步** — 在连接时自动向本地和远程机器部署并配置 Hook 脚本

## 环境要求

| 依赖 | 版本 |
|------|------|
| Windows | 10 / 11 |
| Node.js | 18+ |
| Python | 3.8+ |
| Claude Code | 任意版本 |
| OpenSSH | Windows 原生 SSH 客户端 |

## 快速开始

```bat
cd windows
npm install
start.bat
```

首次启动时，应用会自动：
1. 在端口 `51515` 启动 TCP Hook 服务器
2. 自动检测本地 Claude Code 路径（Windows 原生及 WSL）
3. 显示系统托盘图标 — 点击即可打开面板并管理你的 **Machines（机器）**

## 工作原理

### 本地模式 (Windows / WSL)
```
Claude Code CLI  ──►  Hook 脚本（Python）  ──►  TCP 127.0.0.1:51515  ──►  Claude Island App
（Win 原生或 WSL）     ~/.claude/hooks/         （后台服务器）              托盘 + 弹出面板
```

### 远程模式 (SSH)
```
远程 Claude CLI  ──►  Hook 脚本（Python）  ──►  SSH 反向隧道  ──►  TCP 127.0.0.1:51515  ──►  Claude Island App
（Linux 服务器）       ~/.claude/hooks/       (51515 端口转发)      (Windows 宿主机)           托盘 + 弹出面板
```

**SSH 隧道机制：** 应用使用系统原生的 `ssh` 客户端建立反向隧道（`-R`）。在建立连接前会自动清理远程残留端口（`fuser -k`），确保重连稳定性。同时强制开启 TCP `NoDelay` 以消除网络缓冲导致的指令审批延迟。

## 机器管理 (Machine Management)

Claude Island 按照 **Machine** 维度组织配置：

### 🖥️ Local Machine（本地机器）
自动追踪 Windows 和 WSL 环境。支持手动添加如 `\\wsl$\Ubuntu\home\user\.claude` 的自定义路径。

### 🌐 Remote SSH Machines（远程机器）
- **从 SSH Config 导入**：自动扫描 `~/.ssh/config` 中的主机配置。
- **手动添加**：支持通过别名或 `user@hostname` 手动输入远程主机。
- **全自动同步**：点击 **Connect** 时，应用会自动：
    1. 将最新的 Python Hook 脚本上传到远程机器。
    2. 自动配置远程 `~/.claude/settings.json` 以连接桥接。
    3. 建立安全的反向 SSH 隧道。

## 配置

点击面板右上角的 **⚙️** 图标打开设置：

| 设置项 | 说明 |
|--------|------|
| **Machines** | 添加/删除本地路径，或连接管理远程 SSH 主机 |
| **TCP 端口** | Hook 通信端口（默认 `51515`），远程隧道亦共用此端口 |
| **通知** | 开关 Windows Toast 通知 |

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| 托盘图标没出现 | 使用 `start.bat` 启动，确认 `ELECTRON_RUN_AS_NODE` 未被设置 |
| 远程 SSH 连接超时 | 确保本地 `ssh` 客户端可用，且在终端能正常登录该主机 |
| SSH 认证失败 | 如果私钥有密码，请先在终端运行 `ssh-add` 将密钥加入 agent |
| 远程指令响应慢 | 已修复：通过禁用 TCP Nagle 算法（NoDelay）彻底消除了网络缓冲延迟 |
| 远程回传空回复 | 已修复：反向隧道现在显式绑定到 `127.0.0.1` 以避免 IPv6 匹配冲突 |
| 端口 51515 冲突 | 已修复：应用会在启动新隧道前自动杀掉远程残留的监听进程 |

## 项目结构

```
windows/
├── main.js              # Electron 主进程及 IPC 路由
├── src/
│   ├── config-store.js  # 以机器为中心的配置持久化
│   ├── tunnel-manager.js # SSH 反向隧道管理及远程 Hook 自动部署
│   ├── hook-server.js   # 高性能 TCP 服务器（NoDelay 优化）
│   ├── session-store.js # 会话状态机
│   ├── ssh-config-reader.js # 解析 ~/.ssh/config 方便导入主机
│   ├── tray-manager.js  # 系统托盘图标及状态管理
│   └── hook-installer.js # 本地 Hook 部署逻辑 (Win/WSL)
├── renderer/
│   ├── index.html       # 玻璃拟物 UI 面板
│   └── app.js           # 机器管理及会话交互逻辑
├── hooks/
│   └── claude-island-state.py  # 高性能 Python 桥接脚本
└── start.bat            # 纯净启动环境
```

## 已知限制

- **SSH Agent**：如果私钥受密码保护且未加入 agent，连接可能会在后台静默失败。
- **ProxyJump**：完全支持原生 SSH 配置，但需确保跳板机稳定性。
- **WSL1**：不支持自动 localhost 转发，强烈建议升级到 WSL2。
