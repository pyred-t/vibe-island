# Claude Island for Windows（Windows 版）

一个 Windows 系统托盘应用，实时监控 **Claude Code CLI** 会话状态——在任务栏通知区直接查看会话状态、工具调用、权限审批，无需切换终端。

灵感来自 macOS 版 [Vibe Island](https://github.com/anthropics/vibe-island) 灵动岛体验。

## 功能特性

- 🖥️ **系统托盘** — 常驻图标，动态颜色指示状态（灰色空闲 / 紫色活跃 / 琥珀色待审批）
- 📋 **弹出面板** — 点击托盘图标展示所有活跃会话的状态和工具信息
- 🔐 **权限审批** — 直接点击 Allow / Always Allow / Deny，无需切回终端
- 🔔 **Windows 通知** — 会话需要关注时弹出 Toast 提醒
- 🐧 **WSL 支持** — 支持在 WSL 中运行的 Claude Code（通过 WSL2 localhost 转发）
- 📁 **路径配置** — 可添加任意 `.claude` 目录，包括 `\\wsl$\Ubuntu\home\user\.claude` 等 WSL 路径
- ⚙️ **自动安装 Hook** — 自动将 Python hook 脚本写入 Claude Code 的 `settings.json`

## 环境要求

| 依赖 | 版本 |
|------|------|
| Windows | 10 / 11 |
| Node.js | 18+ |
| Python | 3.8+ |
| Claude Code | 任意版本 |

## 快速开始

```bat
cd windows
npm install
start.bat
```

首次启动时，应用会自动：
1. 在端口 `51515` 启动 TCP Hook 服务器
2. 自动检测 Claude Code 路径（Windows 原生及 WSL）
3. 向所有检测到的 `~/.claude/` 目录安装 hook 脚本
4. 显示系统托盘图标 — 点击即可打开面板

## 工作原理

```
Claude Code CLI  ──►  Hook 脚本（Python）  ──►  TCP 127.0.0.1:51515  ──►  Claude Island App
（Win 原生或 WSL）     ~/.claude/hooks/         （后台服务器）              托盘 + 弹出面板
```

### Hook 脚本

hook 脚本 `hooks/claude-island-state.py` 安装在 `~/.claude/hooks/`，由 Claude Code 在每个事件（会话开始/结束、工具调用、权限请求等）时触发调用。它通过 TCP 而非 Unix Socket 与应用通信，兼容 Windows 原生和 WSL 两种环境。

**WSL 说明：** WSL2 会自动将 `localhost` 转发到 Windows 宿主机，WSL 中的 Claude Code 可直接通过 `127.0.0.1:51515` 连接到 Windows 应用。

## 配置

点击面板右上角的 **⚙️** 图标打开设置：

| 设置项 | 说明 |
|--------|------|
| **Claude Code 路径** | Claude Code 配置目录列表，可添加 WSL 路径 |
| **TCP 端口** | Hook 通信端口（默认 `51515`）|
| **通知** | 开关 Windows Toast 通知 |

### 添加 WSL 路径

1. 打开设置 → 点击 **Add Path**
2. 浏览到 `\\wsl$\<发行版名>\home\<用户名>\.claude`
3. 点击 **Install / Reinstall Hooks**

写入 hook 命令时，应用会自动将 Windows UNC 路径转换为 WSL 内部路径，Claude Code 在 WSL 中会看到脚本位于 `/home/<用户名>/.claude/hooks/claude-island-state.py`。

## 启动方式

必须通过 `start.bat` 启动（而非 `npm start`），因为部分工具会设置 `ELECTRON_RUN_AS_NODE` 环境变量，该变量会破坏 Electron API 的加载。

```bat
windows\start.bat
```

## 开发与测试

```bat
# 启动应用
start.bat

# 在另一个终端模拟完整会话生命周期
node test/send-test-event.js all

# 测试特定事件类型
node test/send-test-event.js permission   # 等待你点击 Allow/Deny
node test/send-test-event.js processing
node test/send-test-event.js waiting

# 验证 Windows 编码处理（中文路径、非 ASCII 内容）
python test/test-encoding.py
```

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| 托盘图标没出现 | 使用 `start.bat` 启动，确认 `ELECTRON_RUN_AS_NODE` 未被设置 |
| 会话没有显示 | 设置 → Hooks → 点击 **Install / Reinstall Hooks** |
| Windows 下状态不准确 | 已修复：hook 脚本现在强制使用 UTF-8 读写 stdin/stdout，解决了中文路径和非 ASCII 工具输出导致的解析失败 |
| WSL 会话未连接 | 确认使用的是 WSL2（WSL1 不支持 localhost 转发）|
| 端口冲突 | 在设置面板修改端口，重新安装 Hook 后生效 |

## 项目结构

```
windows/
├── main.js              # Electron 主进程
├── preload.js           # 安全 IPC 桥接（contextBridge）
├── start.bat            # 启动脚本（清除 ELECTRON_RUN_AS_NODE）
├── src/
│   ├── config-store.js  # 配置持久化（存储在 AppData/Roaming/ClaudeIsland/）
│   ├── hook-server.js   # TCP 服务器，接收 hook 事件，保持权限请求连接
│   ├── session-store.js # 会话状态机
│   ├── hook-installer.js # 安装 hook 脚本到 Claude Code settings.json
│   ├── tray-manager.js  # 系统托盘图标，程序化生成状态指示色
│   └── notification.js  # Windows Toast 通知
├── renderer/
│   ├── index.html       # 弹出面板 HTML
│   ├── styles.css       # 深色主题，玻璃拟物 + 微动画
│   └── app.js           # 前端逻辑：会话列表、权限操作、设置面板
├── hooks/
│   └── claude-island-state.py  # TCP 版 hook 脚本（Windows + WSL 兼容）
└── test/
    ├── send-test-event.js  # 通过 TCP 模拟发送 hook 事件
    ├── diag-connection.py  # 连接诊断工具
    └── test-encoding.py    # 验证 Windows GBK→UTF-8 编码修复
```

## 已知限制

- 权限审批 UI 会自动弹窗，但若错过，Hook 在 5 分钟后超时，工具调用将在无审批的情况下继续
- 需要在 Claude Code 启动会话前先运行本应用，Hook 才能正常连接
- 暂未实现开机自启（计划中）
