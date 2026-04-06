# Claude Island for Windows（Windows 版）

一个 Windows 系统托盘应用，实时监控 **Claude Code CLI** 会话状态——在任务栏通知区直接查看会话状态、工具调用、权限审批，无需切换终端。

灵感来自 macOS 版 [Vibe Island](https://github.com/anthropics/vibe-island) 灵动岛体验。

## 功能特性

- 🖥️ **系统托盘** — 像素风幽灵图标，实时状态颜色（灰色 / 靛蓝 / 琥珀）
- 📋 **弹出面板** — 点击托盘图标开关面板；需要关注时自动弹出
- 🎨 **像素风图标** — Canvas 绘制的状态图标（气泡 / 手掌 / 沙漏 / 横线），带动画效果
- 🦀 **Claude 螃蟹** — 头部像素风螃蟹吉祥物，颜色随会话状态变化
- 🔐 **权限审批** — 允许 / 始终允许 / 拒绝工具调用，带结构化代码预览
- 🔔 **应用内通知** — 浮动通知卡片 + 合成音效，不再被系统 Toast 打扰
- 🌐 **远程 SSH 支持** — 通过安全反向 SSH 隧道监控远端 Linux 服务器上的 Claude Code
- 🏷️ **正确的远端标签** — 远端会话显示 SSH 别名，而非机器的原始 hostname
- 🐧 **WSL 支持** — 支持运行在 WSL 内的 Claude Code（WSL2 localhost 转发）
- 🌍 **中文 / English** — 在设置中切换界面语言
- ⚙️ **机器管理** — 管理多个本地和远端环境，各自配置 Claude 路径
- 🔄 **自动 Hook 同步** — 自动部署和配置本地及远端机器的 hook 脚本

## 环境要求

| 要求 | 版本 |
|------|------|
| Windows | 10 / 11 |
| Node.js | 18+ |
| Python | 3.8+ |
| Claude Code | 任意版本 |
| OpenSSH | Windows 原生客户端 |

## 快速开始

```bat
cd windows
npm install
start.bat
```

首次启动时，应用会：
1. 在端口 `51515` 启动 TCP hook 服务器
2. 自动检测本地 Claude Code 路径（Windows + WSL）
3. 显示托盘图标——点击打开面板并管理**机器**

## 工作原理

### 本地（Windows / WSL）
```
Claude Code CLI  ──►  Hook 脚本（Python）  ──►  TCP 127.0.0.1:51515  ──►  Claude Island 应用
  （Win 或 WSL）       ~/.claude/hooks/           （后台服务器）              托盘 + 弹出面板
```

### 远端（SSH）
```
远端 Claude CLI ──► Hook 脚本（Python）──► SSH 反向隧道 ──► TCP 127.0.0.1:51515 ──► Claude Island 应用
 （Linux 服务器）    ~/.claude/hooks/      （端口 51515 转发）  （Windows 主机）       托盘 + 弹出面板
```

**SSH 隧道：** 应用使用原生 `ssh` 客户端建立反向隧道（`-R`），自动清理残留的远端端口（`fuser -k`）。TCP Nagle 算法已禁用（`NoDelay`）以确保工具审批响应即时送达。Hook 脚本注入 `--machine <别名>` 参数，远端会话始终显示正确的 SSH 别名。

## 通知模式

在**设置 → 通知**中选择：

| 模式 | 行为 |
|------|------|
| **应用内** | 浮动卡片从面板顶部滑入，可选音效 |
| **系统通知** | Windows Toast 通知（旧版行为） |
| **关闭** | 静默——需要审批时窗口仍会自动弹出 |

可选音效：无 / 轻弹 / 叮 / 铃声 / 风铃（通过 Web Audio API 合成）。

面板在以下状态自动弹出：`waiting_for_approval`、`waiting_for_input`、`compacting`、`idle`。**处理中（processing）时不弹出。**

## 机器管理

Claude Island 以**机器**为单位组织配置：

### 🖥️ 本地机器
自动检测 Windows 和 WSL 环境。可手动添加路径，如 `\\wsl$\Ubuntu\home\user\.claude`。

### 🌐 远端 SSH 机器
- **从 SSH 配置导入**：自动扫描 `~/.ssh/config` 中的主机。
- **自定义添加**：手动输入别名或 `user@hostname`。
- **自动同步**：点击**连接**后，应用自动：
    1. 上传最新 Python hook 脚本到远端机器。
    2. 配置远端 `~/.claude/settings.json` 使用桥接。
    3. 建立安全反向隧道。

## 配置项

点击面板中的 **⚙️** 图标打开设置：

| 设置项 | 说明 |
|--------|------|
| **机器管理** | 添加/删除本地路径或连接远端 SSH 主机 |
| **TCP 端口** | Hook 通信端口（默认：`51515`） |
| **通知方式** | 应用内 / 系统通知 / 关闭 |
| **提示音** | 通知音效 |
| **语言** | 中文 / English |

## 故障排查

| 问题 | 解决方法 |
|------|----------|
| 托盘图标不显示 | 使用 `start.bat` 而非 `npm start`，确保未设置 `ELECTRON_RUN_AS_NODE`。 |
| 远端 SSH 超时 | 确保本地 `ssh` 客户端可用，且能通过终端访问目标主机。 |
| SSH 认证失败 | 连接前在终端运行 `ssh-add` 将私钥添加到 SSH Agent。 |
| 远端会话显示错误名称 | 点击**强制同步**重新部署带 `--machine` 参数的 hook 脚本。 |
| 远端 Hook 延迟 | TCP NoDelay 已启用；剩余延迟来自 Python hook 进程启动（约 100-300ms）。 |
| 服务器无响应 | 反向隧道已绑定到 `127.0.0.1` 以避免 IPv6 不匹配。 |
| 端口 51515 冲突 | 应用会在建立新隧道前自动清理远端残留监听进程。 |

## 文件结构

```
windows/
├── main.js                  # Electron 主进程 & IPC 路由
├── preload.js               # 上下文隔离的 IPC 桥接
├── src/
│   ├── config-store.js      # 机器配置持久化
│   ├── tunnel-manager.js    # SSH 反向隧道 & 远端 hook 部署
│   ├── hook-server.js       # TCP 服务器（NoDelay 优化）
│   ├── session-store.js     # 会话状态机
│   ├── ssh-config-reader.js # 解析 ~/.ssh/config
│   ├── tray-manager.js      # 像素风幽灵托盘图标
│   ├── notification.js      # 系统通知处理
│   └── hook-installer.js    # 本地 hook 部署（Win/WSL）
├── renderer/
│   ├── index.html           # 弹出面板 HTML
│   ├── styles.css           # 玻璃拟态 UI 样式
│   ├── i18n.js              # 中英文翻译
│   ├── pixel-icons.js       # Canvas 像素风状态图标 + 螃蟹吉祥物
│   ├── notifications.js     # 应用内浮动通知卡片
│   ├── code-preview.js      # 结构化权限预览（Bash/Edit/Read/Web）
│   └── app.js               # 主渲染逻辑
├── hooks/
│   └── claude-island-state.py  # Python hook 桥接（支持 --machine 参数）
└── start.bat                # 干净的启动环境
```

## 已知限制

- **SSH Agent**：使用带密码的密钥时需持续使用 `ssh-add`。
- **ProxyJump**：通过原生 SSH 配置完全支持，但需要稳定的跳板机连接。
- **WSL1**：不支持标准 localhost 镜像，强烈建议升级到 WSL2。
- **聊天记录**：完整的对话历史视图需要后端文件读取 API（尚未实现）。
