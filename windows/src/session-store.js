/**
 * Session Store for Claude Island Windows
 * Tracks active Claude Code sessions and their state transitions.
 */
const { EventEmitter } = require('events');

/**
 * Session phases matching the macOS version
 */
const SessionPhase = {
  IDLE: 'idle',
  PROCESSING: 'processing',
  WAITING_FOR_INPUT: 'waiting_for_input',
  WAITING_FOR_APPROVAL: 'waiting_for_approval',
  COMPACTING: 'compacting',
  ENDED: 'ended',
};

class SessionStore extends EventEmitter {
  constructor() {
    super();
    // Map<sessionId, SessionState>
    this._sessions = new Map();
  }

  /**
   * Process a hook event and update session state
   */
  processHookEvent(event) {
    const sessionId = event.session_id;
    if (!sessionId) return;

    let session = this._sessions.get(sessionId);
    const isNew = !session;

    if (!session) {
      session = this._createSession(sessionId, event);
      this._sessions.set(sessionId, session);
    }

    // Update session fields
    if (event.cwd) session.cwd = event.cwd;
    if (event.pid) session.pid = event.pid;
    if (event.tty) session.tty = event.tty;
    if (event.agent_id) session.agentId = event.agent_id;
    if (event.hostname) session.hostname = event.hostname;
    if (event.is_remote !== undefined) session.isRemote = event.is_remote;
    session.lastEventAt = new Date();
    session.lastEvent = event.event;

    // Map event to phase
    const prevPhase = session.phase;
    session.phase = this._mapEventToPhase(event);

    // Handle permission context
    if (session.phase === SessionPhase.WAITING_FOR_APPROVAL) {
      session.activePermission = {
        toolUseId: event.tool_use_id || '',
        toolName: event.tool || 'unknown',
        toolInput: event.tool_input || {},
        receivedAt: new Date(),
      };
    } else if (prevPhase === SessionPhase.WAITING_FOR_APPROVAL && session.phase !== SessionPhase.WAITING_FOR_APPROVAL) {
      session.activePermission = null;
    }

    // Handle interaction context (AskUserQuestion)
    if (event.event === 'PreToolUse' && event.tool === 'AskUserQuestion') {
      session.activeInteraction = {
        toolUseId: event.tool_use_id || '',
        toolName: event.tool,
        toolInput: event.tool_input || {},
        receivedAt: new Date(),
      };
    }

    // Handle tool info
    if (event.event === 'PreToolUse' || event.event === 'PostToolUse') {
      session.lastTool = event.tool || null;
      session.lastToolInput = event.tool_input || null;
    }

    // Handle session end
    if (event.event === 'SessionEnd' || event.status === 'ended') {
      session.phase = SessionPhase.ENDED;
      session.endedAt = new Date();
    }

    // Handle notification
    if (event.event === 'Notification') {
      session.lastNotification = {
        type: event.notification_type,
        message: event.message,
        receivedAt: new Date(),
      };
    }

    // Emit events
    if (isNew) {
      this.emit('sessionCreated', session);
    }
    this.emit('sessionUpdated', session);
    this.emit('changed', this.getAllSessions());

    // Emit specific phase transition events
    if (prevPhase !== session.phase) {
      this.emit('phaseChanged', session, prevPhase, session.phase);
    }

    return session;
  }

  /**
   * Create a new session state object
   */
  _createSession(sessionId, event) {
    return {
      sessionId,
      agentId: event.agent_id || 'claude',
      cwd: event.cwd || '',
      pid: event.pid || null,
      tty: event.tty || null,
      hostname: event.hostname || null,
      isRemote: event.is_remote || false,
      phase: SessionPhase.IDLE,
      lastEvent: null,
      lastEventAt: new Date(),
      lastTool: null,
      lastToolInput: null,
      lastNotification: null,
      activePermission: null,
      activeInteraction: null,
      createdAt: new Date(),
      endedAt: null,
    };
  }

  /**
   * Map hook event to session phase
   */
  _mapEventToPhase(event) {
    if (event.event === 'PreCompact') return SessionPhase.COMPACTING;
    if (event.event === 'SessionEnd') return SessionPhase.ENDED;

    switch (event.status) {
      case 'waiting_for_approval':
        return SessionPhase.WAITING_FOR_APPROVAL;
      case 'waiting_for_input':
        return SessionPhase.WAITING_FOR_INPUT;
      case 'running_tool':
      case 'processing':
      case 'starting':
        return SessionPhase.PROCESSING;
      case 'compacting':
        return SessionPhase.COMPACTING;
      case 'ended':
        return SessionPhase.ENDED;
      default:
        return SessionPhase.IDLE;
    }
  }

  /**
   * Handle permission being approved
   */
  permissionApproved(sessionId, toolUseId) {
    const session = this._sessions.get(sessionId);
    if (!session) return;

    if (session.activePermission && session.activePermission.toolUseId === toolUseId) {
      session.activePermission = null;
      session.phase = SessionPhase.PROCESSING;
      this.emit('sessionUpdated', session);
      this.emit('changed', this.getAllSessions());
    }
  }

  /**
   * Handle permission being denied
   */
  permissionDenied(sessionId, toolUseId) {
    const session = this._sessions.get(sessionId);
    if (!session) return;

    if (session.activePermission && session.activePermission.toolUseId === toolUseId) {
      session.activePermission = null;
      session.phase = SessionPhase.PROCESSING;
      this.emit('sessionUpdated', session);
      this.emit('changed', this.getAllSessions());
    }
  }

  /**
   * Handle interaction being submitted
   */
  interactionSubmitted(sessionId, toolUseId) {
    const session = this._sessions.get(sessionId);
    if (!session) return;

    if (session.activeInteraction && session.activeInteraction.toolUseId === toolUseId) {
      session.activeInteraction = null;
      session.phase = SessionPhase.PROCESSING;
      this.emit('sessionUpdated', session);
      this.emit('changed', this.getAllSessions());
    }
  }

  /**
   * Remove a session
   */
  removeSession(sessionId) {
    this._sessions.delete(sessionId);
    this.emit('changed', this.getAllSessions());
  }

  /**
   * Get a specific session
   */
  getSession(sessionId) {
    return this._sessions.get(sessionId);
  }

  /**
   * Get all active sessions (not ended)
   */
  getActiveSessions() {
    return Array.from(this._sessions.values())
      .filter(s => s.phase !== SessionPhase.ENDED)
      .sort((a, b) => b.lastEventAt - a.lastEventAt);
  }

  /**
   * Get all sessions including ended ones
   */
  getAllSessions() {
    return Array.from(this._sessions.values())
      .sort((a, b) => b.lastEventAt - a.lastEventAt);
  }

  /**
   * Get sessions that need attention (waiting for approval/input)
   */
  getPendingSessions() {
    return this.getActiveSessions().filter(s =>
      s.phase === SessionPhase.WAITING_FOR_APPROVAL ||
      s.phase === SessionPhase.WAITING_FOR_INPUT
    );
  }

  /**
   * Clean up old ended sessions
   */
  cleanup(maxAgeMs = 300000) {
    const now = Date.now();
    for (const [id, session] of this._sessions) {
      if (session.phase === SessionPhase.ENDED && session.endedAt) {
        if (now - session.endedAt.getTime() > maxAgeMs) {
          this._sessions.delete(id);
        }
      }
    }
    this.emit('changed', this.getAllSessions());
  }
}

module.exports = { SessionStore: new SessionStore(), SessionPhase };
