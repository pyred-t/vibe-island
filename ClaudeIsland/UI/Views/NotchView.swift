//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousChoiceInteractionIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var compactSessionCountMeasuredWidth: CGFloat = 0

    /// The agent whose accent color should drive the compact header UI.
    private var activeAgentId: String? {
        let activeSession = sessionMonitor.instances
            .filter { $0.phase == .processing || $0.phase == .compacting || $0.phase.isWaitingForApproval || $0.phase == .waitingForInput }
            .max { $0.lastActivity < $1.lastActivity }

        return activeSession?.agentId ?? AgentRegistry.shared.primaryAgentId
    }

    private var activeAgentAccentColor: Color {
        TerminalColors.agentAccent(for: activeAgentId)
    }

    private var sessionCount: Int {
        sessionMonitor.instances.count
    }

    private var showingInteractionPop: Bool {
        viewModel.status == .popping && viewModel.activeInteractionPop != nil
    }

    private var showClosedSessionSummary: Bool {
        viewModel.status != .opened && sessionCount > 0
    }

    private var compactSessionSummaryRequiredWidth: CGFloat {
        let measuredLabelWidth = max(compactSessionCountMeasuredWidth, 320)
        return 36 + 6 + 24 + measuredLabelWidth + 28
    }

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        let sessionSummaryExpansionWidth: CGFloat = showClosedSessionSummary
            ? max(0, compactSessionSummaryRequiredWidth - closedNotchSize.width)
            : 0

        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
                return max(baseWidth + permissionIndicatorWidth, sessionSummaryExpansionWidth)
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return max(2 * max(0, closedNotchSize.height - 12) + 20 + permissionIndicatorWidth, sessionSummaryExpansionWidth)
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return max(2 * max(0, closedNotchSize.height - 12) + 20, sessionSummaryExpansionWidth)
        }

        return sessionSummaryExpansionWidth
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return showingInteractionPop ? viewModel.interactionPopSize : closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    private var notchContainer: some View {
        let isExpandedSurface = viewModel.status == .opened || showingInteractionPop
        let contentWidth = isExpandedSurface ? notchSize.width : closedContentWidth
        let horizontalInset = isExpandedSurface ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.bottom
        let bottomInset: CGFloat = isExpandedSurface ? 12 : 0
        let surfaceWidth = contentWidth + (horizontalInset * 2)
        let shadowColor = (isExpandedSurface || isHovering) ? Color.black.opacity(0.7) : .clear
        let notchAnimation = isExpandedSurface ? openAnimation : closeAnimation

        return notchLayout
            .frame(
                width: contentWidth,
                alignment: .top
            )
            .padding(.horizontal, horizontalInset)
            .padding(.bottom, bottomInset)
            .background(.black)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .shadow(
                color: shadowColor,
                radius: 6
            )
            .frame(
                width: surfaceWidth,
                height: isExpandedSurface ? notchSize.height : nil,
                alignment: .top
            )
            .animation(notchAnimation, value: viewModel.status)
            .animation(openAnimation, value: notchSize) // Animate container size changes between content types
            .animation(.smooth, value: activityCoordinator.expandingActivity)
            .animation(.smooth, value: hasPendingPermission)
            .animation(.smooth, value: hasWaitingForInput)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                    isHovering = hovering
                }
            }
            .onTapGesture {
                if !showingInteractionPop && viewModel.status != .opened {
                    viewModel.notchOpen(reason: .click)
                }
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchContainer
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
            handleChoiceInteractionsChange(instances)
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened || showingInteractionPop {
                overlayContentView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        Group {
            if viewModel.status == .opened {
                openedHeaderContent
            } else if showingInteractionPop {
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else if showClosedSessionSummary {
                HStack(spacing: 0) {
                    ClaudeCrabIcon(size: 18, color: activeAgentAccentColor, animateLegs: isAnyProcessing)
                        .frame(width: 36, height: closedNotchSize.height)
                        .padding(.leading, 6)

                    Spacer(minLength: 12)

                    CompactSessionCountView(count: sessionCount)
                        .readWidth { width in
                            if abs(width - compactSessionCountMeasuredWidth) > 0.5 {
                                compactSessionCountMeasuredWidth = width
                            }
                        }
                        .padding(.trailing, 14)
                }
            } else {
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: closedNotchSize.height,
            maxHeight: closedNotchSize.height,
            alignment: .leading
        )
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var overlayContentView: some View {
        Group {
            if showingInteractionPop, let popState = viewModel.activeInteractionPop {
                InteractionPopView(
                    session: sessionMonitor.instances.first(where: { $0.sessionId == popState.sessionId }),
                    interaction: popState.interaction,
                    isSubmitting: sessionMonitor.submittingInteractionSessionIds.contains(popState.sessionId),
                    submitError: sessionMonitor.interactionSubmitErrors[popState.sessionId],
                    onSubmitResponses: { responses in
                        handleInteractionResponseSelection(sessionId: popState.sessionId, interaction: popState.interaction, responses: responses)
                    },
                    onOpenHostApp: {
                        Task {
                            _ = await sessionMonitor.focusSession(sessionId: popState.sessionId)
                        }
                    },
                    onOpenSession: {
                        if let session = sessionMonitor.instances.first(where: { $0.sessionId == popState.sessionId }) {
                            viewModel.notchOpen(reason: .click)
                            viewModel.contentType = .instances
                            viewModel.pendingExpandedSessionId = session.sessionId
                            viewModel.pendingScrollToSessionId = session.sessionId
                        }
                    }
                )
            } else {
                switch viewModel.contentType {
                case .instances:
                    AgentInstancesView(
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                case .menu:
                    NotchMenuView(viewModel: viewModel)
                case .chat(let session):
                    ChatView(
                        sessionId: session.sessionId,
                        initialSession: session,
                        sessionMonitor: sessionMonitor,
                        viewModel: viewModel
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed && viewModel.hasPhysicalNotch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handleChoiceInteractionsChange(_ instances: [SessionState]) {
        let activeInteractions = instances.compactMap { session -> SessionInteractionRequest? in
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
        let currentIds = Set(activeInteractions.map(\.id))
        let newIds = currentIds.subtracting(previousChoiceInteractionIds)

        let newInteractions = activeInteractions
            .filter { newIds.contains($0.id) }
            .sorted(by: { $0.createdAt < $1.createdAt })

        for interaction in newInteractions {
            viewModel.enqueueInteractionPop(for: interaction.sessionId, interaction: interaction)
        }

        viewModel.pruneInteractionQueue(validInteractionIds: currentIds)

        previousChoiceInteractionIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        _ = await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }

    private func handleInteractionOptionSelection(
        sessionId: String,
        interaction: SessionInteractionRequest,
        option: InteractionOption
    ) {
        handleInteractionResponseSelection(
            sessionId: sessionId,
            interaction: interaction,
            responses: [InteractionResponse(questionId: interaction.questions.first?.id ?? "question-0", option: option)]
        )
    }

    private func handleInteractionResponseSelection(
        sessionId: String,
        interaction: SessionInteractionRequest,
        responses: [InteractionResponse]
    ) {
        guard let session = sessionMonitor.instances.first(where: { $0.sessionId == sessionId }) else {
            return
        }

        Task {
            let result = await sessionMonitor.submitInteraction(sessionId: session.sessionId, responses: responses)
            if result.succeeded {
                await MainActor.run {
                    viewModel.clearInteraction(for: sessionId, interactionId: interaction.id)
                }
            }
        }
    }
}

private struct InteractionPopView: View {
    let session: SessionState?
    let interaction: SessionInteractionRequest
    let isSubmitting: Bool
    let submitError: String?
    let onSubmitResponses: ([InteractionResponse]) -> Void
    let onOpenHostApp: () -> Void
    let onOpenSession: () -> Void

    @State private var selections: [String: InteractionOption] = [:]
    @State private var currentQuestionIndex = 0

    private var accentColor: Color {
        TerminalColors.agentAccent(for: session?.agentId)
    }

    private var currentQuestion: InteractionQuestion? {
        guard !interaction.questions.isEmpty else { return nil }
        return interaction.questions[min(currentQuestionIndex, interaction.questions.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.28), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    ClaudeCrabIcon(size: 18, color: accentColor, animateLegs: false)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session?.displayTitle ?? "Pending interaction")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(AgentRegistry.shared.shortDisplayName(for: session?.agentId))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(accentColor.opacity(0.95))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(accentColor.opacity(0.14))
                            )
                    }

                    Text(interaction.title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(0.6)

                    if interaction.isMultiQuestion {
                        Text("Question \(min(currentQuestionIndex + 1, interaction.questions.count)) of \(interaction.questions.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.42))
                    }
                }

                Spacer(minLength: 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(interaction.submitMode == .focusOnly ? "Selecting an option will bring the original host app forward." : "Select an option directly from the island.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.48))
                    .lineLimit(2)

                if let submitError {
                    Text(submitError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.88))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.05))
            )

            VStack(alignment: .leading, spacing: 10) {
                if let question = currentQuestion {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.question)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(2)

                        HStack(spacing: 10) {
                            ForEach(question.options) { option in
                                if option.role == .bypass {
                                    BypassOptionButton(
                                        option: option,
                                        onConfirm: { handleSelection(option, for: question) },
                                        fontSize: 12,
                                        verticalPadding: 11,
                                        cornerRadius: 12
                                    )
                                } else {
                                    Button {
                                        handleSelection(option, for: question)
                                    } label: {
                                        Text(option.label)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(foregroundColor(for: option.role))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 11)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(backgroundColor(for: option.role, isSelected: selections[question.id]?.id == option.id))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
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
                    HStack(spacing: 10) {
                        if currentQuestionIndex > 0 {
                            Button {
                                currentQuestionIndex -= 1
                            } label: {
                                Text("Back")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white.opacity(0.88))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.white.opacity(0.08))
                                    )
                            }
                            .buttonStyle(.plain)
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
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.black.opacity(0.9))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.white.opacity(0.92))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    onOpenSession()
                } label: {
                    Text("Open in sessions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                if submitError != nil {
                    Button {
                        onOpenHostApp()
                    } label: {
                        Text("Open host app")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.09), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
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
            return Color.white.opacity(0.22)
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
