//
//  AgentEventCoordinator.swift
//  ClaudeIsland
//
//  Centralized startup and coordination for all agent event sources.
//

import Foundation

@MainActor
final class AgentEventCoordinator {
    static let shared = AgentEventCoordinator()

    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.agentId == "claude", event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == HookEventType.stop.rawValue {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == HookEventType.postToolUse.rawValue, let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )

        Task {
            await ProcessBasedAgentDetector.shared.start()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        HookSocketServer.shared.stop()
        InterruptWatcherManager.shared.stopAll()

        Task {
            await ProcessBasedAgentDetector.shared.stop()
        }
    }
}
