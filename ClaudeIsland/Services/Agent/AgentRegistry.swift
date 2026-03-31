//
//  AgentRegistry.swift
//  ClaudeIsland
//
//  Central registry for all AI coding agents supported by Vibe Island.
//

import Foundation
import Combine

/// Registry of all AI coding agents supported by Vibe Island
/// Singleton accessed from the MainActor context
@MainActor
final class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()

    /// All registered agents keyed by agent ID
    @Published private(set) var agents: [String: any AIAgent] = [:]

    /// Primary active agent (the one with the most recent activity)
    @Published private(set) var primaryAgentId: String?

    private init() {
        registerDefaultAgents()
    }

    // MARK: - Agent Registration

    /// Register all supported agents
    private func registerDefaultAgents() {
        let claude = ClaudeCodeAgent()
        agents[claude.id] = claude

        let codex = CodexAgent()
        agents[codex.id] = codex

        let gemini = GeminiCLIAgent()
        agents[gemini.id] = gemini
    }

    /// Register a custom agent
    func register(_ agent: any AIAgent) {
        agents[agent.id] = agent
    }

    // MARK: - Agent Access

    /// Get an agent by ID
    func agent(for id: String) -> (any AIAgent)? {
        agents[id]
    }

    /// Get all registered agents sorted by priority
    func allAgents() -> [(any AIAgent)] {
        agents.values.sorted { $0.priority < $1.priority }
    }

    /// Get agents that have hooks installed
    func agentsWithInstalledHooks() -> [(any AIAgent)] {
        allAgents().filter { $0.supportsHooks && $0.areHooksInstalled() }
    }

    /// Whether all hook-capable agents have hooks installed
    func areAllHooksInstalled() -> Bool {
        let hookAgents = allAgents().filter { $0.supportsHooks }
        guard !hookAgents.isEmpty else { return false }
        return hookAgents.allSatisfy { $0.areHooksInstalled() }
    }

    /// Get the primary agent (highest priority running agent)
    func primaryAgent() -> (any AIAgent)? {
        guard let id = primaryAgentId else { return nil }
        return agents[id]
    }

    /// Get the display name for an agent ID
    func displayName(for agentId: String?) -> String {
        guard let id = agentId, let agent = agents[id] else {
            return "Claude Code" // Backwards compat
        }
        return agent.name
    }

    /// Short display name used in compact UI.
    func shortDisplayName(for agentId: String?) -> String {
        switch agentId {
        case "codex":
            return "Codex"
        case "gemini":
            return "Gemini CLI"
        default:
            return "Claude Code"
        }
    }

    // MARK: - Primary Agent Management

    /// Update which agent is considered "primary" (most recent activity)
    func updatePrimaryAgent(withSessionFrom agentId: String) {
        primaryAgentId = agentId
    }

    /// Get all socket paths for agents with hook support
    func hookSocketPaths() -> [String] {
        agents.values
            .filter { $0.supportsHooks }
            .map { $0.socketPath }
    }

    // MARK: - Hook Management

    /// Install hooks for all agents that support them
    func installHooksForAll() {
        for agent in agents.values where agent.supportsHooks {
            do {
                try agent.installHooks()
            } catch {
                // Log but don't fail
                print("Failed to install hooks for \(agent.id): \(error)")
            }
        }
    }

    /// Install hooks for a specific agent
    func installHooks(for agentId: String) throws {
        guard let agent = agents[agentId] else {
            throw AgentError.unknownAgent(agentId)
        }
        try agent.installHooks()
    }

    /// Uninstall hooks for all agents that support them
    func uninstallHooksForAll() {
        for agent in agents.values where agent.supportsHooks {
            do {
                try agent.uninstallHooks()
            } catch {
                print("Failed to uninstall hooks for \(agent.id): \(error)")
            }
        }
    }
}

// MARK: - Errors

enum AgentError: Error {
    case unknownAgent(String)
    case hookInstallationFailed(String)
}
