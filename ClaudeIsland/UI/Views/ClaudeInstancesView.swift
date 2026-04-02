//
//  AgentInstancesView.swift
//  ClaudeIsland
//
//  Instances list for all AI agents (Claude Code, Codex, Gemini CLI, etc.)
//

import AppKit
import Combine
import SwiftUI

struct AgentInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @State private var expandedSessionIds: Set<String> = []
    @State private var scheduledScrollSessionId: String?

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude, codex, or gemini")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let hasInteractionA = a.activeInteraction != nil
            let hasInteractionB = b.activeInteraction != nil
            if hasInteractionA != hasInteractionB {
                return hasInteractionA && !hasInteractionB
            }

            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(sortedInstances) { session in
                        AgentInstanceRow(
                            session: session,
                            isExpanded: expandedSessionIds.contains(session.sessionId),
                            isInteractionSubmitting: sessionMonitor.submittingInteractionSessionIds.contains(session.sessionId),
                            interactionSubmitError: sessionMonitor.interactionSubmitErrors[session.sessionId],
                            onShare: { shareSession(session) },
                            onChat: { openChat(session) },
                            onArchive: { archiveSession(session) },
                            onApprove: { approveSession(session) },
                            onReject: { rejectSession(session) },
                            onBypass: { bypassSession(session) },
                            onToggleExpanded: { toggleExpanded(sessionId: session.sessionId) },
                            onOpenHostApp: {
                                Task {
                                    _ = await sessionMonitor.focusSession(sessionId: session.sessionId)
                                }
                            },
                            onSubmitInteractionResponses: { responses in
                                handleInteractionResponseSelection(session: session, responses: responses)
                            }
                        )
                        .id(session.sessionId)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollBounceBehavior(.basedOnSize)
            .onAppear {
                handlePendingExpansionIfNeeded(with: proxy)
            }
            .onChange(of: viewModel.pendingExpandedSessionId) { _, _ in
                handlePendingExpansionIfNeeded(with: proxy)
            }
            .onChange(of: scheduledScrollSessionId) { _, sessionId in
                guard let sessionId else { return }
                performDeferredScroll(to: sessionId, with: proxy)
            }
            .onChange(of: sessionMonitor.instances) { _, _ in
                pruneExpandedSessions()
            }
        }
    }

    // MARK: - Actions

    private func shareSession(_ session: SessionState) {
        Task {
            let didFocus = await focusSessionWindow(session)
            if !didFocus {
                await MainActor.run {
                    openChat(session)
                }
            }
        }
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

        return activateHostApp(for: session)
    }

    private func activateHostApp(for session: SessionState) -> Bool {
        guard let pid = session.pid else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(hostApp.activationPID)) else {
            return false
        }

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func bypassSession(_ session: SessionState) {
        sessionMonitor.bypassPermission(sessionId: session.sessionId)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }

    private func toggleExpanded(sessionId: String) {
        if expandedSessionIds.contains(sessionId) {
            expandedSessionIds.remove(sessionId)
        } else {
            expandedSessionIds.insert(sessionId)
        }
    }

    private func pruneExpandedSessions() {
        let validIds = Set(sessionMonitor.instances.map(\.sessionId))
        expandedSessionIds = expandedSessionIds.intersection(validIds)
    }

    private func handlePendingExpansionIfNeeded(with proxy: ScrollViewProxy) {
        guard viewModel.contentType == .instances,
              let sessionId = viewModel.pendingExpandedSessionId else {
            return
        }

        let validIds = Set(sessionMonitor.instances.map(\.sessionId))
        guard validIds.contains(sessionId) else {
            viewModel.consumePendingExpandedSession()
            viewModel.consumePendingScrollTarget()
            return
        }

        expandedSessionIds.insert(sessionId)

        let scrollTarget = viewModel.pendingScrollToSessionId ?? sessionId
        scheduledScrollSessionId = scrollTarget
        viewModel.consumePendingExpandedSession()
        viewModel.consumePendingScrollTarget()
    }
    
    private func performDeferredScroll(to sessionId: String, with proxy: ScrollViewProxy) {
        let validIds = Set(sessionMonitor.instances.map(\.sessionId))
        guard validIds.contains(sessionId) else {
            scheduledScrollSessionId = nil
            return
        }

        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                proxy.scrollTo(sessionId, anchor: .center)
            }
            scheduledScrollSessionId = nil
        }
    }

    private func handleInteractionOptionSelection(session: SessionState, option: InteractionOption) {
        let questionId = session.activeInteraction?.questions.first?.id ?? "question-0"
        handleInteractionResponseSelection(
            session: session,
            responses: [InteractionResponse(questionId: questionId, option: option)]
        )
    }

    private func handleInteractionResponseSelection(session: SessionState, responses: [InteractionResponse]) {
        Task {
            let result = await sessionMonitor.submitInteraction(sessionId: session.sessionId, responses: responses)
            if result.confirmed {
                await MainActor.run {
                    expandedSessionIds.remove(session.sessionId)
                    if let interaction = session.activeInteraction {
                        viewModel.clearInteraction(for: session.sessionId, interactionId: interaction.id)
                    }
                }
            }
        }
    }
}

// MARK: - Instance Row

struct AgentInstanceRow: View {
    let session: SessionState
    let isExpanded: Bool
    let isInteractionSubmitting: Bool
    let interactionSubmitError: String?
    let onShare: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let onBypass: () -> Void
    let onToggleExpanded: () -> Void
    let onOpenHostApp: () -> Void
    let onSubmitInteractionResponses: ([InteractionResponse]) -> Void

    @State private var isHovered = false
    @State private var isYabaiAvailable = false

    /// Agent-specific accent color
    private var agentAccentColor: Color {
        TerminalColors.agentAccent(for: session.agentId)
    }

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    private var activeInteraction: SessionInteractionRequest? {
        if let interaction = session.activeInteraction {
            return interaction
        }

        guard let permission = session.activePermission else {
            return nil
        }

        return SessionInteractionRequest.from(
            permission: permission,
            sessionId: session.sessionId,
            agentId: session.agentId,
            submitMode: SessionInteractionRequest.submitMode(isInTmux: session.isInTmux, tty: session.tty)
        )
    }

    private var canSubmitInteractionDirectly: Bool {
        guard let interaction = activeInteraction else { return false }
        if interaction.sourceAgent == "codex" || interaction.sourceAgent == "gemini" || interaction.sourceAgent == "claude" {
            return interaction.canSubmitDirectly
        }
        return interaction.submitMode == .ttyInjection || interaction.submitMode == .programmatic
    }

    private var agentDisplayName: String {
        AgentRegistry.shared.shortDisplayName(for: session.agentId)
    }

    private var hostAppName: String {
        guard let pid = session.pid else { return "Unknown App" }

        let tree = ProcessTreeBuilder.shared.buildTree()
        return HostApplicationResolver.shared
            .resolveHostApplication(forProcess: pid, tree: tree)?
            .displayName ?? "Unknown App"
    }

    private var userPromptPreview: String {
        session.lastUserMessage ?? session.firstUserMessage ?? session.displayTitle
    }

    private var lastAssistantOutput: String? {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text), .thinking(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            default:
                continue
            }
        }

        guard session.lastMessageRole == "assistant" else { return nil }
        return session.lastMessage
    }

    private var lastVisibleToolCall: ToolCallItem? {
        for item in session.chatItems.reversed() {
            if case .toolCall(let tool) = item.type,
               tool.name != "Task" {
                return tool
            }
        }
        return nil
    }

    private var lastBashCommand: String? {
        for item in session.chatItems.reversed() {
            guard case .toolCall(let tool) = item.type else { continue }
            if tool.name == "Bash", let command = tool.input["command"], !command.isEmpty {
                return command
            }
        }

        if session.lastToolName == "Bash", let command = session.lastMessage, !command.isEmpty {
            return command
        }

        return nil
    }

    private var requestUserInputContext: String {
        interactionContextSummary ??
        lastBashCommand ??
        lastAssistantOutput ??
        session.pendingToolInput ??
        session.lastMessage ??
        "Needs your input"
    }

    private var interactionContextSummary: String? {
        guard let interaction = activeInteraction else { return nil }

        var parts: [String] = []
        let question = interaction.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty {
            parts.append(question)
        }

        let optionSummary = interaction.options
            .prefix(3)
            .map(\.label)
            .joined(separator: " · ")
        if !optionSummary.isEmpty {
            parts.append(optionSummary)
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " — ")
    }

    private var latestActionDisplay: ActionTextDisplay {
        if let permission = session.activePermission {
            if permission.toolName == "AskUserQuestion" || permission.toolName == "request_user_input" {
                return .highlighted(label: "request user input", detail: requestUserInputContext, color: TerminalColors.amber)
            }

            if permission.toolName == "Bash",
               let command = session.pendingToolInput,
               !command.isEmpty {
                return .highlighted(label: "Bash", detail: command, color: agentAccentColor)
            }

            if let input = session.pendingToolInput, !input.isEmpty {
                return .highlighted(
                    label: MCPToolFormatter.formatToolName(permission.toolName),
                    detail: input,
                    color: TerminalColors.amber
                )
            }

            return .highlighted(
                label: MCPToolFormatter.formatToolName(permission.toolName),
                detail: "waiting for approval",
                color: TerminalColors.amber
            )
        }

        if activeInteraction != nil {
            return .highlighted(label: "request user input", detail: requestUserInputContext, color: TerminalColors.amber)
        }

        if isWaitingForApproval, let toolName = session.pendingToolName {
            if toolName == "AskUserQuestion" {
                return .highlighted(label: "request user input", detail: requestUserInputContext, color: TerminalColors.amber)
            }

            if toolName == "Bash",
               let command = session.pendingToolInput,
               !command.isEmpty {
                return .highlighted(label: "Bash", detail: command, color: agentAccentColor)
            }

            if let input = session.pendingToolInput, !input.isEmpty {
                return .plain("\(MCPToolFormatter.formatToolName(toolName)): \(input)")
            }

            return .plain("\(MCPToolFormatter.formatToolName(toolName)): waiting for approval")
        }

        if let assistant = lastAssistantOutput, !assistant.isEmpty {
            return .plain(assistant)
        }

        if let tool = lastVisibleToolCall {
            if tool.name == "AskUserQuestion" {
                return .highlighted(label: "request user input", detail: requestUserInputContext, color: TerminalColors.amber)
            }

            if tool.name == "Bash", let command = tool.input["command"], !command.isEmpty {
                return .highlighted(label: "Bash", detail: command, color: agentAccentColor)
            }

            let preview = tool.inputPreview
            if !preview.isEmpty {
                return .plain("\(MCPToolFormatter.formatToolName(tool.name)): \(preview)")
            }

            return .plain(MCPToolFormatter.formatToolName(tool.name))
        }

        if session.phase == .waitingForInput {
            return .plain("Ready for your next message")
        }

        return .plain(session.lastMessage ?? "No recent agent action")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ClaudeCrabIcon(
                    size: 34,
                    color: agentAccentColor,
                    animateLegs: session.phase == .processing || session.phase == .compacting
                )
                .frame(width: 46, height: 62, alignment: .center)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer(minLength: 12)

                        Text(agentDisplayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(agentAccentColor.opacity(0.95))
                            .lineLimit(1)

                        Text(hostAppName)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.42))
                            .lineLimit(1)

                        actionControls
                    }

                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))

                            Text(userPromptPreview)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 10)
                    }

                    ActionLine(display: latestActionDisplay)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isExpanded, let interaction = activeInteraction {
                SessionInteractionCard(
                    interaction: interaction,
                    accentColor: agentAccentColor,
                    canSubmitDirectly: canSubmitInteractionDirectly,
                    isSubmitting: isInteractionSubmitting,
                    submitError: interactionSubmitError,
                    onSubmitResponses: onSubmitInteractionResponses,
                    onOpenHostApp: onOpenHostApp
                )
                .padding(.leading, 58)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        if let interaction = activeInteraction, interaction.kind == .singleChoice {
            HStack(spacing: 8) {
                TextActionPill(
                    label: isExpanded ? "Hide" : "Options\(session.pendingInteractionCount > 1 ? " (\(session.pendingInteractionCount))" : "")",
                    action: onToggleExpanded
                )

                TextActionPill(label: "Share", action: onShare)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            HStack(spacing: 8) {
                TextActionPill(label: "Share", action: onShare)

                if session.phase == .idle || session.phase == .waitingForInput {
                    TextActionPill(label: "Archive", action: onArchive)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

private struct SessionInteractionCard: View {
    let interaction: SessionInteractionRequest
    let accentColor: Color
    let canSubmitDirectly: Bool
    let isSubmitting: Bool
    let submitError: String?
    let onSubmitResponses: ([InteractionResponse]) -> Void
    let onOpenHostApp: () -> Void

    @State private var selections: [String: InteractionOption] = [:]
    @State private var currentQuestionIndex = 0

    private var currentQuestion: InteractionQuestion? {
        guard !interaction.questions.isEmpty else { return nil }
        return interaction.questions[min(currentQuestionIndex, interaction.questions.count - 1)]
    }

    private var interactionSubmitContext: String {
        switch interaction.responseCapability {
        case .nativeHookAvailable:
            return "Reply directly from island"
        case .keyboardFallbackAvailable:
            return "Reply via terminal keyboard fallback"
        case .directTextAvailable:
            return "Sent directly to the session"
        case .detectOnly:
            return "Detected options only; no submit channel is available"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Choose an option")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accentColor.opacity(0.95))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(accentColor.opacity(0.16))
                    )

                Text(interactionSubmitContext)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)

                if interaction.isMultiQuestion {
                    Spacer(minLength: 0)

                    Text("\(min(currentQuestionIndex + 1, interaction.questions.count))/\(interaction.questions.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            if let submitError {
                Text(submitError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.88))
            }

            if let question = currentQuestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.88))

                    HStack(spacing: 8) {
                        ForEach(question.options) { option in
                            if option.role == .bypass {
                                BypassOptionButton(
                                    option: option,
                                    onConfirm: { handleSelection(option, for: question) }
                                )
                            } else {
                                Button {
                                    handleSelection(option, for: question)
                                } label: {
                                    Text(option.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(foregroundColor(for: option.role))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(backgroundColor(for: option.role, isSelected: selections[question.id]?.id == option.id))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(borderColor(for: option.role, isSelected: selections[question.id]?.id == option.id), lineWidth: 0.8)
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(isSubmitting)
                            }
                        }
                    }
                }
            }

            if interaction.isMultiQuestion {
                HStack(spacing: 8) {
                    if currentQuestionIndex > 0 {
                        Button {
                            currentQuestionIndex -= 1
                        } label: {
                            Text("Back")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.84))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }

                    if let question = currentQuestion, selections[question.id] != nil {
                        Button {
                            if currentQuestionIndex == interaction.questions.count - 1 {
                                submitAllResponses()
                            } else {
                                currentQuestionIndex += 1
                            }
                        } label: {
                            Text(currentQuestionIndex == interaction.questions.count - 1 ? "Submit answers" : "Next question")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.black.opacity(0.9))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.9))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                }
            }

            if submitError != nil {
                Button {
                    onOpenHostApp()
                } label: {
                    Text("Open host app")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
        )
        .onChange(of: interaction.id) { _, _ in
            resetInteractionState()
        }
    }

    private func backgroundColor(for role: InteractionOptionRole, isSelected: Bool = false) -> Color {
        if isSelected {
            return accentColor.opacity(0.82)
        }
        switch role {
        case .primary:
            return Color.white.opacity(0.88)
        case .destructive:
            return Color(red: 0.76, green: 0.24, blue: 0.22)
        case .secondary:
            return Color.white.opacity(0.12)
        case .bypass:
            return TerminalColors.amber.opacity(0.12)
        }
    }

    private func foregroundColor(for role: InteractionOptionRole) -> Color {
        switch role {
        case .primary:
            return .black.opacity(0.9)
        case .destructive:
            return .white.opacity(0.96)
        case .secondary:
            return .white.opacity(0.82)
        case .bypass:
            return TerminalColors.amber
        }
    }

    private func borderColor(for role: InteractionOptionRole, isSelected: Bool = false) -> Color {
        if isSelected {
            return Color.white.opacity(0.24)
        }
        switch role {
        case .primary:
            return Color.white.opacity(0.16)
        case .destructive:
            return Color.white.opacity(0.08)
        case .secondary:
            return Color.white.opacity(0.14)
        case .bypass:
            return TerminalColors.amber.opacity(0.3)
        }
    }

    private func handleSelection(_ option: InteractionOption, for question: InteractionQuestion) {
        if interaction.isMultiQuestion {
            selections[question.id] = option
        } else {
            onSubmitResponses([InteractionResponse(questionId: question.id, option: option)])
        }
    }

    private func submitAllResponses() {
        onSubmitResponses(interaction.questions.compactMap { question in
            guard let option = selections[question.id] else { return nil }
            return InteractionResponse(questionId: question.id, option: option)
        })
    }

    private func resetInteractionState() {
        selections = [:]
        currentQuestionIndex = 0
    }
}

private enum ActionTextDisplay {
    case plain(String)
    case highlighted(label: String, detail: String, color: Color)
}

private struct ActionLine: View {
    let display: ActionTextDisplay

    var body: some View {
        switch display {
        case .plain(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
        case .highlighted(let label, let detail, let color):
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(color.opacity(0.14))
                    )

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }
}

struct TextActionPill: View {
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    init(label: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button {
            if isEnabled {
                action()
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.3) }
        return isHovered ? .white.opacity(0.92) : .white.opacity(0.68)
    }

    private var backgroundColor: Color {
        guard isEnabled else { return Color.white.opacity(0.03) }
        return isHovered ? Color.white.opacity(0.14) : Color.white.opacity(0.08)
    }

    private var borderColor: Color {
        guard isEnabled else { return Color.white.opacity(0.06) }
        return isHovered ? Color.white.opacity(0.22) : Color.white.opacity(0.12)
    }
}

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let onBypass: () -> Void

    @State private var showChatButton = false
    @State private var showBypassButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @State private var bypassConfirmMode = false
    @State private var bypassConfirmed = false

    var body: some View {
        HStack(spacing: 6) {
            if bypassConfirmMode {
                // Bypass confirmation - expanded
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        bypassConfirmed = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onBypass()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: bypassConfirmed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .medium))
                        Text(bypassConfirmed ? "Done" : "Confirm bypass")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(bypassConfirmed ? .white : .black.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(bypassConfirmed
                                ? TerminalColors.green.opacity(0.8)
                                : TerminalColors.amber.opacity(0.95))
                    )
                }
                .buttonStyle(.plain)
                .disabled(bypassConfirmed)
                .transition(.scale(scale: 0.85).combined(with: .opacity))

                if !bypassConfirmed {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            bypassConfirmMode = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(5)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            } else {
                TextActionPill(label: "Chat") {
                    onChat()
                }
                .opacity(showChatButton ? 1 : 0)
                .scaleEffect(showChatButton ? 1 : 0.8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))

                // Bypass pill
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        bypassConfirmMode = true
                    }
                } label: {
                    Text("Bypass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(TerminalColors.amber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(TerminalColors.amber.opacity(0.15))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(TerminalColors.amber.opacity(0.3), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .opacity(showBypassButton ? 1 : 0)
                .scaleEffect(showBypassButton ? 1 : 0.8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))

                TextActionPill(label: "Deny") {
                    onReject()
                }
                .opacity(showDenyButton ? 1 : 0)
                .scaleEffect(showDenyButton ? 1 : 0.8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))

                Button {
                    onApprove()
                } label: {
                    Text("Allow")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showAllowButton ? 1 : 0)
                .scaleEffect(showAllowButton ? 1 : 0.8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.03)) {
                showBypassButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}
