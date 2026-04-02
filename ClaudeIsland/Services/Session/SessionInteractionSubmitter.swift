//
//  SessionInteractionSubmitter.swift
//  ClaudeIsland
//
//  Unified direct-submission pipeline for session interactions.
//

import AppKit
import ApplicationServices
import Foundation

actor SessionInteractionSubmitter {
    static let shared = SessionInteractionSubmitter()

    private init() {}

    func submit(
        interaction: SessionInteractionRequest,
        responses: [InteractionResponse],
        session: SessionState
    ) async -> InteractionSubmitResult {
        if interaction.sourceAgent == "codex" {
            if interaction.responseCapability == .keyboardFallbackAvailable {
                return await submitCodexViaKeyboardFallback(
                    interaction: interaction,
                    responses: responses,
                    session: session
                )
            }
            return .failure("Codex interactions must resolve through the hook socket; refusing terminal text injection")
        }

        if interaction.transportPreference == .programmaticOnly {
            return .failure("This interaction must be handled programmatically")
        }

        let messages = submissionMessages(for: interaction, responses: responses)
        guard !messages.isEmpty else {
            return .failure("No answers to submit")
        }

        var failures: [InteractionSubmitResult] = []
        let allowAccessibilityInjection = canUseAccessibilityInjection(for: session)

        if let tmuxResult = await submitViaTmuxIfPossible(session: session, messages: messages) {
            if tmuxResult.succeeded {
                return tmuxResult
            }
            failures.append(tmuxResult)
        }

        if let ttyResult = await submitViaTTYIfPossible(session: session, messages: messages) {
            if ttyResult.succeeded {
                return ttyResult
            }
            failures.append(ttyResult)
        }

        if allowAccessibilityInjection {
            let accessibilityResult = await submitViaAccessibilityIfPossible(session: session, messages: messages)
            if accessibilityResult.succeeded {
                return accessibilityResult
            }
            failures.append(accessibilityResult)
        }

        return failures.last ?? .failure("Failed to submit interaction")
    }

    private func submitCodexViaKeyboardFallback(
        interaction: SessionInteractionRequest,
        responses: [InteractionResponse],
        session: SessionState
    ) async -> InteractionSubmitResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission missing", transport: .keyboardFallback)
        }

        guard interaction.questions.count == 1,
              responses.count == 1,
              let question = interaction.questions.first,
              let response = responses.first,
              response.questionId == question.id,
              let optionIndex = question.options.firstIndex(where: { $0.id == response.option.id }) else {
            return .failure(
                "Codex keyboard fallback currently supports one visible question and one selected option",
                transport: .keyboardFallback
            )
        }

        let focused = await focusCodexHostApp(for: session)
        guard focused else {
            return .failure("Failed to focus the Codex terminal", transport: .keyboardFallback)
        }

        try? await Task.sleep(for: .milliseconds(180))

        guard postUnicodeString(String(optionIndex + 1)) else {
            return .failure("Failed to send option key to Codex terminal", transport: .keyboardFallback)
        }

        try? await Task.sleep(for: .milliseconds(60))

        guard postReturnKey() else {
            return .failure("Failed to submit selected option in Codex terminal", transport: .keyboardFallback)
        }

        return .submittedPendingConfirmation(via: .keyboardFallback)
    }

    private func canUseAccessibilityInjection(for session: SessionState) -> Bool {
        guard let pid = session.pid else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(forProcess: pid, tree: tree) else {
            return false
        }

        if let bundleIdentifier = hostApp.bundleIdentifier {
            return !TerminalAppRegistry.isTerminalBundle(bundleIdentifier)
        }

        return !TerminalAppRegistry.isTerminal(hostApp.displayName)
    }

    private func focusCodexHostApp(for session: SessionState) async -> Bool {
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

        return await MainActor.run {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private func submissionMessages(
        for interaction: SessionInteractionRequest,
        responses: [InteractionResponse]
    ) -> [String] {
        responses.map { response in
            switch interaction.submissionEncoding {
            case .optionValue:
                return response.option.submissionValue
            case .optionLabel:
                return response.option.label
            }
        }
    }

    private func submitViaTmuxIfPossible(
        session: SessionState,
        messages: [String]
    ) async -> InteractionSubmitResult? {
        guard session.isInTmux,
              let tty = session.tty,
              let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")
                guard paneTty == tty, let tmuxTarget = TmuxTarget(from: target) else { continue }

                if await ToolApprovalHandler.shared.sendMessages(messages, to: tmuxTarget) {
                    return .success(via: .tmux)
                }

                return .failure("tmux send failed", transport: .tmux)
            }
        } catch {
            return .failure("tmux lookup failed", transport: .tmux)
        }

        return nil
    }

    private func submitViaTTYIfPossible(
        session: SessionState,
        messages: [String]
    ) async -> InteractionSubmitResult? {
        guard let tty = session.tty else {
            return nil
        }

        let ttyPath = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
        guard FileManager.default.fileExists(atPath: ttyPath) else {
            return .failure("TTY not found: \(ttyPath)", transport: .tty)
        }

        let payload = messages.joined(separator: "\n") + "\n"

        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: ttyPath))
            defer { try? handle.close() }

            guard let data = payload.data(using: .utf8) else {
                return .failure("Failed to encode message payload", transport: .tty)
            }

            try handle.write(contentsOf: data)
            return .success(via: .tty)
        } catch {
            return .failure("TTY write failed", transport: .tty)
        }
    }

    private func submitViaAccessibilityIfPossible(
        session: SessionState,
        messages: [String]
    ) async -> InteractionSubmitResult {
        guard AXIsProcessTrusted() else {
            return .failure("Accessibility permission missing", transport: .accessibilityInjection)
        }

        guard let pid = session.pid else {
            return .failure("No host app process available", transport: .accessibilityInjection)
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(hostApp.activationPID)) else {
            return .failure("Failed to resolve host app", transport: .accessibilityInjection)
        }

        let activated = await MainActor.run {
            app.activate(options: [.activateAllWindows])
        }
        guard activated else {
            return .failure("Failed to activate host app", transport: .accessibilityInjection)
        }

        try? await Task.sleep(for: .milliseconds(180))

        for (index, message) in messages.enumerated() {
            guard postUnicodeString(message) else {
                return .failure("Failed to inject text into host app", transport: .accessibilityInjection)
            }
            guard postReturnKey() else {
                return .failure("Failed to submit injected text", transport: .accessibilityInjection)
            }

            if index < messages.count - 1 {
                try? await Task.sleep(for: .milliseconds(140))
            }
        }

        return .success(via: .accessibilityInjection)
    }

    private func postUnicodeString(_ string: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16))
        keyUp.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16))
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func postReturnKey() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
