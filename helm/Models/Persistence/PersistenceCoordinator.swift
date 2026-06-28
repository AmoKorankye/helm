import Foundation
import AppKit
import Combine

/// One detached/orphan tmux session discovered on launch whose Service was
/// deleted while the app was away (§4). Surfaced in a sidebar group with a Kill
/// action — NEVER auto-killed.
struct OrphanSession: Identifiable, Hashable {
    let slug: String
    let label: String
    var id: String { slug }
}

/// App-root coordinator (@MainActor) that owns Phase-6 persistence reconciliation:
/// reattach-on-launch (§4), the deaths.log tail (B4 — PRIMARY status source), the
/// app-activate refresh (m1 — ONE list-sessions), and the orphan list. Subscribes
/// to `didBecomeActiveNotification`. GhosttyTerminal-FREE (drives `SessionManager`
/// through its public surface only).
@MainActor
final class PersistenceCoordinator: ObservableObject {
    /// Orphan sessions (live tmux session, no matching saved Service). Rendered in
    /// a sidebar "Detached (orphan)" group with a Kill action.
    @Published private(set) var orphans: [OrphanSession] = []

    private let sessions: SessionManager
    private let store: ProjectStore
    private let tmux: TmuxService
    private let index: TmuxSessionIndex
    private let notifier: AttentionNotifier?

    private var deathsTail: LogTail?
    private var cancellables: Set<AnyCancellable> = []
    private var didReattach = false

    init(sessions: SessionManager,
         store: ProjectStore,
         notifier: AttentionNotifier? = nil) {
        self.sessions = sessions
        self.store = store
        self.tmux = sessions.tmuxService
        self.index = sessions.sessionIndex
        self.notifier = notifier

        // App-activate refresh (m1): reconcile attached/detached/gone on return.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshDetachedOnActivate() }
            .store(in: &cancellables)
    }

    // MARK: - Reattach on launch (§4)

    /// Run once on launch after stores are ready. Graceful degradation: early-
    /// return when tmux is absent (§9). Discovers `helm-*` sessions on `-L helm`,
    /// maps via the authoritative index (M7), restores detached / dead-pane,
    /// reaps corpses, collects orphans. Ingests + truncates deaths.log, then starts
    /// its push-based tail (B4).
    func reattachOnLaunch() {
        guard !didReattach else { return }
        didReattach = true
        guard tmux.isAvailable else { return }
        _ = tmux.ensureConfig()

        // 1. Drain any deaths written while the app was DOWN, then truncate (R3).
        if let deathsURL = TmuxService.deathsLogPath() {
            if let existing = try? String(contentsOf: deathsURL, encoding: .utf8) {
                for line in existing.split(separator: "\n") { ingestDeath(line: String(line)) }
            }
            LogFileMaintenance.truncate(fileURL: deathsURL)
            // 2. Start the always-on push tail for live deaths (B4).
            deathsTail = LogTail(url: deathsURL, fromEnd: true) { [weak self] chunk in
                Task { @MainActor in
                    for line in chunk.split(separator: "\n") {
                        self?.ingestDeath(line: String(line))
                    }
                }
            }
        }

        // 3. Reattach live sessions.
        var newOrphans: [OrphanSession] = []
        for row in tmux.listSessions() {
            guard let record = index.record(forSlug: row.slug) else {
                // Index miss: a session with no record (index lost / external). It's
                // an orphan — offer kill, never auto-kill.
                newOrphans.append(OrphanSession(slug: row.slug,
                                                label: index.label(forOrphan: row.slug) ?? row.slug))
                continue
            }
            // Is the Service still saved? (delete-while-away → orphan)
            let serviceExists = store.service(id: record.serviceID) != nil
            guard serviceExists else {
                newOrphans.append(OrphanSession(slug: row.slug, label: record.displayName))
                continue
            }
            let key = record.sessionKey
            if row.dead {
                // M2: a corpse — never auto-attach. Classify terminal, then reap.
                let live = tmux.sessionLiveness(slug: row.slug)
                sessions.restoreTerminal(
                    key: key, command: record.command, workingDirectory: record.cwd,
                    isAgent: record.isAgent, liveness: live, displayName: record.displayName
                )
                _ = tmux.killSession(slug: row.slug)
                index.forget(slug: row.slug)
            } else {
                sessions.restoreDetached(
                    key: key, command: record.command, workingDirectory: record.cwd,
                    isAgent: record.isAgent, displayName: record.displayName
                )
            }
        }
        orphans = newOrphans
    }

    // MARK: - App-activate refresh (m1 — ONE list-sessions)

    /// On app activate, reconcile detached/gone with a single list-sessions (death
    /// is already pushed via the deaths.log tail; this just catches gone sessions /
    /// refreshes orphans). Zero per-session spawns.
    func refreshDetachedOnActivate() {
        guard tmux.isAvailable, didReattach else { return }
        let rows = tmux.listSessions()
        let liveSlugs = Set(rows.map { $0.slug })
        // A detached session whose tmux session vanished → mark exited.
        for (key, session) in sessions.sessions where session.persistent {
            if case .detached = session.status, !liveSlugs.contains(key.slug) {
                session.applyDeath(code: 0)
            }
        }
        // Drop orphans that no longer exist.
        orphans.removeAll { !liveSlugs.contains($0.slug) }
    }

    // MARK: - Death ingest (B4 — PRIMARY status source)

    /// Parse one deaths.log line `slug exitcode` and route it into the manager.
    func ingestDeath(line: String) {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let slug = f.first.map(String.init) else { return }
        let code = Int32(f.count > 1 ? f[1] : "") ?? 0
        // Notify (death) BEFORE reaping so the index reverse-lookup still resolves.
        notifier?.notifyDeath(slug: slug, code: code,
                              record: index.record(forSlug: slug))
        sessions.ingestDeath(slug: slug, code: code)
    }

    /// User-driven orphan kill (§4 — never auto).
    func killOrphan(slug: String) {
        sessions.killOrphan(slug: slug)
        orphans.removeAll { $0.slug == slug }
    }
}
