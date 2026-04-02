//
//  GeminiCLIAgent.swift
//  ClaudeIsland
//
//  Google Gemini CLI integration for Vibe Island.
//  Primary detection: native hooks, with file parsing only for history and cold restore.
//

import Foundation

/// Google Gemini CLI agent implementation.
struct GeminiCLIAgent: AIAgent {
    let id: String = "gemini"
    let name: String = "Google Gemini CLI"
    let priority: Int = 2  // P1 - second priority
    let socketPath: String = "/tmp/claude-island.sock"

    // Gemini CLI stores data in ~/.gemini/ or ~/.config/gemini/
    let sessionFilesDirectory: String = "~/.gemini"
    let hookSettingsPath: String = "~/.config/gemini/settings.json"
    let hookScriptInstallName: String? = "vibe-island-gemini.py"
    let hookCommandPath: String? = "\(HookPythonLocator.detectPython()) ~/.config/gemini/hooks/vibe-island-gemini.py"

    let supportedEvents: Set<HookEventType> = [
        .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest,
        .notification, .stop, .sessionStart, .sessionEnd, .preCompact
    ]

    let supportsHooks: Bool = true
    let eventSourceMode: AgentEventSourceMode = .hook

    let processNames: [String] = ["gemini", "Gemini", "gemini-cli"]

    // MARK: - Conversation Parsing

    func parseConversation(sessionId: String, cwd: String) -> ConversationInfo? {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd) else { return nil }

        guard let data = FileManager.default.contents(atPath: conversation.chatPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let messages = json["messages"] as? [[String: Any]] ?? []
        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessage: String?
        var lastUserMessageDate: Date?

        for message in messages {
            let role = message["type"] as? String ?? "info"
            let text = preferredDisplayText(for: message)

            if role == "user", firstUserMessage == nil {
                firstUserMessage = Self.truncate(text, maxLength: 50)
            }

            if role == "user" {
                lastUserMessage = Self.truncate(text, maxLength: 80)
            }

            if role == "user",
               let timestamp = message["timestamp"] as? String {
                lastUserMessageDate = formatter.date(from: timestamp)
            }

            if let text, !text.isEmpty {
                lastMessage = Self.truncate(text, maxLength: 80)
                lastMessageRole = role == "user" ? "user" : "assistant"
            }
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage ?? conversation.projectName,
            lastUserMessage: lastUserMessage,
            lastUserMessageDate: lastUserMessageDate ?? conversation.lastUpdated
        )
    }

    func parseInteraction(
        sessionId: String,
        cwd: String,
        isInTmux: Bool,
        tty: String?
    ) -> SessionInteractionRequest? {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd),
              let data = FileManager.default.contents(atPath: conversation.chatPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let submitMode = SessionInteractionRequest.submitMode(isInTmux: isInTmux, tty: tty)
        let messages = json["messages"] as? [[String: Any]] ?? []

        for (index, message) in messages.enumerated().reversed() {
            let timestamp = (message["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? conversation.lastUpdated

            if let interaction = parseStructuredInteraction(
                from: message,
                sessionId: conversation.sessionId,
                interactionId: "gemini-message-\(index)",
                submitMode: submitMode,
                timestamp: timestamp
            ) {
                return interaction
            }

            let candidates = interactionCandidateTexts(for: message)
            if let interaction = candidates.lazy.compactMap({ candidate in
                SessionInteractionRequest.fromHeuristicText(
                    sessionId: conversation.sessionId,
                    interactionId: "gemini-message-\(index)",
                    sourceAgent: "gemini",
                    text: candidate,
                    timestamp: timestamp,
                    submitMode: submitMode
                )
            }).first {
                return interaction
            }
        }

        return nil
    }

    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        parseHistory(sessionId: sessionId, cwd: cwd).messages
    }

    func parseHistory(sessionId: String, cwd: String) -> AgentHistorySnapshot {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd),
              let data = FileManager.default.contents(atPath: conversation.chatPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let messages = json["messages"] as? [[String: Any]] ?? []
        var parsedMessages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var structuredResults: [String: ToolResultData] = [:]

        for (index, message) in messages.enumerated() {
            let role = message["type"] as? String ?? "info"
            let timestamp = (message["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? conversation.lastUpdated
            let chatRole: ChatRole
            switch role {
            case "user":
                chatRole = .user
            case "info":
                chatRole = .system
            default:
                chatRole = .assistant
            }

            var blocks: [MessageBlock] = []
            var messageCompletedToolIds: Set<String> = []

            if let thoughts = message["thoughts"] as? [[String: Any]] {
                blocks.append(contentsOf: thoughts.compactMap(parseThoughtBlock))
            }

            if let text = extractMessageText(from: message["content"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                blocks.append(.text(text))
            }

            if blocks.filter({ if case .text = $0 { return true }; return false }).isEmpty,
               let fallbackText = extractToolFallbackText(fromMessage: message) {
                blocks.append(.text(fallbackText))
            }

            if let toolCalls = message["toolCalls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    if let block = parseToolUseBlock(from: toolCall) {
                        blocks.append(.toolUse(block))
                    }
                    if let completedId = completedToolId(from: toolCall) {
                        messageCompletedToolIds.insert(completedId)
                        if let rawToolName = toolCall["name"] as? String {
                            let normalizedInput = ExternalAgentToolSupport.normalizeToolInput(
                                agentId: id,
                                rawName: rawToolName,
                                input: serializeToolInput(toolCall["args"] as? [String: Any] ?? [:])
                            )
                            let parsed = ExternalAgentToolSupport.parseResult(
                                agentId: id,
                                rawToolName: rawToolName,
                                toolInput: normalizedInput,
                                rawOutput: nil,
                                rawPayload: toolCall
                            )
                            if let parserResult = parsed.parserResult {
                                toolResults[completedId] = parserResult
                            }
                            if let structuredResult = parsed.structuredResult {
                                structuredResults[completedId] = structuredResult
                            }
                        }
                    }
                }
            }

            guard !blocks.isEmpty else { continue }
            completedToolIds.formUnion(messageCompletedToolIds)

            parsedMessages.append(
                ChatMessage(
                    id: "gemini-\(index)",
                    role: chatRole,
                    timestamp: timestamp,
                    content: blocks
                )
            )
        }

        return AgentHistorySnapshot(
            messages: parsedMessages,
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: parseConversation(sessionId: sessionId, cwd: cwd) ?? ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: conversation.projectName,
                lastUserMessage: nil,
                lastUserMessageDate: conversation.lastUpdated
            )
        )
    }

    func resolveCurrentConversation(cwd: String) -> ResolvedGeminiConversation? {
        resolveConversation(sessionId: nil, cwd: cwd)
    }

    func resolveConversation(sessionId: String?, cwd: String) -> ResolvedGeminiConversation? {
        let conversations = allConversations(cwd: cwd)
        guard !conversations.isEmpty else { return nil }

        if let requestedSessionId = sessionId.flatMap(Self.sessionId(fromSessionId:)) {
            if let matchingConversation = conversations.first(where: {
                Self.sessionId(fromSessionId: $0.sessionId) == requestedSessionId
            }) {
                return matchingConversation
            }
        }

        return conversations.first
    }

    private func allConversations(cwd: String) -> [ResolvedGeminiConversation] {
        let historyRoot = URL(fileURLWithPath: NSString(string: "~/.gemini/history").expandingTildeInPath)
        let tmpRoot = URL(fileURLWithPath: NSString(string: "~/.gemini/tmp").expandingTildeInPath)
        let fileManager = FileManager.default

        guard let historyDirs = try? fileManager.contentsOfDirectory(
            at: historyRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var conversations: [ResolvedGeminiConversation] = []

        for dir in historyDirs {
            let rootMarker = dir.appendingPathComponent(".project_root")
            guard let rootData = try? Data(contentsOf: rootMarker),
                  let projectRoot = String(data: rootData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  projectRoot == cwd else {
                continue
            }

            let chatsDir = tmpRoot.appendingPathComponent(dir.lastPathComponent).appendingPathComponent("chats")
            guard let chatFiles = try? fileManager.contentsOfDirectory(
                at: chatsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter({ $0.pathExtension == "json" }),
            !chatFiles.isEmpty else {
                continue
            }

            let parsed = chatFiles.compactMap { chatFile in
                resolvedConversation(chatFile: chatFile, cwd: cwd)
            }
            conversations.append(contentsOf: parsed)
        }

        return conversations.sorted { $0.lastUpdated > $1.lastUpdated }
    }

    private func resolvedConversation(chatFile: URL, cwd: String) -> ResolvedGeminiConversation? {
        guard let latestData = try? Data(contentsOf: chatFile),
              let latestJSON = try? JSONSerialization.jsonObject(with: latestData) as? [String: Any] else {
            return nil
        }

        let sessionId = latestJSON["sessionId"] as? String ?? chatFile.deletingPathExtension().lastPathComponent
        let lastUpdatedString = latestJSON["lastUpdated"] as? String
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fileDate = (try? chatFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let lastUpdated = lastUpdatedString.flatMap { formatter.date(from: $0) } ?? fileDate ?? .distantPast

        return ResolvedGeminiConversation(
            sessionId: "gemini-chat-\(sessionId)",
            chatPath: chatFile.path,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            lastUpdated: lastUpdated
        )
    }

    private static func sessionId(fromSessionId sessionId: String) -> String {
        if sessionId.hasPrefix("gemini-chat-") {
            return String(sessionId.dropFirst("gemini-chat-".count))
        }
        return sessionId
    }

    private func extractMessageText(from rawContent: Any?) -> String? {
        if let text = rawContent as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let parts = rawContent as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                let text = part["text"] as? String
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func preferredDisplayText(for message: [String: Any]) -> String? {
        if let contentText = extractMessageText(from: message["content"]) {
            return contentText
        }

        if let toolFallback = extractToolFallbackText(fromMessage: message) {
            return toolFallback
        }

        let thoughtTexts = (message["thoughts"] as? [[String: Any]] ?? []).compactMap { thought in
            parseThoughtBlock(from: thought)?.thinkingText
        }
        let joinedThoughts = thoughtTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joinedThoughts.isEmpty ? nil : joinedThoughts
    }

    private func interactionCandidateTexts(for message: [String: Any]) -> [String] {
        var candidates: [String] = []

        if let contentText = extractMessageText(from: message["content"]) {
            candidates.append(contentText)
        }

        if let fallbackText = extractToolFallbackText(fromMessage: message),
           !candidates.contains(fallbackText) {
            candidates.append(fallbackText)
        }

        return candidates
    }

    private func extractToolFallbackText(fromMessage message: [String: Any]) -> String? {
        guard let toolCalls = message["toolCalls"] as? [[String: Any]], !toolCalls.isEmpty else {
            return nil
        }

        var snippets: [String] = []
        for toolCall in toolCalls {
            if let snippet = extractToolFallbackText(from: toolCall),
               !snippet.isEmpty,
               !snippets.contains(snippet) {
                snippets.append(snippet)
            }
        }

        let joined = snippets.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func extractToolFallbackText(from toolCall: [String: Any]) -> String? {
        let toolName = (toolCall["name"] as? String ?? "").lowercased()
        let resultDisplay = trimmedString(toolCall["resultDisplay"])
        let renderOutputAsMarkdown = toolCall["renderOutputAsMarkdown"] as? Bool ?? false

        guard let responseText = extractToolResponseText(from: toolCall) else {
            return shouldPromoteToolResultDisplay(toolName: toolName, resultDisplay: resultDisplay) ? resultDisplay : nil
        }

        if shouldPromoteToolResponse(
            toolName: toolName,
            responseText: responseText,
            resultDisplay: resultDisplay,
            renderOutputAsMarkdown: renderOutputAsMarkdown
        ) {
            return responseText
        }

        if shouldPromoteToolResultDisplay(toolName: toolName, resultDisplay: resultDisplay) {
            return resultDisplay
        }

        return nil
    }

    private func extractToolResponseText(from toolCall: [String: Any]) -> String? {
        guard let results = toolCall["result"] as? [[String: Any]], !results.isEmpty else {
            return nil
        }

        var fragments: [String] = []
        for result in results {
            guard let functionResponse = result["functionResponse"] as? [String: Any],
                  let response = functionResponse["response"] as? [String: Any] else {
                continue
            }

            if let output = trimmedString(response["output"]) {
                fragments.append(output)
            } else if let error = trimmedString(response["error"]) {
                fragments.append(error)
            }
        }

        let joined = fragments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func shouldPromoteToolResponse(
        toolName: String,
        responseText: String,
        resultDisplay: String?,
        renderOutputAsMarkdown: Bool
    ) -> Bool {
        if shouldSuppressVerboseToolResponse(toolName: toolName, responseText: responseText) {
            return false
        }

        if toolName == "ask_user" {
            return true
        }

        if responseText.count <= 1200 {
            return true
        }

        if renderOutputAsMarkdown && looksLikeStructuredMarkdown(responseText) {
            return true
        }

        if let resultDisplay, !resultDisplay.isEmpty, responseText.contains(resultDisplay) {
            return true
        }

        return false
    }

    private func shouldPromoteToolResultDisplay(toolName: String, resultDisplay: String?) -> Bool {
        guard let resultDisplay, !resultDisplay.isEmpty else { return false }
        if toolName == "read_file" || toolName == "list_directory" {
            return false
        }
        return resultDisplay.count <= 400
    }

    private func shouldSuppressVerboseToolResponse(toolName: String, responseText: String) -> Bool {
        if ["read_file", "list_directory"].contains(toolName) {
            return true
        }

        if responseText.hasPrefix("Directory listing for ") {
            return true
        }

        if responseText.hasPrefix("<!doctype html") || responseText.hasPrefix("import ") {
            return true
        }

        return responseText.count > 2000 && !looksLikeStructuredMarkdown(responseText)
    }

    private func looksLikeStructuredMarkdown(_ text: String) -> Bool {
        let markdownSignals = [
            "\n#",
            "\n##",
            "\n- ",
            "\n* ",
            "\n1. ",
            "```",
            "| ---"
        ]
        return markdownSignals.contains { text.contains($0) }
    }

    private func trimmedString(_ rawValue: Any?) -> String? {
        guard let text = rawValue as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseThoughtBlock(from rawThought: [String: Any]) -> MessageBlock? {
        let subject = (rawThought["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (rawThought["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let text = [subject, description]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")

        guard !text.isEmpty else { return nil }
        return .thinking(text)
    }

    private func parseToolUseBlock(from rawToolCall: [String: Any]) -> ToolUseBlock? {
        guard let id = rawToolCall["id"] as? String,
              let rawName = rawToolCall["name"] as? String else {
            return nil
        }

        let args = rawToolCall["args"] as? [String: Any] ?? [:]
        let normalizedInput = ExternalAgentToolSupport.normalizeToolInput(
            agentId: self.id,
            rawName: rawName,
            input: serializeToolInput(args)
        )
        let normalizedName = ExternalAgentToolSupport.normalizeToolName(agentId: self.id, rawName: rawName)
        return ToolUseBlock(id: id, name: normalizedName, input: normalizedInput)
    }

    private func parseStructuredInteraction(
        from message: [String: Any],
        sessionId: String,
        interactionId: String,
        submitMode: InteractionSubmitMode,
        timestamp: Date
    ) -> SessionInteractionRequest? {
        if let toolCalls = message["toolCalls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                guard let toolId = toolCall["id"] as? String,
                      let name = toolCall["name"] as? String else {
                    continue
                }

                if name == "ask_user",
                   let args = toolCall["args"] as? [String: Any],
                   let interaction = SessionInteractionRequest.fromJSONObjectPayload(
                        sessionId: sessionId,
                        toolUseId: toolId,
                        payload: args,
                        timestamp: timestamp,
                        sourceAgent: self.id,
                        submitMode: submitMode
                   ) {
                    return interaction
                }
            }
        }

        if message["type"] as? String == "choice",
           let interaction = SessionInteractionRequest.fromJSONObjectPayload(
                sessionId: sessionId,
                toolUseId: interactionId,
                payload: message,
                timestamp: timestamp,
                sourceAgent: self.id,
                submitMode: submitMode
           ) {
            return interaction
        }

        return nil
    }

    private func completedToolId(from rawToolCall: [String: Any]) -> String? {
        guard let id = rawToolCall["id"] as? String else { return nil }

        if let results = rawToolCall["result"] as? [[String: Any]], !results.isEmpty {
            return id
        }

        if let functionResponse = rawToolCall["functionResponse"] as? [String: Any],
           functionResponse["response"] != nil {
            return id
        }

        return nil
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

    func hookScriptResourceName() -> String { "gemini-island-hook" }

    func hookConfig() -> [[String: Any]] {
        GeminiCLIHookConfig.hookConfig(commandPath: hookCommandPath ?? "")
    }

    // MARK: - Process-Based Session Detection

    /// Detect running Gemini CLI sessions via process tree analysis
    /// Returns array of (pid, cwd, sessionId) tuples
    func detectRunningSessions() -> [(pid: Int, cwd: String, sessionId: String)] {
        var results: [(pid: Int, cwd: String, sessionId: String)] = []

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
                if comm == "gemini" || comm == "_gemini" {
                    if let pid = Int(components[0]) {
                        let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid) ?? ""
                        let sessionId = resolveCurrentConversation(cwd: cwd)?.sessionId ?? "gemini-pid-\(pid)"
                        results.append((
                            pid: pid,
                            cwd: cwd,
                            sessionId: sessionId
                        ))
                    }
                }
            }
        } catch {
            // Silently fail
        }

        return results
    }
}

struct ResolvedGeminiConversation: Sendable {
    let sessionId: String
    let chatPath: String
    let projectName: String
    let lastUpdated: Date
}

private extension MessageBlock {
    var thinkingText: String? {
        if case .thinking(let text) = self {
            return text
        }
        return nil
    }
}

enum GeminiCLIHookConfig {
    static func hookConfig(commandPath: String) -> [[String: Any]] {
        let hookEntry: [[String: Any]] = [["type": "command", "command": commandPath]]
        let hookEntryWithTimeout: [[String: Any]] = [
            ["type": "command", "command": commandPath, "timeout": 86400]
        ]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [
            ["matcher": "*", "hooks": hookEntryWithTimeout]
        ]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        return [
            ["event": "UserPromptSubmit", "config": withoutMatcher],
            ["event": "PreToolUse", "config": withMatcher],
            ["event": "PostToolUse", "config": withMatcher],
            ["event": "PermissionRequest", "config": withMatcherAndTimeout],
            ["event": "Notification", "config": withMatcher],
            ["event": "Stop", "config": withoutMatcher],
            ["event": "SessionStart", "config": withoutMatcher],
            ["event": "SessionEnd", "config": withoutMatcher],
            ["event": "PreCompact", "config": preCompactConfig],
        ]
    }
}
