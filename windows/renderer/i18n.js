/**
 * Claude Island Windows — i18n Module
 * Supports English and Chinese UI text
 */

const i18n = (() => {
  const translations = {
    en: {
      // App title
      appTitle: 'Claude Island',

      // Phase labels
      phase_idle: 'Idle',
      phase_processing: 'Processing',
      phase_waiting_for_input: 'Ready',
      phase_waiting_for_approval: 'Needs Approval',
      phase_compacting: 'Compacting',
      phase_ended: 'Ended',

      // Agent names
      agent_claude: 'Claude Code',
      agent_codex: 'Codex',
      agent_gemini: 'Gemini CLI',

      // Session card
      justNow: 'just now',
      secondsAgo: (n) => `${n}s ago`,
      minutesAgo: (n) => `${n}m ago`,
      hoursAgo: (n) => `${n}h ago`,

      // Permission actions
      allow: 'Allow',
      alwaysAllow: 'Always',
      deny: 'Deny',
      allowQuestion: (tool) => `Allow ${tool}?`,

      // Interaction
      send: 'Send',
      inputPlaceholder: 'Type your answer…',

      // Archive
      remove: 'Remove',

      // Empty state
      noActiveSessions: 'No Active Sessions',
      noActiveSessionsHint: 'Start Claude Code to see sessions here',

      // Header buttons
      settings: 'Settings',
      close: 'Close',

      // Settings sections
      sshConfig: 'SSH Config',
      machines: 'Machines',
      server: 'Server',
      notifications: 'Notifications',
      appearance: 'Appearance',
      language: 'Language',

      // Settings labels
      tcpPort: 'TCP Port',
      listenHost: 'Listen Host',
      firewallBtn: 'Re-check',
      firewallChecking: 'Checking…',
      firewallLoopback: 'Loopback mode — no firewall rule needed.',
      firewallOk: (port) => `Port ${port} is reachable.`,
      firewallBlocked: (port) => `Port ${port} is blocked. On Win10 WSL2, run in an elevated PowerShell:<br><code style="user-select:all">Set-NetFirewallProfile -DisabledInterfaceAliases "vEthernet (WSL)"</code><br><span style="font-size:10px;opacity:0.7">This disables firewall on the WSL virtual adapter only. To revert: <code style="user-select:all">Set-NetFirewallProfile -DisabledInterfaceAliases @()</code></span>`,
      enableNotifications: 'Enable notifications',
      notificationMode: 'Notification mode',
      notifModeSystem: 'System',
      notifModeInApp: 'In-app',
      notifModeOff: 'Off',
      notificationSound: 'Sound',
      soundNone: 'None',
      soundPop: 'Pop',
      soundPing: 'Ping',
      soundBell: 'Bell',
      soundChime: 'Chime',
      windowOpacity: 'Window opacity',

      // SSH / Machine
      browse: 'Browse',
      reset: 'Reset',
      importFromSshConfig: 'Import from SSH Config',
      addCustomHost: 'Add Custom Host',
      addPath: '+ Add Path',
      installHooks: 'Install Hooks',
      forceSync: 'Force Sync',
      addRemotePath: '+ Path',
      connect: 'Connect',
      disconnect: 'Disconnect',
      retry: 'Retry',
      cancel: 'Cancel',
      add: 'Add',

      // Machine status
      status_idle: 'Idle',
      status_connecting: 'Connecting…',
      status_installing_hooks: 'Installing…',
      status_connected: 'Connected',
      status_auth_required: 'Auth Required',
      status_port_conflict: 'Port Conflict',
      status_error: 'Error',
      status_disconnecting: 'Disconnecting',

      // Hook badges
      hooksInstalled: 'Hooks ✓',
      hooksNotInstalled: 'Hooks ✗',
      hooksNotFound: 'Not Found',
      autoSynced: 'Auto Synced ✓',
      noPathsConfigured: 'No paths configured',

      // Import dialog
      importSshHost: 'Import SSH Host',
      importSshHostBody: 'Select a host from your SSH config to add as a remote machine:',
      allHostsAdded: 'All SSH config hosts are already added.',

      // Auth dialog
      authRequired: 'Authentication Required',
      authBody: 'Your SSH key needs to be added to the SSH Agent.\nRun in any terminal:',
      copy: 'Copy',
      retryBtn: 'Retry',
      dismiss: 'Dismiss',

      // Notifications
      notif_permRequired: '🔐 Permission Required',
      notif_claudeReady: '✅ Claude is ready',
      notif_compacting: '📦 Compacting context',
      notif_waitingInput: 'Waiting for your input',

      // In-app notification
      clickToView: 'Click to view',
      interactionHint: 'Click option to copy, then paste in terminal',
    },

    zh: {
      // App title
      appTitle: 'Claude Island',

      // Phase labels
      phase_idle: '空闲',
      phase_processing: '处理中',
      phase_waiting_for_input: '就绪',
      phase_waiting_for_approval: '需要审批',
      phase_compacting: '压缩中',
      phase_ended: '已结束',

      // Agent names
      agent_claude: 'Claude Code',
      agent_codex: 'Codex',
      agent_gemini: 'Gemini CLI',

      // Session card
      justNow: '刚刚',
      secondsAgo: (n) => `${n}秒前`,
      minutesAgo: (n) => `${n}分钟前`,
      hoursAgo: (n) => `${n}小时前`,

      // Permission actions
      allow: '允许',
      alwaysAllow: '始终',
      deny: '拒绝',
      allowQuestion: (tool) => `允许 ${tool}？`,

      // Interaction
      send: '发送',
      inputPlaceholder: '输入你的回答…',

      // Archive
      remove: '移除',

      // Empty state
      noActiveSessions: '暂无活跃会话',
      noActiveSessionsHint: '启动 Claude Code 后会话将显示在这里',

      // Header buttons
      settings: '设置',
      close: '关闭',

      // Settings sections
      sshConfig: 'SSH 配置',
      machines: '机器管理',
      server: '服务器',
      notifications: '通知',
      appearance: '外观',
      language: '语言',

      // Settings labels
      tcpPort: 'TCP 端口',
      listenHost: '监听地址',
      firewallBtn: '重新检测',
      firewallChecking: '检测中…',
      firewallLoopback: '回环模式，无需防火墙规则。',
      firewallOk: (port) => `端口 ${port} 可达。`,
      firewallBlocked: (port) => `端口 ${port} 被阻止。Win10 WSL2 请在管理员 PowerShell 中运行：<br><code style="user-select:all">Set-NetFirewallProfile -DisabledInterfaceAliases "vEthernet (WSL)"</code><br><span style="font-size:10px;opacity:0.7">仅关闭 WSL 虚拟网卡的防火墙。恢复命令：<code style="user-select:all">Set-NetFirewallProfile -DisabledInterfaceAliases @()</code></span>`,
      enableNotifications: '启用通知',
      notificationMode: '通知方式',
      notifModeSystem: '系统通知',
      notifModeInApp: '应用内',
      notifModeOff: '关闭',
      notificationSound: '提示音',
      soundNone: '无',
      soundPop: '轻弹',
      soundPing: '叮',
      soundBell: '铃声',
      soundChime: '风铃',
      windowOpacity: '窗口透明度',

      // SSH / Machine
      browse: '浏览',
      reset: '重置',
      importFromSshConfig: '从 SSH 配置导入',
      addCustomHost: '添加自定义主机',
      addPath: '+ 添加路径',
      installHooks: '安装 Hooks',
      forceSync: '强制同步',
      addRemotePath: '+ 路径',
      connect: '连接',
      disconnect: '断开',
      retry: '重试',
      cancel: '取消',
      add: '添加',

      // Machine status
      status_idle: '空闲',
      status_connecting: '连接中…',
      status_installing_hooks: '安装中…',
      status_connected: '已连接',
      status_auth_required: '需要认证',
      status_port_conflict: '端口冲突',
      status_error: '错误',
      status_disconnecting: '断开中',

      // Hook badges
      hooksInstalled: 'Hooks ✓',
      hooksNotInstalled: 'Hooks ✗',
      hooksNotFound: '未找到',
      autoSynced: '自动同步 ✓',
      noPathsConfigured: '未配置路径',

      // Import dialog
      importSshHost: '导入 SSH 主机',
      importSshHostBody: '从 SSH 配置中选择一个主机添加为远程机器：',
      allHostsAdded: '所有 SSH 配置主机均已添加。',

      // Auth dialog
      authRequired: '需要认证',
      authBody: '需要将 SSH 密钥添加到 SSH Agent。\n在终端中运行：',
      copy: '复制',
      retryBtn: '重试',
      dismiss: '关闭',

      // Notifications
      notif_permRequired: '🔐 需要权限',
      notif_claudeReady: '✅ Claude 已就绪',
      notif_compacting: '📦 正在压缩上下文',
      notif_waitingInput: '等待你的输入',

      // In-app notification
      clickToView: '点击查看',
      interactionHint: '点击选项复制，然后在终端中粘贴',
    },
  };

  let currentLang = localStorage.getItem('ci_lang') || 'zh';

  function setLang(lang) {
    if (lang !== 'en' && lang !== 'zh') return;
    currentLang = lang;
    localStorage.setItem('ci_lang', lang);
  }

  function getLang() {
    return currentLang;
  }

  /**
   * Translate a key. If the value is a function, call it with args.
   * Falls back to English, then to the key itself.
   */
  function t(key, ...args) {
    const dict = translations[currentLang] || translations.en;
    const val = dict[key] ?? translations.en[key] ?? key;
    return typeof val === 'function' ? val(...args) : val;
  }

  return { t, setLang, getLang };
})();
