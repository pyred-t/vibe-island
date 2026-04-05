/**
 * TCP Hook Server for Claude Island Windows
 * Receives events from Python hook scripts via TCP socket.
 * Supports request/response for permission decisions.
 */
const net = require('net');
const { EventEmitter } = require('events');

class HookServer extends EventEmitter {
  constructor() {
    super();
    this._server = null;
    this._pendingPermissions = new Map(); // toolUseId -> { socket, event, receivedAt }
    this._pendingInteractions = new Map();
  }

  /**
   * Start the TCP server on the given port
   */
  start(port = 51515) {
    if (this._server) return;

    this._server = net.createServer((socket) => {
      this._handleClient(socket);
    });

    this._server.on('error', (err) => {
      console.error('Hook server error:', err);
      this.emit('error', err);
    });

    this._server.listen(port, '127.0.0.1', () => {
      console.log(`Hook server listening on 127.0.0.1:${port}`);
      this.emit('started', port);
    });
  }

  /**
   * Stop the server and clean up all pending connections
   */
  stop() {
    // Close all pending permission sockets
    for (const [id, pending] of this._pendingPermissions) {
      try { pending.socket.destroy(); } catch (e) {}
    }
    this._pendingPermissions.clear();

    for (const [id, pending] of this._pendingInteractions) {
      try { pending.socket.destroy(); } catch (e) {}
    }
    this._pendingInteractions.clear();

    if (this._server) {
      this._server.close();
      this._server = null;
    }
  }

  /**
   * Handle an incoming client connection
   */
  _handleClient(socket) {
    let data = Buffer.alloc(0);
    let processed = false;
    let processTimer = null;

    const tryProcess = () => {
      if (processed || data.length === 0) return;
      processed = true;
      if (processTimer) { clearTimeout(processTimer); processTimer = null; }
      this._processMessage(socket, data);
    };

    socket.on('data', (chunk) => {
      data = Buffer.concat([data, chunk]);
      // Reset the idle timer each time data arrives
      if (processTimer) clearTimeout(processTimer);
      processTimer = setTimeout(tryProcess, 80);
    });

    // Process when client closes write side (most common for fire-and-forget)
    socket.on('end', tryProcess);

    // Process on full close if not yet done
    socket.on('close', tryProcess);

    socket.on('error', (err) => {
      if (processTimer) clearTimeout(processTimer);
      // still try to process whatever we got
      if (!processed && data.length > 0) tryProcess();
    });

    // Hard timeout: give up waiting after 5s
    socket.setTimeout(5000, () => {
      if (!processed) tryProcess();
      else socket.destroy();
    });
  }

  /**
   * Parse and process a received message
   */
  _processMessage(socket, data) {
    if (data.length === 0) {
      socket.destroy();
      return;
    }

    let event;
    try {
      event = JSON.parse(data.toString('utf-8'));
    } catch (err) {
      console.warn('[HookServer] Failed to parse event, raw:', data.toString('utf-8').substring(0, 200));
      socket.destroy();
      return;
    }

    console.log(`[HookServer] event=${event.event} status=${event.status} session=${event.session_id}`);

    // Determine if this event expects a response
    const expectsResponse = this._eventExpectsResponse(event);

    if (expectsResponse) {
      const toolUseId = event.tool_use_id || `${event.session_id}-${event.tool || 'unknown'}-${Date.now()}`;
      event.tool_use_id = toolUseId;

      const responseKind = this._getResponseKind(event);

      if (responseKind === 'permission') {
        this._pendingPermissions.set(toolUseId, {
          socket,
          event,
          receivedAt: new Date(),
          sessionId: event.session_id,
        });
      } else if (responseKind === 'interaction') {
        this._pendingInteractions.set(toolUseId, {
          socket,
          event,
          receivedAt: new Date(),
          sessionId: event.session_id,
        });
      }

      // Don't close the socket - keep it open for response
      socket.setTimeout(0); // Clear any timeout

      // Clean up if socket dies
      socket.on('close', () => {
        this._pendingPermissions.delete(toolUseId);
        this._pendingInteractions.delete(toolUseId);
      });

      socket.on('error', () => {
        this._pendingPermissions.delete(toolUseId);
        this._pendingInteractions.delete(toolUseId);
      });
    }

    // Emit the event for session store processing (before destroy so listeners see valid state)
    this.emit('hookEvent', event);

    // Close non-permission connections
    if (!expectsResponse) {
      socket.destroy();
    }
  }

  /**
   * Check if an event expects a response
   */
  _eventExpectsResponse(event) {
    if (event.event === 'PermissionRequest') return true;
    if (event.agent_id === 'claude' && event.event === 'PreToolUse' && event.tool === 'AskUserQuestion') return true;
    if (event.status === 'waiting_for_approval') return true;
    return false;
  }

  /**
   * Get the type of response expected
   */
  _getResponseKind(event) {
    if (event.event === 'PermissionRequest') return 'permission';
    if (event.status === 'waiting_for_approval') return 'permission';
    if (event.event === 'PreToolUse' && event.tool === 'AskUserQuestion') return 'interaction';
    return 'none';
  }

  /**
   * Respond to a pending permission request
   */
  respondToPermission(toolUseId, decision, reason = null) {
    const pending = this._pendingPermissions.get(toolUseId);
    if (!pending) {
      console.warn(`No pending permission for toolUseId: ${toolUseId}`);
      return false;
    }

    this._pendingPermissions.delete(toolUseId);

    const response = { decision, reason };

    try {
      pending.socket.write(JSON.stringify(response));
      pending.socket.end();
      return true;
    } catch (err) {
      console.error('Failed to send permission response:', err);
      try { pending.socket.destroy(); } catch (e) {}
      return false;
    }
  }

  /**
   * Respond to a pending interaction
   */
  respondToInteraction(toolUseId, updatedInput) {
    const pending = this._pendingInteractions.get(toolUseId);
    if (!pending) {
      console.warn(`No pending interaction for toolUseId: ${toolUseId}`);
      return false;
    }

    this._pendingInteractions.delete(toolUseId);

    const response = { decision: null, reason: null, updatedInput };

    try {
      pending.socket.write(JSON.stringify(response));
      pending.socket.end();
      return true;
    } catch (err) {
      console.error('Failed to send interaction response:', err);
      try { pending.socket.destroy(); } catch (e) {}
      return false;
    }
  }

  /**
   * Cancel pending permissions for a session
   */
  cancelPendingPermissions(sessionId) {
    for (const [toolUseId, pending] of this._pendingPermissions) {
      if (pending.sessionId === sessionId) {
        try { pending.socket.destroy(); } catch (e) {}
        this._pendingPermissions.delete(toolUseId);
      }
    }
  }

  /**
   * Cancel a specific pending permission
   */
  cancelPendingPermission(toolUseId) {
    const pending = this._pendingPermissions.get(toolUseId);
    if (pending) {
      try { pending.socket.destroy(); } catch (e) {}
      this._pendingPermissions.delete(toolUseId);
    }
  }

  /**
   * Check if there's a pending permission for a session
   */
  hasPendingPermission(sessionId) {
    for (const pending of this._pendingPermissions.values()) {
      if (pending.sessionId === sessionId) return true;
    }
    return false;
  }
}

module.exports = new HookServer();
