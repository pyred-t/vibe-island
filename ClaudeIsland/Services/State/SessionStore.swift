//
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import Mixpanel
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Session")
    nonisolated static let interactionLogPath = "/tmp/claude-island-interactions.log"

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    nonisolated private static func appendInteractionDebug(kind: String, values: [String: Any]) {
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "values": values
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: []),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        if let handle = FileHandle(forWritingAtPath: interactionLogPath) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            FileManager.default.createFile(
                atPath: interactionLogPath,
                contents: Data((line + "\n").utf8)
            )
        }
    }

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .interactionSubmitted(let sessionId, let toolUseId, let result):
            await processInteractionSubmitted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        case .interactionSubmissionPending(let sessionId, let toolUseId):
            await processInteractionSubmissionPending(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break

        // MARK: - Process Detection Events

        case .processDetected(let sessionId, let cwd, let agentId, let pid, let tty):
            await processDetectedSession(sessionId: sessionId, cwd: cwd, agentId: agentId, pid: pid, tty: tty)

        case .processSessionEnded(let sessionId):
            processProcessSessionEnded(sessionId: sessionId)
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        if event.agentId == "codex" {
            Self.logger.debug(
                "Codex hook event normalized: event=\(event.event, privacy: .public) session=\(event.sessionId, privacy: .public) tool=\(event.tool ?? "nil", privacy: .public) toolUseId=\(event.toolUseId ?? "nil", privacy: .public) status=\(event.status, privacy: .public)"
            )
        }

        let sessionId = event.sessionId
        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event)

        // Track new session in Mixpanel
        if isNewSession {
            Mixpanel.mainInstance().track(event: "Session Started")
        }

        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()

        Task { @MainActor in
            AgentRegistry.shared.updatePrimaryAgent(withSessionFrom: event.agentId)
        }

        if event.status == "ended" {
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        if event.expectsPermissionResponse, let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if event.expectsPermissionResponse, let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }
        processNormalizedInteraction(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)

        sessions[sessionId] = session
        publishState()

        if event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd, agentId: event.agentId)
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            agentId: event.agentId,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private func createProcessSession(sessionId: String, cwd: String, agentId: String, pid: Int?, tty: String?) -> SessionState {
        SessionState(
            sessionId: sessionId,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            agentId: agentId,
            pid: pid,
            tty: tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,
            phase: .processing
        )
    }

    // MARK: - Process Detection

    private func processDetectedSession(sessionId: String, cwd: String, agentId: String, pid: Int?, tty: String?) async {
        let isNew = sessions[sessionId] == nil

        if isNew {
            Mixpanel.mainInstance().track(event: "Session Started (\(agentId))")
        }

        var session = sessions[sessionId] ?? createProcessSession(
            sessionId: sessionId,
            cwd: cwd,
            agentId: agentId,
            pid: pid,
            tty: tty
        )

        session.pid = pid
        if let pid = pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()
        session.phase = .processing
        if let conversationInfo = parseConversationInfo(agentId: agentId, sessionId: sessionId, cwd: cwd) {
            session.conversationInfo = conversationInfo
        }
        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)

        sessions[sessionId] = session
        publishState()

        // Update primary agent
        Task { @MainActor in
            AgentRegistry.shared.updatePrimaryAgent(withSessionFrom: agentId)
        }
    }

    private func parseConversationInfo(agentId: String, sessionId: String, cwd: String) -> ConversationInfo? {
        switch agentId {
        case "codex":
            return CodexAgent().parseConversation(sessionId: sessionId, cwd: cwd)
        case "gemini":
            return GeminiCLIAgent().parseConversation(sessionId: sessionId, cwd: cwd)
        case "claude":
            return ClaudeCodeAgent().parseConversation(sessionId: sessionId, cwd: cwd)
        default:
            return nil
        }
    }

    private func refreshInteractionState(for session: inout SessionState) {
        let submitMode = SessionInteractionRequest.submitMode(isInTmux: session.isInTmux, tty: session.tty)

        if let activePermission = session.activePermission,
           let interaction = SessionInteractionRequest.from(
                permission: activePermission,
                sessionId: session.sessionId,
                agentId: session.agentId,
                submitMode: submitMode
           ) {
            session.activeInteraction = interaction
            session.pendingInteractionCount = 1
            Self.appendInteractionDebug(
                kind: "interaction_source",
                values: [
                    "sessionId": session.sessionId,
                    "source": interaction.origin.rawValue,
                    "toolUseId": interaction.toolUseId ?? "",
                    "transportPreference": String(describing: interaction.transportPreference)
                ]
            )
            return
        }

        if let normalizedInteraction = session.normalizedInteraction {
            session.activeInteraction = normalizedInteraction
            session.pendingInteractionCount = 1
            Self.appendInteractionDebug(
                kind: "interaction_source",
                values: [
                    "sessionId": session.sessionId,
                    "source": normalizedInteraction.origin.rawValue,
                    "toolUseId": normalizedInteraction.toolUseId ?? "",
                    "transportPreference": String(describing: normalizedInteraction.transportPreference)
                ]
            )
            return
        }

        switch session.agentId {
        case "codex":
            session.activeInteraction = CodexAgent().parseInteraction(
                sessionId: session.sessionId,
                cwd: session.cwd,
                isInTmux: session.isInTmux,
                tty: session.tty
            )
        case "gemini":
            session.activeInteraction = GeminiCLIAgent().parseInteraction(
                sessionId: session.sessionId,
                cwd: session.cwd,
                isInTmux: session.isInTmux,
                tty: session.tty
            )
        default:
            session.activeInteraction = nil
        }

        if session.activeInteraction == nil,
           ["codex", "gemini"].contains(session.agentId) {
            let accessibilityText = AccessibilityOptionExtractor.shared.extractVisibleText(for: session)
            session.activeInteraction = SessionInteractionRequest.fromAccessibilityEnrichedHook(
                accessibilityText: accessibilityText,
                hookMessage: session.conversationInfo.lastMessage,
                sessionId: session.sessionId,
                interactionId: "ax-\(session.sessionId)",
                sourceAgent: session.agentId,
                timestamp: session.lastActivity,
                submitMode: submitMode
            )
        }

        if let activeToolUseId = session.activeInteraction?.toolUseId,
           (session.dismissedInteractionToolUseIds.contains(activeToolUseId)
            || session.pendingSubmittedInteractionToolUseIds.contains(activeToolUseId)) {
            session.activeInteraction = nil
        }

        session.pendingInteractionCount = session.activeInteraction == nil ? 0 : 1
        if let activeInteraction = session.activeInteraction {
            Self.appendInteractionDebug(
                kind: "interaction_source",
                values: [
                    "sessionId": session.sessionId,
                    "source": activeInteraction.origin.rawValue,
                    "toolUseId": activeInteraction.toolUseId ?? "",
                    "transportPreference": String(describing: activeInteraction.transportPreference)
                ]
            )
        } else {
            Self.appendInteractionDebug(
                kind: "interaction_source",
                values: [
                    "sessionId": session.sessionId,
                    "source": "none"
                ]
            )
        }
    }

    private func syncLiveInteractionHistory(for session: inout SessionState) {
        let syntheticPrefix = "live-interaction-\(session.sessionId)-"
        let activeSyntheticIds = Set(session.activeInteraction.map { ["\(syntheticPrefix)\($0.id)"] } ?? [])

        session.chatItems.removeAll { item in
            item.id.hasPrefix(syntheticPrefix) && !activeSyntheticIds.contains(item.id)
        }

        guard let interaction = session.activeInteraction else { return }

        let detailItemId = "\(syntheticPrefix)\(interaction.id)"
        let detailItem = ChatHistoryItem(
            id: detailItemId,
            type: .assistant(formattedInteractionSummary(interaction)),
            timestamp: interaction.createdAt
        )

        if let idx = session.chatItems.firstIndex(where: { $0.id == detailItemId }) {
            session.chatItems[idx] = detailItem
        } else {
            session.chatItems.append(detailItem)
        }

        guard let toolUseId = interaction.toolUseId else {
            session.chatItems.sort { $0.timestamp < $1.timestamp }
            return
        }

        let enrichedInput = enrichedInteractionInput(for: interaction)
        if let idx = session.chatItems.firstIndex(where: { $0.id == toolUseId }),
           case .toolCall(var tool) = session.chatItems[idx].type {
            let mergedInput = tool.input.merging(enrichedInput) { _, new in new }
            session.chatItems[idx] = ChatHistoryItem(
                id: toolUseId,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: mergedInput,
                    status: tool.status,
                    result: tool.result,
                    structuredResult: tool.structuredResult,
                    subagentTools: tool.subagentTools
                )),
                timestamp: session.chatItems[idx].timestamp
            )
        } else {
            let toolName = session.activePermission?.toolName
                ?? (interaction.sourceAgent == "codex" ? "request_user_input" : "Interaction")
            let status: ToolStatus = session.activePermission?.toolUseId == toolUseId ? .waitingForApproval : .running
            session.chatItems.append(
                ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(ToolCallItem(
                        name: toolName,
                        input: enrichedInput,
                        status: status,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: interaction.createdAt
                )
            )
        }

        session.chatItems.sort { $0.timestamp < $1.timestamp }
    }

    private func formattedInteractionSummary(_ interaction: SessionInteractionRequest) -> String {
        var lines: [String] = []
        lines.append(interaction.title)

        for question in interaction.questions {
            if let header = question.header, !header.isEmpty, header != interaction.title {
                lines.append(header)
            }
            lines.append(question.question)
            for (index, option) in question.options.enumerated() {
                if let detail = option.detail, !detail.isEmpty {
                    lines.append("\(index + 1). \(option.label) - \(detail)")
                } else {
                    lines.append("\(index + 1). \(option.label)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func enrichedInteractionInput(for interaction: SessionInteractionRequest) -> [String: String] {
        var input: [String: String] = [:]
        input["interaction_title"] = interaction.title
        input["interaction_question"] = interaction.question
        input["interaction_options"] = interaction.options.enumerated().map { index, option in
            if let detail = option.detail, !detail.isEmpty {
                return "\(index + 1). \(option.label) - \(detail)"
            }
            return "\(index + 1). \(option.label)"
        }.joined(separator: "\n")
        if let sourceToolInputJSON = interaction.sourceToolInputJSON {
            input["source_tool_input_json"] = sourceToolInputJSON
        }
        input["interaction_origin"] = interaction.origin.rawValue
        return input
    }

    private func processNormalizedInteraction(event: HookEvent, session: inout SessionState) {
        if event.agentId == "codex" {
            switch event.event {
            case HookEventType.preToolUse.rawValue:
                guard event.tool == "request_user_input",
                      let toolUseId = event.toolUseId else {
                    return
                }

                let submitMode = SessionInteractionRequest.submitMode(
                    isInTmux: session.isInTmux,
                    tty: session.tty
                )
                // Use programmaticOnly so response goes back through hook socket
                session.normalizedInteraction = SessionInteractionRequest.fromToolInputPayload(
                    sessionId: session.sessionId,
                    toolUseId: toolUseId,
                    payload: event.toolInput ?? [:],
                    timestamp: Date(),
                    sourceAgent: event.agentId,
                    submitMode: .programmatic,
                    transportPreference: .programmaticOnly
                )
                let codexSessionId = session.sessionId
                let hasInteraction = session.normalizedInteraction != nil
                Self.logger.debug(
                    "Codex interaction mapped from hook payload: session=\(codexSessionId, privacy: .public) toolUseId=\(toolUseId, privacy: .public) hasInteraction=\(hasInteraction, privacy: .public)"
                )
                Self.appendInteractionDebug(
                    kind: "normalized_interaction_created",
                    values: [
                        "sessionId": codexSessionId,
                        "toolUseId": toolUseId,
                        "hasInteraction": hasInteraction,
                        "tool": event.tool ?? "",
                        "toolInput": event.toolInput?.mapValues(\.value) ?? [:]
                    ]
                )

            case HookEventType.postToolUse.rawValue:
                guard let toolUseId = event.toolUseId else { return }
                if session.normalizedInteraction?.toolUseId == toolUseId {
                    session.normalizedInteraction = nil
                }

            case HookEventType.stop.rawValue:
                session.normalizedInteraction = nil

            default:
                break
            }
            return
        }

        if event.agentId == "claude" {
            switch event.event {
            case HookEventType.preToolUse.rawValue:
                guard event.tool == "AskUserQuestion",
                      let toolUseId = event.toolUseId else {
                    return
                }

                session.normalizedInteraction = SessionInteractionRequest.fromClaudeAskUserQuestion(
                    sessionId: session.sessionId,
                    toolUseId: toolUseId,
                    payload: event.toolInput ?? [:],
                    timestamp: Date(),
                    sourceAgent: event.agentId,
                    submitMode: .programmatic
                )
            case HookEventType.postToolUse.rawValue:
                guard let toolUseId = event.toolUseId else { return }
                if session.normalizedInteraction?.toolUseId == toolUseId {
                    session.normalizedInteraction = nil
                }
            case HookEventType.stop.rawValue:
                session.normalizedInteraction = nil
            default:
                break
            }
            return
        }

        if event.agentId == "gemini" {
            switch event.event {
            case HookEventType.preToolUse.rawValue:
                guard event.tool == "ask_user",
                      let toolUseId = event.toolUseId else {
                    return
                }

                // Use programmaticOnly so response goes back through hook socket
                let payload = (event.toolInput ?? [:]).reduce(into: [String: Any]()) { partialResult, item in
                    partialResult[item.key] = item.value.value
                }
                session.normalizedInteraction = SessionInteractionRequest.fromJSONObjectPayload(
                    sessionId: session.sessionId,
                    toolUseId: toolUseId,
                    payload: payload,
                    timestamp: Date(),
                    sourceAgent: event.agentId,
                    submitMode: .programmatic,
                    transportPreference: .programmaticOnly
                )

            case HookEventType.postToolUse.rawValue, HookEventType.interactionResolved.rawValue:
                guard let toolUseId = event.toolUseId else { return }
                if session.normalizedInteraction?.toolUseId == toolUseId {
                    session.normalizedInteraction = nil
                }

            case HookEventType.stop.rawValue:
                session.normalizedInteraction = nil

            default:
                break
            }
            return
        }

        switch event.event {
        case HookEventType.interactionRequest.rawValue:
            let submitMode = SessionInteractionRequest.submitMode(isInTmux: session.isInTmux, tty: session.tty)
            session.normalizedInteraction = buildNormalizedInteraction(
                from: event,
                sessionId: session.sessionId,
                submitMode: submitMode
            )

        case HookEventType.interactionResolved.rawValue:
            let resolvedId = event.toolUseId
            if resolvedId == nil || session.normalizedInteraction?.toolUseId == resolvedId {
                session.normalizedInteraction = nil
            }

        default:
            break
        }
    }

    private func buildNormalizedInteraction(
        from event: HookEvent,
        sessionId: String,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        let createdAt = Date()
        let interactionId = event.toolUseId ?? "\(sessionId)-interaction"

        if let toolInput = event.toolInput {
            return SessionInteractionRequest.fromToolInputPayload(
                sessionId: sessionId,
                toolUseId: interactionId,
                payload: toolInput,
                timestamp: createdAt,
                sourceAgent: event.agentId,
                submitMode: submitMode
            )
        }

        if let message = event.message {
            return SessionInteractionRequest.fromHeuristicText(
                sessionId: sessionId,
                interactionId: interactionId,
                sourceAgent: event.agentId,
                text: message,
                timestamp: createdAt,
                submitMode: submitMode
            )
        }

        return nil
    }

    private func processProcessSessionEnded(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        publishState()
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let rawToolName = event.tool {
                let toolName = ExternalAgentToolSupport.normalizeToolName(agentId: event.agentId, rawName: rawToolName)
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    let input = ExternalAgentToolSupport.normalizeToolInput(
                        agentId: event.agentId,
                        rawName: rawToolName,
                        input: serializeToolInput(event.toolInput)
                    )

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if event.tool == "Task", let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if event.tool == "Task" {
                Self.logger.debug("PostToolUse for Task received (subagent still running)")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    private func processInteractionSubmitted(sessionId: String, toolUseId: String?, result: ToolCompletionResult?) async {
        guard var session = sessions[sessionId] else { return }

        if let toolUseId {
            session.pendingSubmittedInteractionToolUseIds.remove(toolUseId)
        }

        if let toolUseId,
           let result {
            session.dismissedInteractionToolUseIds.insert(toolUseId)
            for i in 0..<session.chatItems.count {
                guard session.chatItems[i].id == toolUseId,
                      case .toolCall(var tool) = session.chatItems[i].type else {
                    continue
                }

                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                tool.resolvedFromToolUseId = toolUseId
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                break
            }
        }

        if toolUseId == nil || session.normalizedInteraction?.toolUseId == toolUseId {
            session.normalizedInteraction = nil
        }

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)

        if session.activePermission == nil,
           session.activeInteraction == nil,
           session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }

        sessions[sessionId] = session
    }

    private func processInteractionSubmissionPending(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        session.pendingSubmittedInteractionToolUseIds.insert(toolUseId)
        Self.appendInteractionDebug(
            kind: "interaction_submission_pending",
            values: [
                "sessionId": sessionId,
                "toolUseId": toolUseId
            ]
        )

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)
        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }
        session.dismissedInteractionToolUseIds.remove(toolUseId)
        session.pendingSubmittedInteractionToolUseIds.remove(toolUseId)

        // Skip only exact duplicates; allow authoritative file/history results to refine optimistic state.
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type {
            let isCompleted = tool.status == .success || tool.status == .error || tool.status == .interrupted
            if isCompleted,
               tool.status == result.status,
               tool.result == result.result,
               tool.structuredResult == result.structuredResult {
                return
            }
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)
        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)
        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)
        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        session.conversationInfo = payload.conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            var existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: existingTool.input.merging(tool.input) { current, new in
                                            new.isEmpty ? current : new
                                        },
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                        existingIds.insert(item.id)
                    }
                }
            }
        } else {
            var existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: existingTool.input.merging(tool.input) { current, new in
                                            new.isEmpty ? current : new
                                        },
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                        existingIds.insert(item.id)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            let needsUpdate =
                tool.status == .running ||
                tool.status == .waitingForApproval ||
                tool.status != result.status ||
                tool.result != result.result ||
                tool.structuredResult != result.structuredResult
            guard needsUpdate else { continue }

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func serializeToolInput(_ hookInput: [String: AnyCodable]?) -> [String: String] {
        var input: [String: String] = [:]
        guard let hookInput else { return input }

        for (key, value) in hookInput {
            if let str = value.value as? String {
                input[key] = str
            } else if let num = value.value as? Int {
                input[key] = String(num)
            } else if let num = value.value as? Double {
                input[key] = String(num)
            } else if let bool = value.value as? Bool {
                input[key] = bool ? "true" : "false"
            } else if JSONSerialization.isValidJSONObject(value.value),
                      let data = try? JSONSerialization.data(withJSONObject: value.value, options: [.fragmentsAllowed]),
                      let json = String(data: data, encoding: .utf8) {
                input[key] = json
            }
        }

        if let cmd = input["cmd"], input["command"] == nil {
            input["command"] = cmd
        }
        if let workdir = input["workdir"], input["cwd"] == nil {
            input["cwd"] = workdir
        }
        if let path = input["path"], input["file_path"] == nil {
            input["file_path"] = path
        }

        return input
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        refreshInteractionState(for: &session)
        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        refreshInteractionState(for: &session)
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        if let session = sessions[sessionId] {
            switch session.agentId {
            case "codex":
                let history = CodexAgent().parseHistory(sessionId: sessionId, cwd: cwd)
                await process(.historyLoaded(
                    sessionId: sessionId,
                    messages: history.messages,
                    completedTools: history.completedToolIds,
                    toolResults: history.toolResults,
                    structuredResults: history.structuredResults,
                    conversationInfo: history.conversationInfo
                ))
                return
            case "gemini":
                let history = GeminiCLIAgent().parseHistory(sessionId: sessionId, cwd: cwd)
                await process(.historyLoaded(
                    sessionId: sessionId,
                    messages: history.messages,
                    completedTools: history.completedToolIds,
                    toolResults: history.toolResults,
                    structuredResults: history.structuredResults,
                    conversationInfo: history.conversationInfo
                ))
                return
            default:
                break
            }
        }

        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        var existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                    existingIds.insert(item.id)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }
        refreshInteractionState(for: &session)
        syncLiveInteractionHistory(for: &session)

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String, agentId: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            switch agentId {
            case "codex":
                let history = CodexAgent().parseHistory(sessionId: sessionId, cwd: cwd)
                guard !history.messages.isEmpty || !history.completedToolIds.isEmpty else { return }
                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: history.messages,
                    isIncremental: false,
                    completedToolIds: history.completedToolIds,
                    toolResults: history.toolResults,
                    structuredResults: history.structuredResults,
                    conversationInfo: history.conversationInfo
                )
                await self?.process(.fileUpdated(payload))

            case "gemini":
                let history = GeminiCLIAgent().parseHistory(sessionId: sessionId, cwd: cwd)
                guard !history.messages.isEmpty || !history.completedToolIds.isEmpty else { return }
                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: history.messages,
                    isIncremental: false,
                    completedToolIds: history.completedToolIds,
                    toolResults: history.toolResults,
                    structuredResults: history.structuredResults,
                    conversationInfo: history.conversationInfo
                )
                await self?.process(.fileUpdated(payload))

            default:
                let result = await ConversationParser.shared.parseIncremental(
                    sessionId: sessionId,
                    cwd: cwd
                )

                if result.clearDetected {
                    await self?.process(.clearDetected(sessionId: sessionId))
                }

                guard !result.newMessages.isEmpty || result.clearDetected else {
                    return
                }

                let conversationInfo = await ConversationParser.shared.parse(
                    sessionId: sessionId,
                    cwd: cwd
                )

                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: result.newMessages,
                    isIncremental: !result.clearDetected,
                    completedToolIds: result.completedToolIds,
                    toolResults: result.toolResults,
                    structuredResults: result.structuredResults,
                    conversationInfo: conversationInfo
                )

                await self?.process(.fileUpdated(payload))
            }
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
