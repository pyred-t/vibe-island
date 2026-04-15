# Claude Island Windows — Hook 系统文档

## 概述

Hook 系统是 Claude Island 与 Claude Code 通信的核心机制。整体分为三层：

```
Claude Code 进程
    │
    │ (调用 hook 脚本，通过 stdin 传入 JSON 事件)
    ▼
claude-island-state.py   ← hooks/目录，安装到 ~/.claude/hooks/
    │
    │ (TCP 连接到 Windows 本机 / WSL host IP)
    ▼
HookServer (Node.js TCP)  ← src/hook-server.js，监听 127.0.0.1:51515
    │
    │ (emit hookEvent)
    ▼
SessionStore              ← src/session-store.js，维护 session 状态
    │
    │ (emit changed / phaseChanged)
    ▼
主窗口 / Tray              ← main.js，驱动 UI 更新和窗口弹出
```

---

## 一、Hook 脚本：`hooks/claude-island-state.py`

### 作用

Claude Code 每次触发 hook event 时调用此脚本。脚本从 `stdin` 读取事件 JSON，通过 TCP socket 发送给 Claude Island 应用，并在需要时等待用户决策响应。

### 部署位置

安装后会被复制到每个 Claude Code 配置目录的 `hooks/` 子目录：

```
~/.claude/hooks/claude-island-state.py           ← Windows 原生
//wsl$/Ubuntu/home/user/.claude/hooks/...        ← WSL 路径
```

### 调用方式（由 `settings.json` 配置）

**Windows 原生：**
```
python "C:\...\claude-island-state.py" --port 51515 --host 127.0.0.1
```

**WSL（非镜像模式）：**
```
python3 /home/user/.claude/hooks/claude-island-state.py --port 51515 --host $(awk '/^nameserver/{print $2;exit}' /etc/resolv.conf)
```

**远程 SSH 机器（由 TunnelManager 注入）：**
```
python3 ~/.claude/hooks/claude-island-state.py --port 51515 --host 127.0.0.1 --machine my-server
```

### 命令行参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--port` | `51515` | 连接的 TCP 端口 |
| `--host` | 自动检测 | 目标 host；WSL 下会尝试 127.0.0.1，失败则读取 resolv.conf |
| `--machine` | 无 | 远程机器别名，由 TunnelManager 注入，用于标识来源机器 |

### Hook 事件处理逻辑

| Claude Code 事件 | 脚本行为 | 发送给 app 的 `status` | 是否等待响应 |
|------------------|---------|----------------------|------------|
| `UserPromptSubmit` | 发送状态 | `processing` | ❌ |
| `PreToolUse` (普通工具) | 发送状态 | `running_tool` | ❌ |
| `PreToolUse` + `AskUserQuestion` | 发送后立即退出（fire-and-forget） | `waiting_for_input` | ❌ |
| `PreToolUse` + `ExitPlanMode` | 发送后立即退出（fire-and-forget） | `waiting_for_approval` | ❌ |
| `PostToolUse` | 发送状态 | `processing` | ❌ |
| `PermissionRequest` (普通工具) | 发送并**阻塞等待**用户决策 | `waiting_for_approval` | ✅ 最长 5 分钟 |
| `PermissionRequest` + `AskUserQuestion` | 直接退出（Claude Code 自己处理） | 无 | ❌ |
| `Notification` + `permission_prompt` | 直接退出 | 无 | ❌ |
| `Notification` + `idle_prompt` | 发送状态 | `waiting_for_input` | ❌ |
| `Stop` | 发送状态 | `waiting_for_input` | ❌ |
| `SubagentStop` | 发送状态 | `waiting_for_input` | ❌ |
| `SessionStart` | 发送状态 | `waiting_for_input` | ❌ |
| `SessionEnd` | 发送状态 | `ended` | ❌ |
| `PreCompact` | 发送状态 | `compacting` | ❌ |

### PermissionRequest 响应格式

等待响应时，app 通过同一个 TCP 连接回写 JSON：

```json
{ "decision": "allow" }
{ "decision": "always_allow" }
{ "decision": "deny", "reason": "Denied by user via Claude Island" }
```

脚本根据 `decision` 输出对应的 `hookSpecificOutput` 给 Claude Code：

- `allow` → `{"behavior": "allow"}`
- `always_allow` → `{"behavior": "allow", "updatedPermissions": [...]}` （使用 `permission_suggestions`）
- `deny` → `{"behavior": "deny", "message": "..."}`

### 特殊适配

- **Windows 编码**：在 Windows Python 上强制将 stdin/stdout/stderr 重新包装为 UTF-8，避免中文 Windows 默认 GBK 编码造成解析错误。
- **WSL host 检测**：`detect_host()` 先尝试 127.0.0.1，失败则读取 `/etc/resolv.conf` 中的 nameserver（WSL2 非镜像模式下为 Windows 宿主机 IP）。
- **连接超时**：连接阶段 3 秒超时，确保 app 未运行时不阻塞 Claude Code。

---

## 二、Hook 安装器：`src/hook-installer.js`

### 作用

负责将 `claude-island-state.py` 复制到目标 Claude Code 配置目录，并向 `settings.json` 写入 hook 注册项。

### 安装流程

1. 检查目标 `claudeConfigPath` 是否存在
2. 创建 `<claudeConfigPath>/hooks/` 目录（如不存在）
3. 复制 `claude-island-state.py` 到该目录
4. 读取并更新 `<claudeConfigPath>/settings.json`：
   - 先调用 `_stripManagedHooks()` 清除已有的 Claude Island hook 条目（防止重复）
   - 写入所有 hook 事件的注册配置

### 注册的 Hook 事件

| 事件 | 配置特点 |
|------|---------|
| `UserPromptSubmit` | 无 matcher，无 timeout |
| `PreToolUse` | `matcher: '*'`，**timeout: 86400s**（等待用户审批） |
| `PostToolUse` | `matcher: '*'` |
| `PermissionRequest` | `matcher: '*'`，**timeout: 86400s** |
| `Notification` | `matcher: '*'` |
| `Stop` | 无 matcher |
| `SubagentStop` | 无 matcher |
| `SessionStart` | 无 matcher |
| `SessionEnd` | 无 matcher |
| `PreCompact` | `matcher: 'auto'` 和 `matcher: 'manual'` 各一条 |

> **为什么 `PreToolUse` 和 `PermissionRequest` 需要 86400s timeout？**  
> 因为脚本在等待用户通过 GUI 审批权限时会阻塞，用户可能需要较长时间才能响应。86400s = 24 小时，确保不会因超时而自动失败。

### WSL 路径处理

当 `claudeConfigPath` 形如 `//wsl$/Ubuntu/...` 或 `//wsl.localhost/...` 时：
- 自动将 Windows 路径转换为 WSL 内部路径（如 `/home/user/.claude`）
- host 参数使用 shell 表达式 `$(awk '/^nameserver/{print $2;exit}' /etc/resolv.conf)` 动态获取宿主机 IP

### 卸载

`uninstall(claudeConfigPath)` 会：
1. 删除 hook 脚本文件
2. 从 `settings.json` 中移除所有 Claude Island 管理的 hook 条目
3. 清理 `configStore` 中的安装记录

---

## 三、TCP Hook 服务器：`src/hook-server.js`

### 作用

在 Windows 主进程中监听 TCP 连接，接收来自 Python hook 脚本的事件，对需要用户决策的事件保持 socket 连接并在用户操作后回写响应。

### 监听配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| host | `127.0.0.1` | 监听 host，可通过设置页改为 `0.0.0.0` 以支持 WSL/远程 |
| port | `51515` | 监听端口 |

### 消息处理策略

**普通事件（fire-and-forget）：**
```
Python → 发送 JSON → close()
Node  → 收到 → emit('hookEvent') → 关闭 socket
```

**需要响应的事件（PermissionRequest / waiting_for_approval）：**
```
Python → 发送 JSON → 保持连接等待
Node  → 收到 → 存入 _pendingPermissions Map → 保持 socket 开放
用户点击 Allow/Deny
→ respondToPermission() → 写入决策 JSON → end()
Python → 收到响应 → 输出 hookSpecificOutput → 退出
```

### 数据接收机制

为处理 TCP 分包，使用三层保障：
1. `socket.on('data')` 累积数据，并设 5ms 空闲计时器
2. `socket.on('end')` 客户端关闭写端时立即处理
3. `socket.on('close')` 兜底，5s 硬超时限制

### 待处理队列管理

| 方法 | 说明 |
|------|------|
| `respondToPermission(toolUseId, decision, reason)` | 回复权限请求（allow/always_allow/deny） |
| `respondToInteraction(toolUseId, updatedInput)` | 回复交互请求 |
| `denyInteraction(toolUseId, reason)` | 拒绝/关闭交互 |
| `cancelPendingPermissions(sessionId)` | 取消某个 session 的所有待处理权限（Stop 事件时调用） |
| `cancelPendingPermission(toolUseId)` | 取消特定权限请求（PostToolUse 时调用，工具已完成） |

---

## 四、Session Store：`src/session-store.js`

### 作用

将 hook 事件流转换为结构化的 session 状态，驱动 UI 渲染和窗口弹出决策。

### Session 状态字段

| 字段 | 说明 |
|------|------|
| `sessionId` | Claude Code session UUID |
| `phase` | 当前状态（见下表） |
| `cwd` | 工作目录 |
| `hostname` | 机器名（本地或远程） |
| `isRemote` | 是否为远程 SSH 机器 |
| `activePermission` | 当前待审批的权限请求 |
| `activeInteraction` | 当前待显示的 AskUserQuestion |
| `activePlan` | ExitPlanMode 的计划内容 |
| `lastTool` / `lastToolInput` | 最近使用的工具 |

### Session Phase 状态机

```
IDLE
  │
  ├─ UserPromptSubmit ──────────────────────────────► PROCESSING
  │                                                       │
  │   ◄──── PostToolUse ────── PreToolUse ◄───────────────┤
  │                                              PermissionRequest
  │                                                       │
  │                                              WAITING_FOR_APPROVAL
  │                                               Allow/Deny ▼
  │                                                   PROCESSING
  │
  ├─ Stop / SubagentStop / SessionStart ──────► WAITING_FOR_INPUT
  │
  ├─ PreCompact ──────────────────────────────► COMPACTING
  │
  └─ SessionEnd ──────────────────────────────► ENDED
```

### 触发窗口弹出的 Phase 变化

在 `main.js` 的 `wireEvents()` 中，以下 phase 变化会强制弹出窗口：

- **所有** phase 变化，除了 → `PROCESSING` 和 → `ENDED`

即 `WAITING_FOR_INPUT`、`WAITING_FOR_APPROVAL`、`COMPACTING`、`IDLE` 变化时都会弹出。这是有意的强提醒设计。

---

## 五、配合关系总结

```
Claude Code Hook 事件
        │
        ▼
claude-island-state.py
  ├─ PermissionRequest → 阻塞等待响应（最长 5 分钟）
  └─ 其他事件 → fire-and-forget
        │
        ▼ TCP :51515
HookServer
  ├─ 普通事件 → emit('hookEvent') → 关闭连接
  └─ PermissionRequest → 保持连接 → 存入 _pendingPermissions
        │
        ▼ emit('hookEvent')
SessionStore.processHookEvent()
  ├─ 更新 session 状态
  ├─ emit('changed') → 更新 UI / Tray
  └─ emit('phaseChanged') → 触发 showWindow()（非 PROCESSING/ENDED）
        │
        ▼ (用户操作)
ipcMain('approve-permission' / 'deny-permission')
  └─ HookServer.respondToPermission()
        └─ 通过保持的 TCP socket 回写决策
                └─ Python 脚本收到响应，输出 hookSpecificOutput，退出
```
