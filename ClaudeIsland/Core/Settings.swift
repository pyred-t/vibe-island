//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let enabledAgents = "enabledAgents"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Agent Settings

    /// Set of enabled agent IDs (e.g., "claude", "codex", "gemini")
    /// If empty, all agents are enabled
    static var enabledAgents: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Keys.enabledAgents) ?? [])
        }
        set {
            defaults.set(Array(newValue), forKey: Keys.enabledAgents)
        }
    }

    /// Check if an agent is enabled
    static func isAgentEnabled(_ agentId: String) -> Bool {
        let enabled = enabledAgents
        // Empty means all enabled
        return enabled.isEmpty || enabled.contains(agentId)
    }

    /// Enable or disable an agent
    static func setAgentEnabled(_ agentId: String, enabled: Bool) {
        var enabledSet = enabledAgents
        if enabledSet.isEmpty {
            // If no specific agents are set, all are enabled
            // Remove the agent from the "all enabled" state by setting the specific set
            if !enabled {
                enabledSet = Set(["claude", "codex", "gemini"])
                enabledSet.remove(agentId)
                enabledAgents = enabledSet
            }
        } else {
            if enabled {
                enabledSet.insert(agentId)
            } else {
                enabledSet.remove(agentId)
            }
            enabledAgents = enabledSet
        }
    }
}
