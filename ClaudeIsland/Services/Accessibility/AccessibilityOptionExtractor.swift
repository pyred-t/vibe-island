//
//  AccessibilityOptionExtractor.swift
//  ClaudeIsland
//
//  Reads visible terminal text via macOS Accessibility APIs to supplement
//  hook event data with the actual rendered prompt text.
//
//  Supported terminals:
//  - Terminal.app (AXScrollArea > AXTextArea with kAXValueAttribute)
//  - iTerm2 (AXGroup > AXTextArea)
//
//  Unsupported (GPU-rendered, no AX text):
//  - Alacritty, Kitty, WezTerm
//

import ApplicationServices
import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Accessibility")

/// Attempts to read visible terminal text via macOS Accessibility APIs.
/// Used as an opportunistic enrichment layer — falls back silently when unavailable.
struct AccessibilityOptionExtractor {
    static let shared = AccessibilityOptionExtractor()

    /// Bundle IDs known to expose terminal text content via AX APIs.
    private static let supportedTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]

    /// Maximum characters to return from the tail of terminal text.
    private static let maxTailLength = 1000

    /// Maximum AX tree depth to walk when searching for text elements.
    private static let maxTreeDepth = 8

    private init() {}

    // MARK: - Public API

    /// Try to read the tail of the visible terminal text for a session.
    /// Returns nil if accessibility is unavailable or unsupported for the host app.
    func extractVisibleText(for session: SessionState) -> String? {
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility not trusted — skipping text extraction")
            return nil
        }
        guard let pid = session.pid else { return nil }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(
            forProcess: pid, tree: tree
        ) else {
            logger.debug("Could not resolve host app for pid \(pid)")
            return nil
        }

        // Only attempt extraction for terminals known to expose AX text
        if let bundleId = hostApp.bundleIdentifier,
           !Self.supportedTerminals.contains(bundleId) {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid_t(hostApp.activationPID))

        guard let textContent = findTextContent(in: appElement, maxDepth: Self.maxTreeDepth) else {
            logger.debug("No AX text content found for \(hostApp.displayName)")
            return nil
        }

        // Return the tail — the prompt region is at the end of terminal output
        if textContent.count > Self.maxTailLength {
            return String(textContent.suffix(Self.maxTailLength))
        }
        return textContent
    }

    /// Quick check: is AX text extraction likely to work for this session?
    func isAvailable(for session: SessionState) -> Bool {
        guard AXIsProcessTrusted(), let pid = session.pid else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(
            forProcess: pid, tree: tree
        ) else { return false }

        if let bundleId = hostApp.bundleIdentifier {
            return Self.supportedTerminals.contains(bundleId)
        }
        return false
    }

    // MARK: - AX Tree Walking

    /// Recursively search the AX element tree for text-bearing elements.
    /// Searches children in reverse since text areas tend to be later in the tree.
    private func findTextContent(in element: AXUIElement, maxDepth: Int) -> String? {
        guard maxDepth > 0 else { return nil }

        // Check if this element has a text value
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXStaticTextRole {
            var valueRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let text = valueRef as? String, !text.isEmpty {
                return text
            }
        }

        // Recurse into children
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        // Search in reverse — text areas tend to be later in the tree
        for child in children.reversed() {
            if let text = findTextContent(in: child, maxDepth: maxDepth - 1) {
                return text
            }
        }

        return nil
    }
}
