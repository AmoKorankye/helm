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

    /// Phase 6: the ONLY tmux caller, injected at the app root. Used to build the
    /// persistent launcher, write/locate helm.conf, and kill sessions (kill-first
    /// Stop/Restart/Delete, M4). Non-persistent sessions never reach it.
    private let tmux: TmuxService
    /// The authoritative slug index (M7): recorded on persistent create, forgotten
    /// on delete/reap.
    private let index: TmuxSessionIndex
    /// helm.conf path, resolved/written once at construction (idempotent).
    private let confPath: String?

    /// Phase 6: posts attention banners for non-persistent agents (m4). Injected by
    /// the app root after construction so the manager stays constructible standalone.
    weak var notifier: AttentionNotifier?
    /// Per-session attention-ping subscription, torn down on close/rebuild.
    private var attentionSubscriptions: [SessionKey: AnyCancellable] = [:]

    init(tmux: TmuxService = TmuxService(), index: TmuxSessionIndex? = nil) {
        self.tmux = tmux
        self.index = index ?? TmuxSessionIndex()
        self.confPath = tmux.isAvailable ? tmux.ensureConfig() : nil
    }

    /// Read-only access for the persistence coordinator (reattach + death ingest)
    /// and views (orphan kill). Keeps tmux/index ownership inside the manager.
    var tmuxService: TmuxService { tmux }
    var sessionIndex: TmuxSessionIndex { index }

    /// Ingest a server-side death (B4 deaths.log line `slug exitcode`) → flip the
    /// matching session's status + reap the tmux corpse. No-op if no live session
    /// for the slug (it may already be terminal or never restored).
    func ingestDeath(slug: String, code: Int32) {
        // Flip status synchronously (cheap, main-actor). The status flip is the
        // user-visible part and must not wait on tmux IO.
        if let record = index.record(forSlug: slug), let session = sessions[record.sessionKey] {
            session.applyDeath(code: code)
        }
        // Reap the dead pane server-side OFF the main actor so a slow/hung tmux
        // never stalls the UI on a death event (the reap is just cleanup so a
        // future reattach gets a clean slate). Mirrors WorktreeService's off-main
        // Process pattern (GCD global queue, not the main actor).
        let tmux = self.tmux
        DispatchQueue.global(qos: .utility).async { _ = tmux.killSession(slug: slug) }
    }

    /// Kill an orphan tmux session (a session whose Service was deleted while the
    /// app was away) on explicit user action — NEVER auto-killed (§4).
    func killOrphan(slug: String) {
        _ = tmux.killSession(slug: slug)
        tmux.stopPipePane(slug: slug)
        index.forget(slug: slug)
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
        isAgent: Bool = false,
        persistent: Bool = false,
        displayName: String = ""
    ) -> TerminalSession {
        let key = SessionKey(serviceID: serviceID, instance: instance)
        if let existing = sessions[key] { return existing }
        let session = makeSession(
            key: key,
            command: command,
            workingDirectory: workingDirectory,
            isAgent: isAgent,
            persistent: persistent,
            displayName: displayName
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
        let wasPersistent = old.persistent
        let displayName = wasPersistent ? Self.indexDisplayName(indexRecord(key.slug)) : ""
        // Persistent Restart (§5): kill the old tmux session FIRST (verify gone) so
        // the rebuilt launcher's `new-session` runs fresh and never reattaches the
        // old process. The launcher's own dead-pane guard also covers a corpse.
        if wasPersistent {
            _ = tmux.killSession(slug: key.slug)
            tmux.stopPipePane(slug: key.slug)
        }
        // Tear down the old session (suppress a late exit emit, cancel its Combine
        // subscriptions) WITHOUT emitting an exit event, then drop it so the host
        // view swaps the surface.
        exitSubscriptions[key] = nil
        attentionSubscriptions[key] = nil
        old.invalidate()
        let fresh = makeSession(
            key: key, command: cmd, workingDirectory: dir, isAgent: agent,
            persistent: wasPersistent, displayName: displayName
        )
        sessions[key] = fresh
        return fresh
    }

    func close(_ key: SessionKey) {
        if let session = sessions[key] {
            // Delete a persistent service (§5): reap the tmux process + forget the
            // index record so no orphan process/record survives the delete.
            if session.persistent {
                _ = tmux.killSession(slug: key.slug)
                tmux.stopPipePane(slug: key.slug)
                index.forget(slug: key.slug)
            }
            session.invalidate()
        }
        exitSubscriptions[key] = nil
        attentionSubscriptions[key] = nil
        sessions[key] = nil
    }

    // MARK: - Internals

    private func makeSession(
        key: SessionKey,
        command: String,
        workingDirectory: String,
        isAgent: Bool = false,
        persistent: Bool = false,
        displayName: String = "",
        restoreStatus: SessionStatus? = nil,
        recordIndex: Bool = true,
        startLog: Bool = true
    ) -> TerminalSession {
        // Graceful degradation (§9): a service flagged persistent falls back to a
        // non-persistent launch when tmux is unavailable. The flag is preserved in
        // the model (re-enables when tmux returns); only the launch degrades.
        let effectivePersistent = persistent && tmux.isAvailable && confPath != nil
        let session = TerminalSession(
            key: key,
            command: command,
            workingDirectory: workingDirectory,
            isAgent: isAgent,
            persistent: effectivePersistent,
            tmux: effectivePersistent ? tmux : nil,
            confPath: confPath,
            restoreStatus: restoreStatus
        )
        // M7: record the authoritative index entry on persistent CREATE so launch
        // reattach + notification deep-link can reverse-map the slug. A restore
        // already has the record (recordIndex == false).
        if effectivePersistent && recordIndex {
            index.record(
                slug: key.slug,
                serviceID: key.serviceID,
                instance: key.instance,
                displayName: displayName,
                command: command,
                cwd: workingDirectory,
                isAgent: isAgent
            )
        }
        // M6: start the live log capture whenever the session is (or is about to be)
        // a LIVE tmux session — create AND reattach. Skipped for a dead-pane restore
        // (startLog == false): pipe-pane on a corpse is pointless. Idempotent on the
        // tmux side (`pipe-pane -o` re-toggles).
        if effectivePersistent && startLog {
            if let logURL = TmuxService.sessionLogPath(slug: key.slug) {
                LogFileMaintenance.cap(fileURL: logURL)
                tmux.startPipePane(slug: key.slug, toFile: logURL.path)
            }
        }
        // Republish this session's exit onto the manager's single stream.
        exitSubscriptions[key] = session.didExit
            .sink { [weak self] status in
                self?.exitEvents.send(ExitEvent(key: key, status: status))
            }
        // m4: forward a non-persistent agent's fresh attention ping to the notifier.
        // (Persistent agents can't deliver OSC under tmux, B3 — their attention is
        // handled server-side via the death/bell hooks.)
        if isAgent && !effectivePersistent {
            let label = displayName.isEmpty ? "Agent" : displayName
            attentionSubscriptions[key] = session.attentionPing
                .sink { [weak self] in
                    self?.notifier?.notifyAttention(displayName: label, key: key)
                }
        }
        return session
    }

    /// Build the index/orphan display label for a (service, project, instance).
    static func displayName(service: Service, project: Project, instance: SessionInstance) -> String {
        switch instance {
        case .primary:
            return "\(project.name) / \(service.name)"
        case let .worktree(branch):
            return "\(project.name) / \(service.name) [\(branch)]"
        case .adHoc:
            return "\(project.name) / \(service.name)"
        }
    }

    // MARK: - Phase 6 reattach (lazy attach; never auto-attaches a corpse, M2)

    /// Restore a detached persistent session on launch (§4). Builds a
    /// `TerminalSession` seeded `.detached` that does NOT spawn a `tmux attach`
    /// client until first selected (idle battery = zero attach clients). Selecting
    /// it → `reattach(key:)` builds the surface → launcher `attach` → `.running`.
    /// Idempotent: a present key is returned unchanged.
    @discardableResult
    func restoreDetached(
        key: SessionKey,
        command: String,
        workingDirectory: String,
        isAgent: Bool,
        displayName: String
    ) -> TerminalSession {
        if let existing = sessions[key] { return existing }
        let session = makeSession(
            key: key,
            command: command,
            workingDirectory: workingDirectory,
            isAgent: isAgent,
            persistent: true,
            displayName: displayName,
            restoreStatus: .detached,
            recordIndex: false,   // index already has it (we're restoring FROM it).
            startLog: false       // lazy: no attach client yet → start the log on reattach.
        )
        sessions[key] = session
        return session
    }

    /// Restore a dead-pane persistent session on launch (§4 / M2): build a session
    /// already in a terminal state (no surface, never auto-attached). The caller
    /// reaps the tmux corpse separately.
    @discardableResult
    func restoreTerminal(
        key: SessionKey,
        command: String,
        workingDirectory: String,
        isAgent: Bool,
        liveness: TmuxService.Liveness,
        displayName: String
    ) -> TerminalSession {
        if let existing = sessions[key] { return existing }
        let status: SessionStatus
        if case let .paneDead(code) = liveness {
            status = code == 0 ? .exited(code: 0, byUser: false) : .crashed(reason: .exited(code: code))
        } else {
            status = .exited(code: nil, byUser: false)
        }
        let session = makeSession(
            key: key,
            command: command,
            workingDirectory: workingDirectory,
            isAgent: isAgent,
            persistent: true,
            displayName: displayName,
            restoreStatus: status,
            recordIndex: false,
            startLog: false   // dead pane — no live capture to start.
        )
        sessions[key] = session
        return session
    }

    /// Reattach a detached session (select a `.detached` row, §5). Guarded on
    /// liveness == `.alive` (never auto-attach a corpse, M2): a live session is
    /// rebuilt in place so the launcher's `attach` reconnects; a dead pane is
    /// reclassified terminal instead. NO kill.
    @discardableResult
    func reattach(key: SessionKey) -> TerminalSession? {
        guard let old = sessions[key], old.persistent else { return sessions[key] }
        guard case .detached = old.status else { return old }
        let live = tmux.sessionLiveness(slug: key.slug)
        switch live {
        case .alive:
            // Rebuild in place → fresh surface → launcher attaches to the LIVE
            // session (its has-session branch skips create, just attaches).
            let cmd = old.command
            let dir = old.workingDirectory
            let agent = old.isAgent
            exitSubscriptions[key] = nil
            old.invalidate()
            let fresh = makeSession(
                key: key, command: cmd, workingDirectory: dir,
                isAgent: agent, persistent: true,
                displayName: Self.indexDisplayName(self.indexRecord(key.slug)),
                restoreStatus: .starting, recordIndex: false
            )
            sessions[key] = fresh
            return fresh
        case let .paneDead(code):
            old.applyDeath(code: code)
            return old
        case .gone:
            old.applyDeath(code: 0)
            return old
        }
    }

    private func indexRecord(_ slug: String) -> TmuxSessionRecord? {
        index.record(forSlug: slug)
    }
    private static func indexDisplayName(_ record: TmuxSessionRecord?) -> String {
        record?.displayName ?? ""
    }

    // SEAM (Phase 6): when over a memory/surface budget, LRU-evict offscreen
    // sessions to `.detached` (tmux-backed) instead of dropping them. Not now.
}
