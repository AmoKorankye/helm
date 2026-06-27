import Foundation
import Combine
import GhosttyTerminal

/// Owns the live set of terminal sessions, injected at the app root. The detail
/// pane only *displays* a manager-owned `TerminalSession`; it never builds a
/// terminal itself. Sessions die only on explicit `close` (HANDOVER §9,
/// decision 2). This is the single seam, alongside `TerminalSession`, that
/// imports `GhosttyTerminal`.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [SessionKey: TerminalSession] = [:]

    /// Create-or-return the session for a service instance. Idempotent: calling
    /// repeatedly for the same `(service, instance)` returns the same live
    /// session, so switching away and back preserves the running process.
    func session(
        for service: Service,
        in project: Project,
        instance: SessionInstance = .primary
    ) -> TerminalSession {
        let key = SessionKey(serviceID: service.id, instance: instance)
        if let existing = sessions[key] {
            return existing
        }
        let session = TerminalSession(
            key: key,
            command: service.command,
            workingDirectory: project.directory
        )
        sessions[key] = session
        return session
    }

    func session(for key: SessionKey) -> TerminalSession? {
        sessions[key]
    }

    func close(_ key: SessionKey) {
        sessions[key] = nil
    }

    // SEAM (Phase 6): when over a memory/surface budget, LRU-evict offscreen
    // sessions to `.detached` (tmux-backed) instead of dropping them. Not now.
}
