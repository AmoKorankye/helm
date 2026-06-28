import Foundation
import Combine
import GhosttyTerminal

/// Owns the live set of terminal sessions, injected at the app root. The detail
/// pane only *displays* a manager-owned `TerminalSession`; it never builds a
/// terminal itself. Sessions die only on explicit `close`/`stop` (HANDOVER §9,
/// decision 2). This is the single seam, alongside `TerminalSession`, that
/// imports `GhosttyTerminal`.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [SessionKey: TerminalSession] = [:]

    /// Single exit-event stream the `ProcessSupervisor` subscribes to. Republished
    /// from each session's own `didExit`. Carries the final `SessionStatus` so the
    /// supervisor decides from status alone (intent already encoded, grill m3).
    let exitEvents = PassthroughSubject<ExitEvent, Never>()

    /// Per-session subscription to its `didExit`, torn down on close/rebuild.
    private var exitSubscriptions: [SessionKey: AnyCancellable] = [:]

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
        let session = makeSession(
            key: key,
            command: service.command,
            workingDirectory: project.directory,
            isAgent: service.isAgent
        )
        sessions[key] = session
        return session
    }

    /// Create-or-return the session for a specific (service, instance), spawning in
    /// an EXPLICIT working directory. Phase 4: the caller passes the worktree path
    /// for a `.worktree` instance; `project.directory` for `.primary`. Idempotent
    /// per key — switching away and back preserves the running process.
    func session(
        forServiceID serviceID: UUID,
        instance: SessionInstance,
        command: String,
        workingDirectory: String,
        isAgent: Bool = false
    ) -> TerminalSession {
        let key = SessionKey(serviceID: serviceID, instance: instance)
        if let existing = sessions[key] { return existing }
        let session = makeSession(
            key: key,
            command: command,
            workingDirectory: workingDirectory,
            isAgent: isAgent
        )
        sessions[key] = session
        return session
    }

    func session(for key: SessionKey) -> TerminalSession? {
        sessions[key]
    }

    /// Enumerate the live `SessionKey`s for a set of serviceIDs — `.primary` AND
    /// every live `.worktree(...)` instance — straight from the dict (the single
    /// source of truth). Lets `ProjectStore` stay git/Ghostty-free while delete
    /// still tears down per-worktree sessions (grill B1).
    func keys(forServiceIDs ids: Set<UUID>) -> [SessionKey] {
        sessions.keys.filter { ids.contains($0.serviceID) }
    }

    // MARK: - Lifecycle

    /// Explicit user stop. Always tears down the ghostty surface: freeing it
    /// (`ghostty_surface_free`) closes the PTY master, which SIGHUPs the entire
    /// foreground process group (zsh → npm → node), reliably killing the whole job
    /// tree. We do NOT signal a single guessed pid — that often hit the wrong /
    /// already-dead transient helper while the real server lived on. The session
    /// marks itself terminally `.exited(byUser:true)`.
    ///
    /// CRITICAL (Phase 3 stop-respawn bug): a Stop must NEVER remove the session
    /// from `sessions`. If it did, the detail pane's create-or-return
    /// (`session(for:in:)`) would immediately spawn a brand-new session for the
    /// still-selected service — the "restart" the user wrongly saw. The
    /// `TerminalSession` stays in the dict in `.exited(byUser:true)`, so
    /// create-or-return returns the *stopped* session. `close` (which removes from
    /// the dict) is for delete only.
    func stop(_ key: SessionKey) {
        guard let session = sessions[key] else { return }
        session.stop()
        // The surface-teardown lives in `SessionHostView.updateNSView`, which only
        // re-runs when the manager (its `@ObservedObject`) republishes — `stop`
        // mutated the *session*, not the dict, so nudge the manager so the host
        // frees the surface promptly.
        objectWillChange.send()
    }

    /// Restart = rebuild the session+surface IN PLACE under the same `SessionKey`
    /// (grill M1: a surface cannot be reused). The fresh session carries the
    /// CURRENT saved command/dir if provided (so restart applies edits, m4),
    /// otherwise reuses what the old session launched with.
    @discardableResult
    func rebuild(
        key: SessionKey,
        command: String? = nil,
        workingDirectory: String? = nil,
        isAgent: Bool? = nil
    ) -> TerminalSession? {
        guard let old = sessions[key] else { return nil }
        let cmd = command ?? old.command
        let dir = workingDirectory ?? old.workingDirectory
        // M3: thread isAgent through restart so a rebuilt agent keeps detection.
        // Default to the old session's value (a manual restart from the overlay/row
        // doesn't pass it); a caller with the current Service can override.
        let agent = isAgent ?? old.isAgent
        // Tear down the old session (suppress a late exit emit, cancel its Combine
        // subscriptions) WITHOUT emitting an exit event, then drop it so the host
        // view swaps the surface.
        exitSubscriptions[key] = nil
        old.invalidate()
        let fresh = makeSession(key: key, command: cmd, workingDirectory: dir, isAgent: agent)
        sessions[key] = fresh
        return fresh
    }

    func close(_ key: SessionKey) {
        if let session = sessions[key] {
            session.invalidate()
        }
        exitSubscriptions[key] = nil
        sessions[key] = nil
    }

    // MARK: - Internals

    private func makeSession(
        key: SessionKey,
        command: String,
        workingDirectory: String,
        isAgent: Bool = false
    ) -> TerminalSession {
        let session = TerminalSession(
            key: key,
            command: command,
            workingDirectory: workingDirectory,
            isAgent: isAgent
        )
        // Republish this session's exit onto the manager's single stream.
        exitSubscriptions[key] = session.didExit
            .sink { [weak self] status in
                self?.exitEvents.send(ExitEvent(key: key, status: status))
            }
        return session
    }

    // SEAM (Phase 6): when over a memory/surface budget, LRU-evict offscreen
    // sessions to `.detached` (tmux-backed) instead of dropping them. Not now.
}
