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
            let text = extractMessageText(from: message["content"])

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

            if let content = extractMessageText(from: message["content"]),
               let interaction = SessionInteractionRequest.fromHeuristicText(
                    sessionId: conversation.sessionId,
                    interactionId: "gemini-message-\(index)",
                    sourceAgent: "gemini",
                    text: content,
                    timestamp: timestamp,
                    submitMode: submitMode
               ) {
                return interaction
            }
        }

        return nil
    }

    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        guard let conversation = resolveConversation(sessionId: sessionId, cwd: cwd),
              let data = FileManager.default.contents(atPath: conversation.chatPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let messages = json["messages"] as? [[String: Any]] ?? []

        return messages.enumerated().compactMap { index, message in
            let role = message["type"] as? String ?? "info"
            let text = extractMessageText(from: message["content"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }

            let timestamp = (message["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? conversation.lastUpdated
            let chatRole: ChatRole = role == "user" ? .user : .assistant

            return ChatMessage(
                id: "gemini-\(index)",
                role: chatRole,
                timestamp: timestamp,
                content: [.text(text)]
            )
        }
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
            return text
        }
        if let parts = rawContent as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
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
