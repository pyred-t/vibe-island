//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Unified hook installer for all supported agents
//

import Foundation

@MainActor
struct HookInstaller {

    /// Install hook scripts and update hook settings for all supported agents.
    static func installIfNeeded() {
        AgentRegistry.shared.installHooksForAll()
    }

    /// Check if hooks are currently installed for all hook-capable agents.
    static func isInstalled() -> Bool {
        AgentRegistry.shared.areAllHooksInstalled()
    }

    /// Uninstall hooks for all hook-capable agents.
    static func uninstall() {
        AgentRegistry.shared.uninstallHooksForAll()
    }
}
