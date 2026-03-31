//
//  TerminalAppRegistry.swift
//  ClaudeIsland
//
//  Centralized registry of known terminal applications
//

import Foundation

/// Registry of known terminal application names and bundle identifiers
struct TerminalAppRegistry: Sendable {
    private static let helperSuffixSeparators = [
        " Helper",
        " Renderer",
        " GPU",
        " Plugin"
    ]

    /// Terminal app names for process matching
    static let appNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Ghostty",
        "Alacritty",
        "kitty",
        "Hyper",
        "Warp",
        "WezTerm",
        "Tabby",
        "Rio",
        "Contour",
        "foot",
        "st",
        "urxvt",
        "xterm",
        "Code",           // VS Code
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "zed"
    ]

    /// Bundle identifiers for terminal apps (for window enumeration)
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed"
    ]

    /// Check if an app name or command path is a known terminal
    static func isTerminal(_ appNameOrCommand: String) -> Bool {
        let lower = appNameOrCommand.lowercased()

        // Check if any known app name is contained in the command (case-insensitive)
        for name in appNames {
            if lower.contains(name.lowercased()) {
                return true
            }
        }

        // Additional checks for common patterns
        return lower.contains("terminal") || lower.contains("iterm")
    }

    /// Check if a bundle identifier is a known terminal
    static func isTerminalBundle(_ bundleId: String) -> Bool {
        bundleIdentifiers.contains(bundleId)
    }

    /// Whether a process/app name looks like an Electron/Chromium helper instead of the real host app.
    static func isIntermediateAppName(_ rawName: String) -> Bool {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lower = normalized.lowercased()
        return lower.contains("helper")
            || lower.contains("renderer")
            || lower.contains("gpu")
            || lower.contains("plugin")
    }

    /// Whether a bundle URL points inside a nested helper app.
    static func isIntermediateBundleURL(_ bundleURL: URL) -> Bool {
        let path = bundleURL.path.lowercased()
        return path.contains("/contents/frameworks/")
            || path.contains("/contents/helpers/")
            || path.contains("/helpers/")
    }

    /// Walk upward from a nested helper bundle to the outermost `.app`.
    static func topLevelApplicationURL(from bundleURL: URL?) -> URL? {
        guard let bundleURL else { return nil }

        let standardized = bundleURL.standardizedFileURL
        let components = standardized.pathComponents

        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return standardized
        }

        let appPath = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
        return URL(fileURLWithPath: appPath)
    }

    /// Convert a localized app name or process command into a human-readable host app label.
    static func displayName(localizedName: String?, command: String?) -> String {
        displayName(bundleIdentifier: nil, bundleURL: nil, localizedName: localizedName, command: command)
    }

    /// Convert bundle metadata or fallback process info into a human-readable host app label.
    static func displayName(
        bundleIdentifier: String?,
        bundleURL: URL?,
        localizedName: String?,
        command: String?
    ) -> String {
        if let bundleIdentifier, let knownName = knownDisplayName(forBundleIdentifier: bundleIdentifier) {
            return knownName
        }

        if let bundleURL,
           let bundleName = bundleDisplayName(for: bundleURL) {
            return normalizedDisplayName(bundleName)
        }

        if let localizedName {
            let normalized = normalizedDisplayName(localizedName)
            if normalized != localizedName || isTerminal(localizedName) {
                return normalized
            }
        }

        if let command {
            let processName = URL(fileURLWithPath: command).lastPathComponent
            let normalized = normalizedDisplayName(processName)
            if normalized != processName || isTerminal(processName) {
                return normalized
            }
        }

        return "Unknown App"
    }

    /// Resolve a bundle's UI-facing display name from Info.plist.
    static func bundleDisplayName(for bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }

        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let fallback = bundleURL.deletingPathExtension().lastPathComponent
        return fallback.isEmpty ? nil : fallback
    }

    private static func knownDisplayName(forBundleIdentifier bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "com.microsoft.VSCode":
            return "Visual Studio Code"
        case "com.microsoft.VSCodeInsiders":
            return "Visual Studio Code Insiders"
        default:
            return nil
        }
    }

    /// Normalize internal process/app names into UI-facing labels.
    static func normalizedDisplayName(_ rawName: String) -> String {
        let cleaned = strippedHelperDecorations(from: rawName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "")

        guard !cleaned.isEmpty else { return "Unknown App" }

        switch cleaned {
        case "Warp-Stable", "Warp":
            return "Warp"
        case "Code":
            return "Visual Studio Code"
        case "Code - Insiders":
            return "Visual Studio Code Insiders"
        case "Cursor":
            return "Cursor"
        case "Windsurf":
            return "Windsurf"
        case "Zed", "zed":
            return "Zed"
        case "iTerm", "iTerm2":
            return "iTerm"
        default:
            return cleaned
        }
    }

    private static func strippedHelperDecorations(from rawName: String) -> String {
        var cleaned = rawName
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: "\\s*\\([^\\)]*(Renderer|GPU|Plugin)[^\\)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for separator in helperSuffixSeparators {
            if let range = cleaned.range(of: separator, options: [.caseInsensitive, .backwards]) {
                cleaned = String(cleaned[..<range.lowerBound])
                break
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
