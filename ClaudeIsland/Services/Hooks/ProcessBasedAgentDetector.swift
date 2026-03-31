//
//  ProcessBasedAgentDetector.swift
//  ClaudeIsland
//
//  Process-based discovery and liveness monitoring for agent sessions.
//

import Darwin
import Foundation
import os.log

actor ProcessBasedAgentDetector {
    static let shared = ProcessBasedAgentDetector()

    private let logger = Logger(subsystem: "com.claudeisland", category: "ProcessDetector")
    private let pollIntervalSeconds: UInt64 = 2
    private var pollTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        logger.info("Process liveness detector started")

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: (self?.pollIntervalSeconds ?? 2) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        logger.info("Process liveness detector stopped")
    }

    private func poll() async {
        await discoverRunningSessions()

        let sessions = await SessionStore.shared.allSessions()
        for session in sessions {
            guard let pid = session.pid else { continue }
            guard !isProcessAlive(pid) else { continue }

            logger.info(
                "Hook-backed session process ended: \(session.agentId, privacy: .public) pid=\(pid, privacy: .public)"
            )
            await SessionStore.shared.process(.processSessionEnded(sessionId: session.sessionId))
        }
    }

    private func discoverRunningSessions() async {
        let processTree = ProcessTreeBuilder.shared.buildTree()
        let currentSessions = await SessionStore.shared.allSessions()
        let currentSessionsById = Dictionary(uniqueKeysWithValues: currentSessions.map { ($0.sessionId, $0) })

        var detectedSessions: [(agentId: String, pid: Int, cwd: String, sessionId: String)] = []

        if AppSettings.isAgentEnabled("codex") {
            detectedSessions.append(
                contentsOf: CodexAgent().detectRunningSessions().map {
                    (agentId: "codex", pid: $0.pid, cwd: $0.cwd, sessionId: $0.sessionId)
                }
            )
        }

        if AppSettings.isAgentEnabled("gemini") {
            detectedSessions.append(
                contentsOf: GeminiCLIAgent().detectRunningSessions().map {
                    (agentId: "gemini", pid: $0.pid, cwd: $0.cwd, sessionId: $0.sessionId)
                }
            )
        }

        for detected in detectedSessions {
            guard !detected.cwd.isEmpty else { continue }

            let existing = currentSessionsById[detected.sessionId]
            if existing?.pid == detected.pid, existing?.cwd == detected.cwd {
                continue
            }

            let tty = processTree[detected.pid]?.tty.map { "/dev/\($0)" }
            logger.debug(
                "Discovered running session: \(detected.agentId, privacy: .public) pid=\(detected.pid, privacy: .public) session=\(detected.sessionId, privacy: .public)"
            )
            await SessionStore.shared.process(
                .processDetected(
                    sessionId: detected.sessionId,
                    cwd: detected.cwd,
                    agentId: detected.agentId,
                    pid: detected.pid,
                    tty: tty
                )
            )
        }
    }

    private func isProcessAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
