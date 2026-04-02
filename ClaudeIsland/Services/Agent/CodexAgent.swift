//
//  CodexAgent.swift
//  ClaudeIsland
//
//  OpenAI Codex CLI integration for Vibe Island.
//  Primary live semantics: native hooks via ~/.codex/hooks.json.
//  Rollout parsing remains a history / cold-restore fallback.
//

import Foundation

/// OpenAI Codex CLI agent implementation.
struct CodexAgent: AIAgent {
    let id: String = "codex"
    let name: String = "OpenAI Codex"
    let priority: Int = 1  // P0 - highest after Claude
    let socketPath: String = "/tmp/claude-island.sock"

    // Codex CLI stores session data in ~/.codex.
    let sessionFilesDirectory: String = "~/.codex"
    let hookSettingsPath: String = "~/.codex/hooks.json"
    let hookScriptInstallName: String? = "vibe-island-codex.py"
    let hookCommandPath: String? = "\(HookPythonLocator.detectPython()) ~/.codex/hooks/vibe-island-codex.py"

    let supportedEvents: Set<HookEventType> = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop
    ]

    let supportsHooks: Bool = true
    let eventSourceMode: AgentEventSourceMode = .hook

    let processNames: [String] = ["codex", "Codex", "codex-code", "openai-codex"]

    // MARK: - Conversation Parsing

    func parseConversation(sessionId: String, cwd: String) -> ConversationInfo? {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd) else { return nil }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: conversation.rolloutPath),
              let data = fileManager.contents(atPath: conversation.rolloutPath),
              let content = String(data: data, encoding: .utf8) else {
            return ConversationInfo(
                summary: conversation.title,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: conversation.title,
                lastUserMessage: nil,
                lastUserMessageDate: conversation.updatedAt
            )
        }

        return parseRolloutContent(content, fallbackTitle: conversation.title, fallbackDate: conversation.updatedAt)
    }

    func parseInteraction(
        sessionId: String,
        cwd: String,
        isInTmux: Bool,
        tty: String?
    ) -> SessionInteractionRequest? {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd),
              let data = FileManager.default.contents(atPath: conversation.rolloutPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parseLatestInteraction(
            content,
            sessionId: conversation.sessionId,
            submitMode: SessionInteractionRequest.submitMode(isInTmux: isInTmux, tty: tty)
        )
    }

    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        parseHistory(sessionId: sessionId, cwd: cwd).messages
    }

    func parseHistory(sessionId: String, cwd: String) -> AgentHistorySnapshot {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd),
              let data = FileManager.default.contents(atPath: conversation.rolloutPath),
              let content = String(data: data, encoding: .utf8) else {
            return AgentHistorySnapshot(
                messages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: nil,
                    lastUserMessage: nil,
                    lastUserMessageDate: nil
                )
            )
        }

        let entries = content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var messages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var structuredResults: [String: ToolResultData] = [:]
        var toolInputsById: [String: [String: String]] = [:]
        var rawToolNamesById: [String: String] = [:]

        for (index, json) in entries.enumerated() {
            guard let type = json["type"] as? String else {
                continue
            }

            let timestamp = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? conversation.updatedAt

            if shouldSkipVisibleMessage(at: index, in: entries) {
                continue
            }

            if let message = parseVisibleMessage(from: json),
               !message.text.isEmpty {
                messages.append(
                    ChatMessage(
                        id: "codex-\(index)",
                        role: message.role,
                        timestamp: timestamp,
                        content: [.text(message.text)]
                    )
                )
                continue
            }

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "function_call",
               let rawToolName = payload["name"] as? String,
               let callId = payload["call_id"] as? String {
                let parsedInput = parseToolInput(from: payload["arguments"])
                let toolInput = ExternalAgentToolSupport.normalizeToolInput(
                    agentId: id,
                    rawName: rawToolName,
                    input: parsedInput
                )
                let toolName = ExternalAgentToolSupport.normalizeToolName(agentId: id, rawName: rawToolName)
                toolInputsById[callId] = toolInput
                rawToolNamesById[callId] = rawToolName
                messages.append(
                    ChatMessage(
                        id: "codex-tool-\(index)",
                        role: .assistant,
                        timestamp: timestamp,
                        content: [
                            .toolUse(
                                ToolUseBlock(
                                    id: callId,
                                    name: toolName,
                                    input: toolInput
                                )
                            )
                        ]
                    )
                )
                continue
            }

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "function_call_output",
               let callId = payload["call_id"] as? String {
                completedToolIds.insert(callId)
                let rawToolName = rawToolNamesById[callId] ?? toolInputsById[callId]?["tool_name"] ?? "unknown"
                let parsed = ExternalAgentToolSupport.parseResult(
                    agentId: id,
                    rawToolName: rawToolName,
                    toolInput: toolInputsById[callId] ?? [:],
                    rawOutput: payload["output"] as? String,
                    rawPayload: payload
                )
                if let parserResult = parsed.parserResult {
                    toolResults[callId] = parserResult
                }
                if let structuredResult = parsed.structuredResult {
                    structuredResults[callId] = structuredResult
                }
                continue
            }
        }

        return AgentHistorySnapshot(
            messages: messages,
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: parseRolloutContent(content, fallbackTitle: conversation.title, fallbackDate: conversation.updatedAt)
        )
    }

    func resolveCurrentConversation(cwd: String) -> ResolvedCodexConversation? {
        resolveConversation(sessionId: nil, cwd: cwd)
    }

    func resolveSessionId(cwd: String) -> String? {
        resolveCurrentConversation(cwd: cwd)?.sessionId
    }

    func resolveConversation(sessionId: String?, cwd: String) -> ResolvedCodexConversation? {
        if let threadId = sessionId.flatMap(Self.threadId(fromSessionId:)) {
            return queryConversation(whereClause: "id = '\(escapeSQL(threadId))'")
        }

        if !cwd.isEmpty, cwd != "/" {
            let escapedCwd = escapeSQL(cwd)
            if let conversation = queryConversation(
                whereClause: "cwd = '\(escapedCwd)' and archived = 0",
                orderBy: "updated_at desc"
            ) {
                return conversation
            }
        }

        return queryConversation(
            whereClause: "archived = 0",
            orderBy: "updated_at desc"
        )
    }

    private func queryConversation(
        whereClause: String,
        orderBy: String = "updated_at desc"
    ) -> ResolvedCodexConversation? {
        let expandedDbPath = NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
        let query = """
        select id, rollout_path, title, updated_at, source
        from threads
        where \(whereClause)
        order by \(orderBy)
        limit 1;
        """

        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/usr/bin/sqlite3",
            arguments: [expandedDbPath, query]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: "|")
        guard parts.count >= 5,
              let updatedAtEpoch = TimeInterval(parts[3]) else {
            return nil
        }

        return ResolvedCodexConversation(
            sessionId: "codex-thread-\(parts[0])",
            rolloutPath: parts[1],
            title: parts[2],
            updatedAt: Date(timeIntervalSince1970: updatedAtEpoch),
            source: parts[4]
        )
    }

    private func escapeSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func threadId(fromSessionId sessionId: String) -> String? {
        guard sessionId.hasPrefix("codex-thread-") else { return nil }
        return String(sessionId.dropFirst("codex-thread-".count))
    }

    private func parseRolloutContent(
        _ content: String,
        fallbackTitle: String,
        fallbackDate: Date
    ) -> ConversationInfo {
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessage: String?
        var lastUserMessageDate: Date?

        let entries = content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for (index, json) in entries.enumerated() {
            guard json["type"] as? String != nil else {
                continue
            }

            if shouldSkipVisibleMessage(at: index, in: entries) {
                continue
            }

            if let message = parseVisibleMessage(from: json) {
                if message.role == .user {
                    if firstUserMessage == nil {
                        firstUserMessage = Self.truncate(message.text, maxLength: 50)
                    }
                    lastUserMessage = Self.truncate(message.text, maxLength: 80)
                    if let timestampStr = json["timestamp"] as? String {
                        lastUserMessageDate = formatter.date(from: timestampStr)
                    }
                }

                lastMessage = Self.truncate(message.text, maxLength: 80)
                lastMessageRole = message.role == .user ? "user" : "assistant"
                continue
            }
        }

        return ConversationInfo(
            summary: fallbackTitle,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage ?? fallbackTitle,
            lastUserMessage: lastUserMessage,
            lastUserMessageDate: lastUserMessageDate ?? fallbackDate
        )
    }

    func parseLatestInteraction(
        _ content: String,
        sessionId: String,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var resolvedCallIds = Set<String>()

        for (index, line) in lines.enumerated().reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any] else {
                continue
            }

            let timestamp = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? Date()

            if type == "response_item",
               payload["type"] as? String == "function_call_output",
               let callId = payload["call_id"] as? String {
                resolvedCallIds.insert(callId)
                continue
            }

            if type == "response_item",
               payload["type"] as? String == "function_call",
               let name = payload["name"] as? String,
               name == "request_user_input",
               let callId = payload["call_id"] as? String,
               !resolvedCallIds.contains(callId),
               let arguments = payload["arguments"] as? String,
               let interaction = SessionInteractionRequest.fromCodexRequestUserInput(
                    sessionId: sessionId,
                    callId: callId,
                    arguments: arguments,
                    timestamp: timestamp,
                    sourceAgent: id,
                    submitMode: submitMode
               ) {
                return interaction
            }

            if type == "response_item",
               payload["type"] as? String == "function_call",
               let name = payload["name"] as? String,
               let callId = payload["call_id"] as? String,
               !resolvedCallIds.contains(callId),
               let arguments = payload["arguments"] as? String,
               let jsonArguments = ExternalAgentToolSupport.decodeJSONObject(arguments),
               jsonArguments["sandbox_permissions"] as? String == "require_escalated"
                || jsonArguments["justification"] != nil {
                let question = jsonArguments["justification"] as? String ?? "Allow \(name) to run?"
                let command = jsonArguments["cmd"] as? String ?? jsonArguments["command"] as? String
                let prompt = [question, command.map { "$ \($0)" }].compactMap { $0 }.joined(separator: "\n")
                if let interaction = SessionInteractionRequest.fromHeuristicText(
                    sessionId: sessionId,
                    interactionId: callId,
                    sourceAgent: "codex",
                    text: "Would you like to run the following command?\n\(prompt)",
                    timestamp: timestamp,
                    submitMode: submitMode
                ) {
                    return interaction
                }
            }

            if type == "event_msg",
               payload["type"] as? String == "agent_message",
               let message = payload["message"] as? String,
               message.count < 400,
               let interaction = SessionInteractionRequest.fromHeuristicText(
                    sessionId: sessionId,
                    interactionId: "codex-agent-message-\(index)",
                    sourceAgent: "codex",
                    text: message,
                    timestamp: timestamp,
                    submitMode: submitMode
               ) {
                return interaction
            }

            if type == "response_item",
               payload["type"] as? String == "message",
               let role = payload["role"] as? String,
               role == "assistant",
               let messageText = extractMessageText(from: payload["content"]),
               messageText.count < 400,
               let interaction = SessionInteractionRequest.fromHeuristicText(
                    sessionId: sessionId,
                    interactionId: "codex-message-\(index)",
                    sourceAgent: "codex",
                    text: messageText,
                    timestamp: timestamp,
                    submitMode: submitMode
               ) {
                return interaction
            }
        }

        return nil
    }

    private func shouldSkipVisibleMessage(at index: Int, in entries: [[String: Any]]) -> Bool {
        guard index + 1 < entries.count,
              isAgentMessage(entries[index]),
              let currentText = parseVisibleMessage(from: entries[index])?.text,
              let nextText = assistantResponseText(from: entries[index + 1]) else {
            return false
        }

        return isEquivalentMessageText(currentText, nextText)
    }

    private func isAgentMessage(_ json: [String: Any]) -> Bool {
        guard let type = json["type"] as? String,
              type == "event_msg",
              let payload = json["payload"] as? [String: Any] else {
            return false
        }
        return payload["type"] as? String == "agent_message"
    }

    private func assistantResponseText(from json: [String: Any]) -> String? {
        guard let type = json["type"] as? String,
              type == "response_item",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "assistant" else {
            return nil
        }
        return extractMessageText(from: payload["content"])
    }

    private func isEquivalentMessageText(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private func parseVisibleMessage(from json: [String: Any]) -> (role: ChatRole, text: String)? {
        guard let type = json["type"] as? String else { return nil }

        if type == "response_item",
           let payload = json["payload"] as? [String: Any],
           payload["type"] as? String == "message",
           let role = payload["role"] as? String,
           let messageText = extractMessageText(from: payload["content"]),
           !messageText.isEmpty {
            return (role == "user" ? .user : .assistant, messageText)
        }

        if type == "event_msg",
           let payload = json["payload"] as? [String: Any],
           payload["type"] as? String == "agent_message",
           let messageText = extractPlainText(payload["message"]),
           !messageText.isEmpty {
            return (.assistant, messageText)
        }

        return nil
    }

    private func extractMessageText(from rawContent: Any?) -> String? {
        if let text = extractPlainText(rawContent) {
            return text
        }

        if let parts = rawContent as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                guard let type = part["type"] as? String else { return nil }
                switch type {
                case "input_text", "output_text", "text":
                    return extractPlainText(part["text"])
                default:
                    return nil
                }
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func extractPlainText(_ rawValue: Any?) -> String? {
        guard let text = rawValue as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseToolInput(from rawArguments: Any?) -> [String: String] {
        if let arguments = rawArguments as? String,
           let data = arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return serializeToolInput(json)
        }

        if let json = rawArguments as? [String: Any] {
            return serializeToolInput(json)
        }

        if let text = rawArguments as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [:] : ["input": trimmed]
        }

        return [:]
    }

    private func serializeToolInput(_ payload: [String: Any]) -> [String: String] {
        payload.reduce(into: [String: String]()) { result, entry in
            if let stringValue = stringify(entry.value) {
                result[entry.key] = stringValue
            }
        }
    }

    private func stringify(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let intValue = value as? Int {
            return String(intValue)
        }
        if let doubleValue = value as? Double {
            return String(doubleValue)
        }
        if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return nil
    }

    private static func truncate(_ text: String?, maxLength: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength)) : text
    }

    // MARK: - Hook Script

    func hookScriptResourceName() -> String { "codex-island-hook" }

    func hookConfig() -> [[String: Any]] {
        CodexHookConfig.hookConfig(commandPath: hookCommandPath ?? "")
    }

    func postInstallHooks() throws {
        try CodexHookConfig.ensureCodexHooksFeatureEnabled()
    }

    func postUninstallHooks() throws {}

    // MARK: - Process-Based Session Detection

    /// Whether a detected Codex process is the CLI binary or the App bundle.
    enum CodexVariant: String, Sendable {
        case cli      // ~/.codex/bin/codex or homebrew install
        case app      // /Applications/Codex.app bundle
        case unknown
    }

    /// Detect running Codex sessions via process tree analysis
    /// Returns array of (pid, cwd, sessionId, variant) tuples
    func detectRunningSessions() -> [(pid: Int, cwd: String, sessionId: String, variant: CodexVariant)] {
        var results: [(pid: Int, cwd: String, sessionId: String, variant: CodexVariant)] = []
        var seenSessionIds = Set<String>()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid,comm,wchan"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return results }

            let lines = output.components(separatedBy: .newlines)

            for line in lines {
                let components = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }

                guard components.count >= 2 else { continue }

                let comm = components[1]
                guard let pid = Int(components[0]) else { continue }

                let executablePath = ProcessTreeBuilder.shared.getExecutablePath(forPid: pid)
                guard Self.looksLikeCodexProcess(command: comm, executablePath: executablePath) else {
                    continue
                }

                let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid) ?? ""
                let sessionId = resolveSessionId(cwd: cwd) ?? "codex-pid-\(pid)"
                guard seenSessionIds.insert(sessionId).inserted else { continue }

                let variant = Self.detectCodexVariant(pid: pid, command: comm, executablePath: executablePath)
                results.append((
                    pid: pid,
                    cwd: cwd,
                    sessionId: sessionId,
                    variant: variant
                ))
            }
        } catch {
            // Silently fail
        }

        return results
    }

    /// Determine whether a Codex process is the CLI binary or the desktop App.
    private static func detectCodexVariant(pid _: Int, command: String, executablePath: String?) -> CodexVariant {
        if let path = executablePath {
            if path.contains("/Codex.app/") {
                return .app
            }
            if path.contains("/.codex/") || path.contains("/bin/codex") {
                return .cli
            }
        }
        // Heuristic: capitalized "Codex" is typically the App
        return command.first?.isUppercase == true ? .app : .unknown
    }

    private static func looksLikeCodexProcess(command: String, executablePath: String?) -> Bool {
        let loweredCommand = command.lowercased()
        if ["codex", "_codex", "openai-codex"].contains(loweredCommand) {
            return true
        }

        guard let executablePath else { return false }
        let loweredPath = executablePath.lowercased()
        return loweredPath.contains("/codex.app/")
            || loweredPath.contains("/.codex/")
            || loweredPath.hasSuffix("/bin/codex")
    }
}


struct ResolvedCodexConversation: Sendable {
    let sessionId: String
    let rolloutPath: String
    let title: String
    let updatedAt: Date
    let source: String
}

enum CodexHookConfig {
    private static let configPath = NSString(string: "~/.codex/config.toml").expandingTildeInPath

    static func hookConfig(commandPath: String) -> [[String: Any]] {
        let standardHook: [[String: Any]] = [[
            "hooks": [[
                "type": "command",
                "command": commandPath,
                "timeout": 5
            ]]
        ]]
        let preToolHook: [[String: Any]] = [[
            "hooks": [[
                "type": "command",
                "command": commandPath,
                "timeout": 86400
            ]]
        ]]

        return [
            ["event": "SessionStart", "config": standardHook],
            ["event": "UserPromptSubmit", "config": standardHook],
            ["event": "PreToolUse", "config": preToolHook],
            ["event": "PostToolUse", "config": standardHook],
            ["event": "Stop", "config": standardHook]
        ]
    }

    static func ensureCodexHooksFeatureEnabled() throws {
        try updateCodexHooksFeature(enabled: true)
    }

    static func disableCodexHooksFeature() throws {
        try updateCodexHooksFeature(enabled: false)
    }

    private static func updateCodexHooksFeature(enabled: Bool) throws {
        let configURL = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let desiredLine = "codex_hooks = \(enabled ? "true" : "false")"
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        let updated: String
        if let range = existing.range(
            of: #"(?m)^codex_hooks\s*=\s*(true|false)\s*$"#,
            options: .regularExpression
        ) {
            updated = existing.replacingCharacters(in: range, with: desiredLine)
        } else if let featuresRange = existing.range(
            of: #"(?m)^\[features\]\s*$"#,
            options: .regularExpression
        ) {
            let prefix = String(existing[..<featuresRange.upperBound])
            var suffix = String(existing[featuresRange.upperBound...])
            if !suffix.hasPrefix("\n") {
                suffix = "\n" + suffix
            }
            updated = "\(prefix)\n\(desiredLine)\(suffix)"
        } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated = "[features]\n\(desiredLine)\n"
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = "\(existing)\(separator)[features]\n\(desiredLine)\n"
        }

        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
