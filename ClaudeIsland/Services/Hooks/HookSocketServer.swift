//
//  HookSocketServer.swift
//  ClaudeIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.claudeisland", category: "Hooks")

enum HookResponseKind: String, Codable, Sendable {
    case none
    case permission
    case interaction
}

/// Event received from AI coding agent hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    let agentId: String
    let rawPayload: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case agentId = "agent_id"
        case rawPayload = "raw_payload"
    }

    /// Create a copy with updated toolUseId
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?, agentId: String, rawPayload: [String: AnyCodable]? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.agentId = agentId
        self.rawPayload = rawPayload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        event = try container.decodeIfPresent(String.self, forKey: .event) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        toolInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId) ?? "claude"
        rawPayload = try container.decodeIfPresent([String: AnyCodable].self, forKey: .rawPayload)
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        if responseKind == .interaction {
            return .waitingForInput
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        if event == "PermissionRequest" {
            return true
        }
        if agentId == "claude" && event == "PreToolUse" && tool == "AskUserQuestion" {
            return true
        }
        if agentId == "codex" && event == "PreToolUse" && status == "waiting_for_approval" {
            return true
        }
        // Keep socket open for Codex request_user_input and Gemini ask_user interactions
        if agentId == "codex" && event == "PreToolUse" && tool == "request_user_input" {
            return true
        }
        if agentId == "gemini" && event == "PreToolUse" && tool == "ask_user" {
            return true
        }
        return false
    }

    nonisolated var responseKind: HookResponseKind {
        if event == "PermissionRequest" {
            return .permission
        }
        if agentId == "claude" && event == "PreToolUse" && tool == "AskUserQuestion" {
            return .interaction
        }
        if agentId == "codex" && event == "PreToolUse" && status == "waiting_for_approval" {
            return .permission
        }
        // Codex request_user_input and Gemini ask_user are user-facing interaction prompts
        if agentId == "codex" && event == "PreToolUse" && tool == "request_user_input" {
            return .interaction
        }
        if agentId == "gemini" && event == "PreToolUse" && tool == "ask_user" {
            return .interaction
        }
        return .none
    }

    nonisolated var expectsPermissionResponse: Bool {
        responseKind == .permission
    }

    nonisolated var expectsInteractionResponse: Bool {
        responseKind == .interaction
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String?
    let reason: String?
    let updatedInput: AnyCodable?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

struct PendingInteraction: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

enum InteractionResponseWriteResult: Equatable, Sendable {
    case success
    case missingPendingInteraction
    case encodingFailed
    case writeFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .success:
            return nil
        case .missingPendingInteraction:
            return "No pending interaction socket matched this tool_use_id"
        case .encodingFailed:
            return "Failed to encode interaction response for hook socket"
        case .writeFailed(let errno):
            return "Failed to write interaction response to hook socket (errno \(errno))"
        }
    }
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/claude-island.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.claudeisland.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Pending interaction requests indexed by toolUseId
    private var pendingInteractions: [String: PendingInteraction] = [:]
    private let interactionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()

        interactionsLock.lock()
        for (_, pending) in pendingInteractions {
            close(pending.clientSocket)
        }
        pendingInteractions.removeAll()
        interactionsLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason)
        }
    }

    func respondToInteraction(toolUseId: String, updatedInput: [String: Any]) async -> InteractionResponseWriteResult {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .missingPendingInteraction)
                    return
                }
                continuation.resume(
                    returning: self.sendInteractionResponse(
                        toolUseId: toolUseId,
                        updatedInput: updatedInput
                    )
                )
            }
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    private func cleanupPendingInteractions(sessionId: String) {
        interactionsLock.lock()
        let matching = pendingInteractions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale interaction for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingInteractions.removeValue(forKey: toolUseId)
        }
        interactionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Peek cached tool_use_id without removing it.
    private func peekCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue[0]
        logger.debug("Peeked cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Remove one cached tool_use_id for the given event key.
    private func consumeCachedToolUseId(event: HookEvent, preferredToolUseId: String? = nil) {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return
        }

        if let preferredToolUseId,
           let index = queue.firstIndex(of: preferredToolUseId) {
            queue.remove(at: index)
        } else {
            queue.removeFirst()
        }

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            return
        }

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
            cleanupPendingInteractions(sessionId: event.sessionId)
        }

        var eventToDispatch = event
        if event.event == "PostToolUse", event.toolUseId == nil,
           let cachedToolUseId = peekCachedToolUseId(event: event) {
            eventToDispatch = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: cachedToolUseId,
                notificationType: event.notificationType,
                message: event.message,
                agentId: event.agentId,
                rawPayload: event.rawPayload
            )
            consumeCachedToolUseId(event: event, preferredToolUseId: cachedToolUseId)
        } else if event.event == "PostToolUse", let eventToolUseId = event.toolUseId {
            consumeCachedToolUseId(event: event, preferredToolUseId: eventToolUseId)
        }

        if eventToDispatch.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = eventToDispatch.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = peekCachedToolUseId(event: eventToDispatch) {
                toolUseId = cachedToolUseId
            } else {
                // Generate a synthetic tool_use_id so we can still track and respond
                let synthetic = "\(eventToDispatch.sessionId)-\(eventToDispatch.tool ?? "unknown")-\(Int(Date().timeIntervalSince1970))"
                logger.warning("Permission request missing tool_use_id for \(eventToDispatch.sessionId.prefix(8), privacy: .public) - using synthetic: \(synthetic.prefix(20), privacy: .public)")
                toolUseId = synthetic
            }

            logger.debug("Permission request - keeping socket open for \(eventToDispatch.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: eventToDispatch.sessionId,
                cwd: eventToDispatch.cwd,
                event: eventToDispatch.event,
                status: eventToDispatch.status,
                pid: eventToDispatch.pid,
                tty: eventToDispatch.tty,
                tool: eventToDispatch.tool,
                toolInput: eventToDispatch.toolInput,
                toolUseId: toolUseId,
                notificationType: eventToDispatch.notificationType,
                message: eventToDispatch.message,
                agentId: eventToDispatch.agentId,
                rawPayload: eventToDispatch.rawPayload
            )

            switch updatedEvent.responseKind {
            case .permission:
                let pending = PendingPermission(
                    sessionId: eventToDispatch.sessionId,
                    toolUseId: toolUseId,
                    clientSocket: clientSocket,
                    event: updatedEvent,
                    receivedAt: Date()
                )
                permissionsLock.lock()
                pendingPermissions[toolUseId] = pending
                permissionsLock.unlock()
            case .interaction:
                let pending = PendingInteraction(
                    sessionId: eventToDispatch.sessionId,
                    toolUseId: toolUseId,
                    clientSocket: clientSocket,
                    event: updatedEvent,
                    receivedAt: Date()
                )
                interactionsLock.lock()
                pendingInteractions[toolUseId] = pending
                interactionsLock.unlock()
                logInteractionDebug(
                    kind: "pending",
                    values: [
                        "sessionId": eventToDispatch.sessionId,
                        "toolUseId": toolUseId,
                        "agentId": eventToDispatch.agentId,
                        "tool": eventToDispatch.tool ?? "",
                        "status": eventToDispatch.status,
                        "rawPayload": eventToDispatch.rawPayload?.mapValues(\.value) ?? [:]
                    ]
                )
            case .none:
                break
            }

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        eventHandler?(eventToDispatch)
    }

    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?) {
        sendHookResponse(
            toolUseId: toolUseId,
            response: HookResponse(decision: decision, reason: reason, updatedInput: nil),
            summary: decision
        )
    }

    private func sendHookResponse(toolUseId: String, response: HookResponse, summary: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(summary, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
    }

    private func sendInteractionResponse(toolUseId: String, updatedInput: [String: Any]) -> InteractionResponseWriteResult {
        interactionsLock.lock()
        guard let pending = pendingInteractions.removeValue(forKey: toolUseId) else {
            interactionsLock.unlock()
            logger.debug("No pending interaction for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            logInteractionDebug(
                kind: "write-miss",
                values: ["toolUseId": toolUseId]
            )
            return .missingPendingInteraction
        }
        interactionsLock.unlock()

        let response = HookResponse(
            decision: nil,
            reason: nil,
            updatedInput: AnyCodable(updatedInput)
        )
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            logInteractionDebug(
                kind: "write-encode-failed",
                values: [
                    "sessionId": pending.sessionId,
                    "toolUseId": toolUseId,
                    "updatedInput": updatedInput
                ]
            )
            return .encodingFailed
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: interaction for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeErrno: Int32?
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                writeErrno = EINVAL
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                writeErrno = errno
                logger.error("Interaction write failed with errno: \(errno)")
            } else {
                logger.debug("Interaction write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)

        if let writeErrno {
            logInteractionDebug(
                kind: "write-failed",
                values: [
                    "sessionId": pending.sessionId,
                    "toolUseId": toolUseId,
                    "errno": Int(writeErrno),
                    "updatedInput": updatedInput
                ]
            )
            return .writeFailed(errno: writeErrno)
        }

        logInteractionDebug(
            kind: "write-succeeded",
            values: [
                "sessionId": pending.sessionId,
                "toolUseId": toolUseId,
                "updatedInput": updatedInput
            ]
        )
        return .success
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason, updatedInput: nil)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }

    private func logInteractionDebug(kind: String, values: [String: Any]) {
        let path = Foundation.ProcessInfo.processInfo.environment["CLAUDE_ISLAND_INTERACTION_LOG_PATH"]
            ?? "/tmp/claude-island-interactions.log"
        var payload = values
        payload["kind"] = kind
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            if let lineData = "\(line)\n".data(using: .utf8) {
                try handle.write(contentsOf: lineData)
            }
        } catch {
            logger.error("Failed to append interaction debug log: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
