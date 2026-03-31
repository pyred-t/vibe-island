//
//  HostApplicationResolver.swift
//  ClaudeIsland
//
//  Resolves the user-facing host application for an agent process.
//

import AppKit
import Foundation

struct HostApplicationInfo: Sendable {
    let displayName: String
    let bundleIdentifier: String?
    let appURL: URL?
    let activationPID: Int
}

struct HostApplicationResolver: Sendable {
    nonisolated static let shared = HostApplicationResolver()

    private nonisolated init() {}

    nonisolated func resolveHostApplication(forProcess pid: Int, tree: [Int: ProcessInfo]) -> HostApplicationInfo? {
        let candidatePids = collectCandidatePids(forProcess: pid, tree: tree)

        for candidatePid in candidatePids {
            if let resolved = resolveRunningApplication(for: candidatePid) {
                return resolved
            }
        }

        if let fallbackPid = candidatePids.first(where: { tree[$0]?.command != nil }),
           let command = tree[fallbackPid]?.command {
            return HostApplicationInfo(
                displayName: TerminalAppRegistry.displayName(localizedName: nil, command: command),
                bundleIdentifier: nil,
                appURL: nil,
                activationPID: fallbackPid
            )
        }

        return nil
    }

    private nonisolated func collectCandidatePids(forProcess pid: Int, tree: [Int: ProcessInfo]) -> [Int] {
        var current = pid
        var depth = 0
        var candidates: [Int] = []
        var seen = Set<Int>()

        while current > 1 && depth < 20 {
            guard let info = tree[current] else { break }

            if shouldInspectAsHostCandidate(pid: current, process: info),
               seen.insert(current).inserted {
                candidates.append(current)
            }

            current = info.ppid
            depth += 1
        }

        if let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
           seen.insert(terminalPid).inserted {
            candidates.append(terminalPid)
        }

        if seen.insert(pid).inserted {
            candidates.append(pid)
        }

        return candidates
    }

    private nonisolated func shouldInspectAsHostCandidate(pid: Int, process: ProcessInfo) -> Bool {
        if NSRunningApplication(processIdentifier: pid_t(pid)) != nil {
            return true
        }

        return TerminalAppRegistry.isTerminal(process.command)
    }

    private nonisolated func resolveRunningApplication(for pid: Int) -> HostApplicationInfo? {
        guard let runningApp = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return nil
        }

        let originalBundleURL = runningApp.bundleURL?.standardizedFileURL
        let appURL = TerminalAppRegistry.topLevelApplicationURL(from: originalBundleURL)
        let topLevelBundleURL = appURL ?? originalBundleURL
        let topLevelBundle = topLevelBundleURL.flatMap(Bundle.init(url:))
        let bundleIdentifier = topLevelBundle?.bundleIdentifier ?? runningApp.bundleIdentifier

        let preferredName = topLevelBundleURL.flatMap(TerminalAppRegistry.bundleDisplayName(for:))
            ?? runningApp.localizedName
        let displayName = TerminalAppRegistry.displayName(
            bundleIdentifier: bundleIdentifier,
            bundleURL: topLevelBundleURL,
            localizedName: preferredName,
            command: nil
        )

        let activationPID = resolveActivationPID(
            originalApp: runningApp,
            bundleIdentifier: bundleIdentifier,
            appURL: topLevelBundleURL
        )

        return HostApplicationInfo(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            appURL: topLevelBundleURL,
            activationPID: activationPID
        )
    }

    private nonisolated func resolveActivationPID(
        originalApp: NSRunningApplication,
        bundleIdentifier: String?,
        appURL: URL?
    ) -> Int {
        let runningApps = NSWorkspace.shared.runningApplications

        if let appURL {
            let standardizedAppURL = appURL.standardizedFileURL
            if let matched = runningApps.first(where: { candidate in
                candidate.bundleURL?.standardizedFileURL == standardizedAppURL
            }) {
                return Int(matched.processIdentifier)
            }
        }

        if let bundleIdentifier {
            let appURL = appURL?.standardizedFileURL
            let matchedByBundle = runningApps.first { candidate in
                guard candidate.bundleIdentifier == bundleIdentifier else { return false }
                if let appURL {
                    return candidate.bundleURL?.standardizedFileURL == appURL
                }
                return true
            }
            if let matchedByBundle {
                return Int(matchedByBundle.processIdentifier)
            }
        }

        return Int(originalApp.processIdentifier)
    }
}
