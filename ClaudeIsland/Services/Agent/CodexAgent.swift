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
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd),
              let data = FileManager.default.contents(atPath: conversation.rolloutPath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var messages: [ChatMessage] = []

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let timestamp = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? conversation.updatedAt

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "message",
               let role = payload["role"] as? String,
               let messageText = extractMessageText(from: payload["content"]),
               !messageText.isEmpty {
                let chatRole: ChatRole = role == "user" ? .user : .assistant
                messages.append(
                    ChatMessage(
                        id: "codex-\(index)",
                        role: chatRole,
                        timestamp: timestamp,
                        content: [.text(messageText)]
                    )
                )
                continue
            }

            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "agent_message",
               let messageText = payload["message"] as? String,
               !messageText.isEmpty {
                messages.append(
                    ChatMessage(
                        id: "codex-commentary-\(index)",
                        role: .assistant,
                        timestamp: timestamp,
                        content: [.text(messageText)]
                    )
                )
            }
        }

        return messages
    }

    func resolveCurrentConversation(cwd: String) -> ResolvedCodexConversation? {
        resolveConversation(sessionId: nil, cwd: cwd)
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
        select id, rollout_path, title, updated_at
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
        guard parts.count >= 4,
              let updatedAtEpoch = TimeInterval(parts[3]) else {
            return nil
        }

        return ResolvedCodexConversation(
            sessionId: "codex-thread-\(parts[0])",
            rolloutPath: parts[1],
            title: parts[2],
            updatedAt: Date(timeIntervalSince1970: updatedAtEpoch)
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

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "message",
               let role = payload["role"] as? String,
               let messageText = extractMessageText(from: payload["content"]) {
                if role == "user" {
                    if firstUserMessage == nil {
                        firstUserMessage = Self.truncate(messageText, maxLength: 50)
                    }
                    lastUserMessage = Self.truncate(messageText, maxLength: 80)
                    if let timestampStr = json["timestamp"] as? String {
                        lastUserMessageDate = formatter.date(from: timestampStr)
                    }
                }

                lastMessage = Self.truncate(messageText, maxLength: 80)
                lastMessageRole = role
                continue
            }

            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "agent_message",
               let messageText = payload["message"] as? String {
                lastMessage = Self.truncate(messageText, maxLength: 80)
                lastMessageRole = "assistant"
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

            if type == "event_msg",
               payload["type"] as? String == "agent_message",
               let message = payload["message"] as? String,
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

    private func extractMessageText(from rawContent: Any?) -> String? {
        if let parts = rawContent as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                guard let type = part["type"] as? String else { return nil }
                switch type {
                case "input_text", "output_text":
                    return part["text"] as? String
                default:
                    return nil
                }
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
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

    /// Detect running Codex sessions via process tree analysis
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
                if comm == "codex" || comm == "_codex" {
                    if let pid = Int(components[0]) {
                        let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid) ?? ""
                        let sessionId = resolveCurrentConversation(cwd: cwd)?.sessionId ?? "codex-pid-\(pid)"
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

struct ResolvedCodexConversation: Sendable {
    let sessionId: String
    let rolloutPath: String
    let title: String
    let updatedAt: Date
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
