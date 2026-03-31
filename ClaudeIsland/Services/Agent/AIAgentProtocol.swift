//
//  AIAgentProtocol.swift
//  ClaudeIsland
//
//  Protocol defining what an AI coding agent must implement to work with Vibe Island.
//

import Foundation

enum AgentEventSourceMode: String, Sendable {
    case hook
    case hybrid
    case processOnly
}

/// Represents a type of hook event that an agent can emit
enum HookEventType: String, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case preCompact = "PreCompact"
    case interactionRequest = "InteractionRequest"
    case interactionResolved = "InteractionResolved"
}

/// Protocol for AI coding agent integrations
/// Each supported agent (Claude Code, Codex, Gemini CLI, etc.) implements this
protocol AIAgent: Sendable {
    /// Unique identifier for this agent (e.g., "claude", "codex", "gemini")
    var id: String { get }

    /// Human-readable display name (e.g., "Claude Code", "OpenAI Codex")
    var name: String { get }

    /// Priority for ordering (lower = higher priority in UI)
    var priority: Int { get }

    /// Unix socket path for hook events
    var socketPath: String { get }

    /// Directory where the agent stores session/conversation files
    var sessionFilesDirectory: String { get }

    /// Path to the agent's hook settings file
    var hookSettingsPath: String { get }

    /// Installed script filename inside the agent-specific hooks directory
    var hookScriptInstallName: String? { get }

    /// Full command path written into the hook config
    var hookCommandPath: String? { get }

    /// Hook events this agent supports
    var supportedEvents: Set<HookEventType> { get }

    /// Whether this agent uses a hook system for event communication
    var supportsHooks: Bool { get }

    /// How this agent feeds user-visible events into the shared state machine
    var eventSourceMode: AgentEventSourceMode { get }

    /// The process name(s) to look for when detecting via process monitoring
    var processNames: [String] { get }

    /// Parse a conversation file and return summary info
    func parseConversation(sessionId: String, cwd: String) -> ConversationInfo?

    /// Return the bundled resource name (without extension) for the Python hook script.
    /// Return an empty string if the agent doesn't use hook scripts.
    func hookScriptResourceName() -> String

    /// Generate the hook configuration entries for the agent's settings file.
    /// Format: [["event": "EventName", "config": [...]]]
    func hookConfig() -> [[String: Any]]

    /// Whether this agent's hooks are currently installed
    func areHooksInstalled() -> Bool

    /// Install hooks for this agent
    func installHooks() throws

    /// Uninstall hooks for this agent
    func uninstallHooks() throws

    /// Optional agent-specific post-install work
    func postInstallHooks() throws

    /// Optional agent-specific post-uninstall work
    func postUninstallHooks() throws
}

enum HookPythonLocator {
    static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}

private enum HookInstallSupport {

    static func settingsDirectory(for path: String) -> String {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        var directoryPath = path.replacingOccurrences(of: "~/", with: "~/")
        if directoryPath.hasSuffix("/\(fileName)") {
            directoryPath = String(directoryPath.dropLast(fileName.count + 1))
        }
        return directoryPath
    }

    static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func expandedSettingsURL(for agent: any AIAgent) -> URL {
        URL(fileURLWithPath: expandedPath(agent.hookSettingsPath))
    }

    static func hookScriptsDirectory(for agent: any AIAgent) -> URL {
        let hooksDirectory = expandedPath(settingsDirectory(for: agent.hookSettingsPath))
        return URL(fileURLWithPath: hooksDirectory).appendingPathComponent("hooks")
    }

    static func managedCommandMarkers(for agent: any AIAgent) -> [String] {
        var markers: [String] = []
        if let installName = agent.hookScriptInstallName {
            markers.append(installName)
        }
        markers.append("vibe-island-\(agent.id).py")
        return markers
    }

    static func isManagedCommand(_ command: String, for agent: any AIAgent) -> Bool {
        if command.contains("vibe-island-bridge"), command.contains("--source \(agent.id)") {
            return true
        }

        return managedCommandMarkers(for: agent).contains { marker in
            command.contains(marker)
        }
    }

    static func stripManagedHooks(from hooks: [String: Any], agent: any AIAgent) -> [String: Any] {
        var cleanedHooks: [String: Any] = [:]

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                cleanedHooks[event] = value
                continue
            }

            let cleanedEntries = entries.compactMap { entry -> [String: Any]? in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                    return entry
                }

                let remainingHooks = entryHooks.filter { hook in
                    let command = hook["command"] as? String ?? ""
                    return !isManagedCommand(command, for: agent)
                }

                guard !remainingHooks.isEmpty else { return nil }

                var updatedEntry = entry
                updatedEntry["hooks"] = remainingHooks
                return updatedEntry
            }

            if !cleanedEntries.isEmpty {
                cleanedHooks[event] = cleanedEntries
            }
        }

        return cleanedHooks
    }

    static func containsManagedHook(in entries: [[String: Any]], agent: any AIAgent) -> Bool {
        entries.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { hook in
                let command = hook["command"] as? String ?? ""
                return isManagedCommand(command, for: agent)
            }
        }
    }

    static func writeHookScriptIfNeeded(for agent: any AIAgent) throws {
        guard let installName = agent.hookScriptInstallName,
              !agent.hookScriptResourceName().isEmpty else {
            return
        }

        let hooksDirectory = hookScriptsDirectory(for: agent)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)

        let destination = hooksDirectory.appendingPathComponent(installName)
        if let bundled = Bundle.main.url(forResource: agent.hookScriptResourceName(), withExtension: "py") {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: bundled, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destination.path
            )
        }
    }

    static func install(_ agent: any AIAgent) throws {
        try writeHookScriptIfNeeded(for: agent)

        let settingsURL = expandedSettingsURL(for: agent)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        hooks = stripManagedHooks(from: hooks, agent: agent)

        for config in agent.hookConfig() {
            guard let event = config["event"] as? String,
                  let hookArray = config["config"] as? [[String: Any]] else {
                continue
            }

            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(contentsOf: hookArray)
            hooks[event] = entries
        }

        json["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL)
    }

    static func uninstall(_ agent: any AIAgent) throws {
        if let installName = agent.hookScriptInstallName {
            let scriptURL = hookScriptsDirectory(for: agent).appendingPathComponent(installName)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let settingsURL = expandedSettingsURL(for: agent)
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return
        }

        let cleanedHooks = stripManagedHooks(from: hooks, agent: agent)
        if cleanedHooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = cleanedHooks
        }

        let updatedData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: settingsURL)
    }

    static func areInstalled(_ agent: any AIAgent) -> Bool {
        guard agent.supportsHooks else { return false }

        let settingsURL = expandedSettingsURL(for: agent)
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for event in agent.supportedEvents {
            guard let entries = hooks[event.rawValue] as? [[String: Any]],
                  containsManagedHook(in: entries, agent: agent) else {
                return false
            }
        }

        return true
    }
}

// MARK: - Default implementations

extension AIAgent {
    func hookScriptResourceName() -> String { "" }

    var hookScriptInstallName: String? {
        let resourceName = hookScriptResourceName()
        return resourceName.isEmpty ? nil : "vibe-island-\(id).py"
    }

    var hookCommandPath: String? {
        guard let installName = hookScriptInstallName else { return nil }
        let python = HookPythonLocator.detectPython()
        let hooksDirectory = HookInstallSupport.settingsDirectory(for: hookSettingsPath)
        return "\(python) \(hooksDirectory)/hooks/\(installName)"
    }

    func hookConfig() -> [[String: Any]] { [] }

    func postInstallHooks() throws {}

    func postUninstallHooks() throws {}

    func installedHookEvents() -> Set<HookEventType> {
        Set(hookConfig().compactMap { entry in
            guard let eventName = entry["event"] as? String else { return nil }
            return HookEventType(rawValue: eventName)
        })
    }

    func validateHookContract() throws {
        guard supportsHooks else { return }

        let declaredEvents = supportedEvents
        let installedEvents = installedHookEvents()
        guard declaredEvents == installedEvents else {
            let missingInstall = declaredEvents.subtracting(installedEvents).map(\.rawValue).sorted()
            let missingDeclare = installedEvents.subtracting(declaredEvents).map(\.rawValue).sorted()
            let details = [
                missingInstall.isEmpty ? nil : "declaredOnly=\(missingInstall.joined(separator: ","))",
                missingDeclare.isEmpty ? nil : "installedOnly=\(missingDeclare.joined(separator: ","))"
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            throw AgentError.hookInstallationFailed(
                "Hook contract mismatch for \(id): \(details)"
            )
        }
    }

    func areHooksInstalled() -> Bool {
        HookInstallSupport.areInstalled(self)
    }

    func installHooks() throws {
        try validateHookContract()
        try HookInstallSupport.install(self)
        try postInstallHooks()
    }

    func uninstallHooks() throws {
        try HookInstallSupport.uninstall(self)
        try postUninstallHooks()
    }
}
