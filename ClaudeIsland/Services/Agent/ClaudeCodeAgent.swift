//
//  ClaudeCodeAgent.swift
//  ClaudeIsland
//
//  Claude Code integration for Vibe Island.
//  Encapsulates all Claude Code-specific detection, hook installation, and parsing.
//

import Foundation

/// Claude Code agent implementation
struct ClaudeCodeAgent: AIAgent {
    let id: String = "claude"
    let name: String = "Claude Code"
    let priority: Int = 0  // Highest priority
    let socketPath: String = "/tmp/claude-island.sock"

    let sessionFilesDirectory: String = ".claude"
    let hookSettingsPath: String = "~/.claude/settings.json"
    let hookScriptInstallName: String? = "claude-island-state.py"
    let hookCommandPath: String? = "\(HookPythonLocator.detectPython()) ~/.claude/hooks/claude-island-state.py"

    let supportedEvents: Set<HookEventType> = [
        .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest,
        .notification, .stop, .subagentStop,
        .sessionStart, .sessionEnd, .preCompact
    ]

    let supportsHooks: Bool = true
    let eventSourceMode: AgentEventSourceMode = .hook

    let processNames: [String] = ["claude"]

    // MARK: - Conversation Parsing

    func parseConversation(sessionId: String, cwd: String) -> ConversationInfo? {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let sessionFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              attrs[.modificationDate] as? Date != nil else {
            return nil
        }

        guard let data = fileManager.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parseJSONLContent(content)
    }

    private func parseJSONLContent(_ content: String) -> ConversationInfo {
        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessage: String?
        var lastUserMessageDate: Date?

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            if type == "summary", let s = json["summary"] as? String {
                summary = s
            }

            if type == "user" {
                if firstUserMessage == nil {
                    if let contentArray = json["content"] as? [[String: Any]],
                       let textBlock = contentArray.first,
                       let text = textBlock["text"] as? String {
                        firstUserMessage = String(text.prefix(80))
                    }
                }
                if let contentArray = json["content"] as? [[String: Any]],
                   let textBlock = contentArray.first {
                    if let text = textBlock["text"] as? String {
                        lastUserMessage = String(text.prefix(120))
                    }
                    if let timestamp = textBlock["timestamp"] as? String {
                        let formatter = ISO8601DateFormatter()
                        lastUserMessageDate = formatter.date(from: timestamp)
                    }
                }
            }

            if type == "assistant" {
                if let contentArray = json["content"] as? [[String: Any]] {
                    for block in contentArray {
                        if let text = block["text"] as? String {
                            lastMessage = String(text.prefix(120))
                            lastMessageRole = "assistant"
                        }
                        if let toolUse = block["tool_use"] as? [String: Any] {
                            lastToolName = toolUse["name"] as? String
                        }
                    }
                }
            }

            if type == "tool" {
                if let contentArray = json["content"] as? [[String: Any]],
                   let toolResult = contentArray.first {
                    if let text = toolResult["content"] as? String {
                        lastMessage = String(text.prefix(120))
                        lastMessageRole = "tool"
                    }
                    lastToolName = json["name"] as? String
                }
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessage: lastUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    // MARK: - Hook Script

    /// Returns the bundled hook script resource name (without extension)
    func hookScriptResourceName() -> String { "claude-island-state" }

    /// The bundled hook script name for reference
    var bundledHookScriptName: String { "claude-island-state" }

    // MARK: - Hook Configuration

    /// Returns hook configs in the format expected by Claude Code's settings.json
    func hookConfig() -> [[String: Any]] {
        ClaudeCodeAgentHookConfig.hookConfig(commandPath: hookCommandPath ?? "")
    }
}

/// Claude Code hook configuration helper
enum ClaudeCodeAgentHookConfig {
    /// Returns hook configs in the format expected by Claude Code's settings.json
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
            ["event": "PreToolUse", "config": withMatcherAndTimeout],
            ["event": "PostToolUse", "config": withMatcher],
            ["event": "PermissionRequest", "config": withMatcherAndTimeout],
            ["event": "Notification", "config": withMatcher],
            ["event": "Stop", "config": withoutMatcher],
            ["event": "SubagentStop", "config": withoutMatcher],
            ["event": "SessionStart", "config": withoutMatcher],
            ["event": "SessionEnd", "config": withoutMatcher],
            ["event": "PreCompact", "config": preCompactConfig],
        ]
    }
}
