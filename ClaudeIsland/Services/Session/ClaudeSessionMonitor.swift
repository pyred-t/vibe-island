//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []
    @Published var interactionSubmitErrors: [String: String] = [:]
    @Published var submittingInteractionSessionIds: Set<String> = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        AgentEventCoordinator.shared.start()
    }

    func stopMonitoring() {
        AgentEventCoordinator.shared.stop()
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            _ = await submitPermissionDecision(sessionId: sessionId, decisionId: "allow")
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            _ = await submitPermissionDecision(sessionId: sessionId, decisionId: "deny", reason: reason)
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    func submitInteraction(sessionId: String, option: InteractionOption) async -> InteractionSubmitResult {
        await submitInteraction(sessionId: sessionId, responses: [InteractionResponse(questionId: "question-0", option: option)])
    }

    func submitInteraction(sessionId: String, responses: [InteractionResponse]) async -> InteractionSubmitResult {
        submittingInteractionSessionIds.insert(sessionId)
        interactionSubmitErrors.removeValue(forKey: sessionId)
        defer {
            submittingInteractionSessionIds.remove(sessionId)
        }

        guard let session = await SessionStore.shared.session(for: sessionId),
              !responses.isEmpty else {
            let result = InteractionSubmitResult.failure("Session not found")
            interactionSubmitErrors[sessionId] = result.error
            return result
        }

        let interaction = session.activeInteraction ?? {
            guard let permission = session.activePermission else { return nil }
            return SessionInteractionRequest.from(
                permission: permission,
                sessionId: session.sessionId,
                agentId: session.agentId,
                submitMode: SessionInteractionRequest.submitMode(isInTmux: session.isInTmux, tty: session.tty)
            )
        }()

        guard let interaction else {
            let result = InteractionSubmitResult.failure("No pending interaction found")
            interactionSubmitErrors[sessionId] = result.error
            return result
        }

        if let permission = session.activePermission,
           interaction.toolUseId == permission.toolUseId {
            if interaction.transportPreference == .programmaticOnly,
               let decision = hookDecision(from: responses.first?.option.id) {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: decision
                )

                switch decision {
                case "allow":
                    await SessionStore.shared.process(
                        .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
                    )
                case "deny":
                    await SessionStore.shared.process(
                        .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: nil)
                    )
                default:
                    break
                }

                return .success(via: .hookSocket)
            }
        }

        if let toolUseId = interaction.toolUseId,
           let updatedInput = interaction.programmaticUpdatedInput(for: responses) {
            HookSocketServer.shared.respondToInteraction(
                toolUseId: toolUseId,
                updatedInput: updatedInput
            )

            await SessionStore.shared.process(
                .interactionSubmitted(sessionId: sessionId, toolUseId: toolUseId)
            )

            return .success(via: .hookSocket)
        }

        if interaction.transportPreference == .programmaticOnly {
            let result = InteractionSubmitResult.failure("This interaction requires a native hook response")
            interactionSubmitErrors[sessionId] = result.error
            return result
        }

        let result = await SessionInteractionSubmitter.shared.submit(
            interaction: interaction,
            responses: responses,
            session: session
        )

        if result.succeeded,
           let permission = session.activePermission,
           interaction.toolUseId == permission.toolUseId,
           let decisionId = responses.first?.option.id {
            switch decisionId {
            case "allow":
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
                )
            case "deny":
                await SessionStore.shared.process(
                    .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: nil)
                )
            default:
                break
            }
        }

        if let error = result.error {
            interactionSubmitErrors[sessionId] = error
        }

        return result
    }

    func clearInteractionSubmitError(sessionId: String) {
        interactionSubmitErrors.removeValue(forKey: sessionId)
    }

    func focusSession(sessionId: String) async -> Bool {
        guard let session = await SessionStore.shared.session(for: sessionId) else {
            return false
        }

        return await focusSessionWindow(session)
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    private func hookDecision(from optionId: String?) -> String? {
        switch optionId {
        case "allow":
            return "allow"
        case "deny":
            return "deny"
        default:
            return nil
        }
    }

    private func submitPermissionDecision(
        sessionId: String,
        decisionId: String,
        reason: String? = nil
    ) async -> InteractionSubmitResult {
        guard let session = await SessionStore.shared.session(for: sessionId),
              let permission = session.activePermission,
              let interaction = SessionInteractionRequest.from(
                permission: permission,
                sessionId: session.sessionId,
                agentId: session.agentId,
                submitMode: SessionInteractionRequest.submitMode(isInTmux: session.isInTmux, tty: session.tty)
              ),
              let question = interaction.questions.first,
              let option = question.options.first(where: { $0.id == decisionId }) else {
            return .failure("No pending permission found")
        }

        if interaction.transportPreference == .programmaticOnly,
           let decision = hookDecision(from: decisionId) {
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: decision,
                reason: reason
            )

            switch decision {
            case "allow":
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
                )
            case "deny":
                await SessionStore.shared.process(
                    .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
                )
            default:
                break
            }

            return .success(via: .hookSocket)
        }

        let result = await SessionInteractionSubmitter.shared.submit(
            interaction: interaction,
            responses: [InteractionResponse(questionId: question.id, option: option)],
            session: session
        )

        if result.succeeded {
            switch decisionId {
            case "allow":
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
                )
            case "deny":
                await SessionStore.shared.process(
                    .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
                )
            default:
                break
            }
        }

        if let error = result.error {
            interactionSubmitErrors[sessionId] = error
        }

        return result
    }

    private func focusSessionWindow(_ session: SessionState) async -> Bool {
        if session.isInTmux {
            if let pid = session.pid,
               await YabaiController.shared.focusWindow(forClaudePid: pid) {
                return true
            }

            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                return true
            }
        }

        guard let pid = session.pid else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(hostApp.activationPID)) else {
            return false
        }

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
