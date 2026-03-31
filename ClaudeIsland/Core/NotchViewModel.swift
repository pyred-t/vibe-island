//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

private let defaultInteractionPopDuration: TimeInterval = 12.0

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published var interactionPopQueue: [InteractionPopState] = []
    @Published var activeInteractionPop: InteractionPopState?
    @Published var pendingExpandedSessionId: String?
    @Published var pendingScrollToSessionId: String?
    @Published private(set) var interactionQuestionProgress: [String: Int] = [:]

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Compact size for settings menu
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 420 + screenSelector.expandedPickerHeight + soundSelector.expandedPickerHeight
            )
        case .instances:
            return CGSize(
                width: min(screenRect.width * 0.58, 720),
                height: 360
            )
        }
    }

    var interactionPopSize: CGSize {
        CGSize(
            width: min(screenRect.width * 0.54, 620),
            height: 252
        )
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?
    private var interactionPopDismissTask: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        // Start hover timer to auto-expand after 1 second
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isHovering else { return }
                self.notchOpen(reason: .hover)
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        dismissActiveInteractionPop(advanceQueue: false)
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    func enqueueInteractionPop(
        for sessionId: String,
        interaction: SessionInteractionRequest,
        duration: TimeInterval = defaultInteractionPopDuration
    ) {
        let popState = InteractionPopState(
            sessionId: sessionId,
            interaction: interaction,
            createdAt: Date()
        )

        let interactionId = interaction.id
        if activeInteractionPop?.interaction.id == interactionId {
            return
        }
        if interactionPopQueue.contains(where: { $0.interaction.id == interactionId }) {
            return
        }

        interactionPopQueue.append(popState)
        pendingExpandedSessionId = sessionId
        pendingScrollToSessionId = sessionId

        if activeInteractionPop == nil {
            advanceInteractionPopQueue(duration: duration)
        }
    }

    func advanceInteractionPopQueue(duration: TimeInterval = 5.0) {
        interactionPopDismissTask?.cancel()

        guard !interactionPopQueue.isEmpty else {
            activeInteractionPop = nil
            interactionPopDismissTask = nil
            if status == .popping {
                status = .closed
            }
            return
        }

        let nextPop = interactionPopQueue.removeFirst()
        activeInteractionPop = nextPop

        if status != .opened {
            openReason = .notification
            status = .popping
        }

        let dismissTask = DispatchWorkItem { [weak self] in
            self?.dismissActiveInteractionPop()
        }
        interactionPopDismissTask = dismissTask
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissTask)
    }

    func clearInteractionPop() {
        interactionPopQueue.removeAll()
        dismissActiveInteractionPop(advanceQueue: false)
    }

    func dismissActiveInteractionPop(advanceQueue: Bool = true) {
        interactionPopDismissTask?.cancel()
        interactionPopDismissTask = nil
        activeInteractionPop = nil

        guard advanceQueue, !interactionPopQueue.isEmpty else {
            if status == .popping {
                status = .closed
            }
            return
        }

        advanceInteractionPopQueue()
    }

    func clearInteraction(for sessionId: String, interactionId: String? = nil) {
        if activeInteractionPop?.sessionId == sessionId,
           interactionId == nil || activeInteractionPop?.interaction.id == interactionId {
            dismissActiveInteractionPop()
        }

        interactionPopQueue.removeAll { popState in
            popState.sessionId == sessionId &&
                (interactionId == nil || popState.interaction.id == interactionId)
        }

        if pendingExpandedSessionId == sessionId {
            pendingExpandedSessionId = nil
        }
        if pendingScrollToSessionId == sessionId {
            pendingScrollToSessionId = nil
        }

        if let interactionId {
            interactionQuestionProgress.removeValue(forKey: interactionId)
        }
    }

    func pruneInteractionQueue(validInteractionIds: Set<String>) {
        if let activeInteractionPop,
           !validInteractionIds.contains(activeInteractionPop.interaction.id) {
            dismissActiveInteractionPop()
        }

        interactionPopQueue.removeAll { !validInteractionIds.contains($0.interaction.id) }
        interactionQuestionProgress = interactionQuestionProgress.filter { validInteractionIds.contains($0.key) }
    }

    func currentQuestionIndex(for interactionId: String, totalQuestions: Int) -> Int {
        min(max(interactionQuestionProgress[interactionId] ?? 0, 0), max(totalQuestions - 1, 0))
    }

    func advanceInteractionQuestion(for interactionId: String, totalQuestions: Int) -> Bool {
        let currentIndex = currentQuestionIndex(for: interactionId, totalQuestions: totalQuestions)
        let nextIndex = currentIndex + 1

        guard nextIndex < totalQuestions else {
            interactionQuestionProgress.removeValue(forKey: interactionId)
            return false
        }

        interactionQuestionProgress[interactionId] = nextIndex
        return true
    }

    func consumePendingExpandedSession() {
        pendingExpandedSessionId = nil
    }

    func consumePendingScrollTarget() {
        pendingScrollToSessionId = nil
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
