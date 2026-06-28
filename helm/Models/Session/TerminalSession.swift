import Foundation
import Combine
import GhosttyTerminal

/// A long-lived terminal session: the library's `TerminalViewState` plus Helm
/// metadata. Reference type, owned by `SessionManager`, never by a SwiftUI view.
/// libghostty consumes `TerminalViewState` as an `@ObservedObject`, so an
/// external owner is the intended pattern (HANDOVER §9 crux).
///
/// All libghostty coupling for session construction is sealed in here and in
/// `SessionManager` (HANDOVER §9, decision 6) — no other file imports
/// `GhosttyTerminal`.
///
/// LIVENESS IS OWNED BY GHOSTTY. ghostty (libghostty, in-process) owns the PTY,
/// spawns the child under `.exec`, AND reaps it. Helm therefore does NOT race it
/// with a kqueue + `waitpid` on a guessed descendant pid — that is inherently
/// fragile (`waitpid` returns `ECHILD`, and a transient helper pid can be latched
/// then mistaken for the real server dying). Instead we consume ghostty's
/// AUTHORITATIVE surface-lifecycle signal:
///   - the surface is open and ghostty has not reported close  ⇒ `.running`,
///   - `terminalDidClose(processAlive:false)`                  ⇒ the child exited,
///   - an explicit user Stop                                   ⇒ `.exited(byUser:true)`.
/// Nothing else ends a session, so a live process is NEVER shown as crashed.
@MainActor
final class TerminalSession: ObservableObject {
    let key: SessionKey
    /// The library-owned terminal state. Passed to `SessionHostView` to wire the
    /// hosted `AppTerminalView` (delegate + controller + configuration).
    let viewState: TerminalViewState

    @Published private(set) var status: SessionStatus = .starting
    private(set) var startedAt: Date

    /// Whether this session runs a CLI agent (drives the detector + sidebar badge).
    /// Threaded through from `Service.isAgent` and preserved across restart (M3).
    let isAgent: Bool

    /// Inferred agent state, republished from the owned `AgentStateDetector` so
    /// views observe the SESSION (like `status`) and never the detector directly.
    /// Stays `.unknown` for non-agent sessions (no detector attached).
    @Published private(set) var agentState: AgentState = .unknown

    /// The detector that derives `agentState` from libghostty signals + OSC 9;4
    /// progress. nil for non-agent sessions. Owned here (inside the session seal).
    private let detector: AgentStateDetector?

    /// Helm-owned forwarding delegate set as the hosted view's `delegate` in place
    /// of `viewState` (§6 / M1): forwards every stock call to `viewState` AND pipes
    /// OSC 9;4 progress to `detector`. Retained here so the host view's `weak`
    /// delegate ref stays alive for the session's lifetime.
    private let surfaceDelegate: SessionSurfaceDelegate

    /// The delegate `SessionHostView` installs on the hosted terminal view. Exposed
    /// as the stock protocol type so the host stays unaware of the forwarder shape.
    var hostDelegate: any TerminalSurfaceViewDelegate { surfaceDelegate }

    /// Set true when a user Stop must tear down (free) this session's ghostty
    /// surface so ghostty closes the PTY master, SIGHUPing the whole foreground
    /// process group (zsh → npm → node). The session itself STAYS in the
    /// manager's dict in a terminal state so the detail pane's create-or-return
    /// returns this stopped session instead of spawning a fresh one (Phase 3
    /// stop-respawn bug). Restart (rebuild) replaces the whole session+surface,
    /// clearing this.
    @Published private(set) var surfaceShouldClose = false

    /// The command + cwd this session was *actually* spawned with. `private(set)
    /// var` (grill m4) so a restart can update them to the rebuilt values and the
    /// inspector's drift banner stays correct. Exposes no GhosttyTerminal types.
    private(set) var command: String
    private(set) var workingDirectory: String

    /// Phase 6: this session runs under tmux (`-L helm`) so its process survives
    /// app close. Drives the close-handler branch (detach vs exit), kill-first
    /// Stop, and the log panel. Non-persistent sessions never touch `TmuxService`.
    let persistent: Bool
    /// The tmux service used for persistent lifecycle queries (liveness/kill). nil
    /// for non-persistent sessions (they never call tmux).
    private let tmux: TmuxService?
    /// This session's tmux session name (slug), used for every persistent query.
    var slug: String { key.slug }

    private var cancellables: Set<AnyCancellable> = []
    /// User-Stop intent: set before tearing down the surface so the resulting
    /// `terminalDidClose` (if it fires after) is classified as a clean user stop,
    /// not a spontaneous exit.
    private var stopRequestedByUser = false
    /// Main-actor guard so the session emits **exactly one** exit event to the
    /// supervisor, and only the first transition out of a live state wins.
    private var hasEmittedExit = false
    /// Emitted exactly once when this session ends, so `SessionManager` can
    /// republish to the supervisor. Carries the final `status`.
    let didExit = PassthroughSubject<SessionStatus, Never>()

    /// Republished from the detector's `attentionPing` (m4): a fresh bell/notif on
    /// a NON-PERSISTENT agent. `AttentionNotifier` posts a banner from this while
    /// the app is away. Persistent agents can't deliver OSC under tmux (B3), so
    /// this only fires for non-persistent sessions.
    let attentionPing = PassthroughSubject<Void, Never>()

    /// Restore-as-detached seed (Phase 6 reattach): when non-nil the session is
    /// constructed straight into this status (no surface attach) instead of
    /// `.starting`. Used by `restoreDetached` (`.detached`) and `restoreTerminal`
    /// (dead-pane `.exited`/`.crashed`).
    init(key: SessionKey,
         command: String,
         workingDirectory: String,
         isAgent: Bool = false,
         persistent: Bool = false,
         tmux: TmuxService? = nil,
         confPath: String? = nil,
         restoreStatus: SessionStatus? = nil) {
        self.key = key
        self.command = command
        self.workingDirectory = workingDirectory
        self.startedAt = Date()
        self.isAgent = isAgent
        self.persistent = persistent
        self.tmux = persistent ? tmux : nil

        // --- Config logic ---
        // Non-persistent: KEEP the Phase-1 `.exec` path exactly (Strategy E′) —
        // tmux is NEVER invoked, byte-for-byte the current command construction.
        // Persistent: ghostty execs `/bin/zsh -lc "<launcher>"`, the tmux launcher
        // (B1, three quote layers) built by `TmuxService.attachCommand`.
        var config = TerminalConfiguration()
        if persistent, let tmux, let confPath {
            let launcher = tmux.attachCommand(
                slug: key.slug,
                innerCommand: command,
                workingDirectory: workingDirectory,
                confPath: confPath
            )
            config = config.custom("command", launcher)
        } else if !command.isEmpty {
            let wrapped = "/bin/zsh -lic \"\(command)\""
            config = config.custom("command", wrapped)
        }

        let state = TerminalViewState(
            configSource: .none,
            theme: .default,
            terminalConfiguration: config
        )
        state.configuration = TerminalSurfaceOptions(workingDirectory: workingDirectory)
        self.viewState = state
        if let restoreStatus {
            self.status = restoreStatus
        }

        // Agent layer (Phase 5). Only agent sessions get a detector; the forwarding
        // delegate is used uniformly (progress just no-ops when detector == nil), so
        // the host wiring is identical for every session (§6).
        let detector = isAgent ? AgentStateDetector(viewState: state) : nil
        self.detector = detector
        self.surfaceDelegate = SessionSurfaceDelegate(forwardingTo: state, progress: detector)

        installCloseHandler()
        observeSurfaceAttach()

        // Republish the detector's agentState onto the session (so views observe the
        // SESSION, like `status`). Zero-poll: a Combine sink, not a timer.
        if let detector {
            detector.$agentState
                .sink { [weak self] in self?.agentState = $0 }
                .store(in: &cancellables)
            detector.attentionPing
                .sink { [weak self] in self?.attentionPing.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Agent layer (Phase 5)

    /// Drop the attention latch for this session (M2): called from the sidebar row
    /// tap so re-selecting an attention session clears the pulse even if it never
    /// regains focus. No-op for non-agent sessions.
    func clearAttention() {
        detector?.clearAttention()
    }

    // MARK: - Status wiring (ghostty-driven, zero-poll)

    /// `terminalDidClose(processAlive:)` is ghostty's AUTHORITATIVE "this surface's
    /// process ended" signal under `.exec`. `processAlive == false` means the child
    /// exited; `true` means the surface is closing while the child is still live
    /// (we ignore that here — a live process must never be shown as dead). The
    /// callback carries no exit code, so a non-user exit is the neutral
    /// `.exited(code:nil, byUser:false)` ("Process exited"), never a "crash".
    private func installCloseHandler() {
        viewState.onClose = { [weak self] processAlive in
            Task { @MainActor in
                guard let self else { return }
                if self.persistent {
                    // §3.1 source 2: for a persistent session, surface close means
                    // the ATTACH CLIENT died — usually a DETACH (process survives),
                    // unless a user Stop already handled it or the pane is dead.
                    self.resolvePersistentClose()
                } else {
                    // EXISTING Phase-3 path, byte-identical.
                    guard !processAlive else { return }   // child still alive → stay running.
                    self.endSession(byUser: self.stopRequestedByUser)
                }
            }
        }
    }

    /// Persistent surface-close reconciliation (§3.1 source 2). A user Stop already
    /// set the terminal status (and `stopRequestedByUser`), so we only act when the
    /// session is still live. Query tmux ONCE to discriminate detach vs already-
    /// dead (the B4 hook may have raced ahead): `.alive` → `.detached`; `.paneDead`
    /// → exit/crash; `.gone` → exited.
    private func resolvePersistentClose() {
        guard !hasEmittedExit else { return }
        switch status {
        case .running, .starting, .detached:
            break
        default:
            return   // already terminal (user Stop / death already ingested).
        }
        let live = tmux?.sessionLiveness(slug: slug) ?? .gone
        switch live {
        case .alive:
            // Detach is NOT an exit — it is never emitted to the supervisor, so a
            // restart policy never fires on a mere detach (§3.3).
            status = .detached
        case let .paneDead(code):
            applyDeath(code: code)
        case .gone:
            // Session vanished without a death marker — treat as a neutral exit.
            endSession(byUser: stopRequestedByUser)
        }
    }

    /// Apply a server-side death (from the B4 deaths.log hook or a liveness query)
    /// to this persistent session's status, exactly once. code 0 → neutral exit;
    /// non-zero → crash (red dot). Emits the exit event to the supervisor.
    func applyDeath(code: Int32) {
        guard !hasEmittedExit else { return }
        switch status {
        case .running, .starting, .detached:
            hasEmittedExit = true
            if code == 0 {
                status = .exited(code: 0, byUser: false)
            } else {
                status = .crashed(reason: .exited(code: code))
            }
            detector?.sessionTerminated()
            didExit.send(status)
        default:
            break
        }
    }

    /// Move to `.running` once the surface attaches (the child only exists then).
    /// `surfaceSize` publishes on first resize/attach. Zero-poll: a Combine sink,
    /// not a timer.
    private func observeSurfaceAttach() {
        // `$surfaceSize` first publishes during the surface attach/resize, which
        // happens INSIDE `SessionHostView.updateNSView` (a SwiftUI view update).
        // Setting the observed `@Published status` there triggers the "Publishing
        // changes from within view updates" warning. `.receive(on:)` hops the status
        // flip to the next runloop tick — out of the view update. Still event-driven
        // (fires only on first surface size), not a poll; the `.starting`/`.detached`
        // guards are re-checked on the deferred tick so a status that already turned
        // terminal in between (e.g. an immediate close) is never overwritten back to
        // `.running`.
        viewState.$surfaceSize
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                switch self.status {
                case .starting:
                    self.status = .running
                case .detached:
                    // Persistent reattach: the surface re-attached to a live tmux
                    // session → back to running. (Reattach only builds a surface
                    // when liveness was .alive, M2, so this never lights a corpse.)
                    self.status = .running
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Single terminal transition: end the session exactly once. A non-user exit
    /// is neutral `.exited(byUser:false)` (no fabricated crash); a user Stop is
    /// `.exited(byUser:true)`. Emits the exit event to the supervisor once.
    private func endSession(byUser: Bool) {
        guard !hasEmittedExit else { return }
        switch status {
        case .running, .starting:
            hasEmittedExit = true
            status = .exited(code: nil, byUser: byUser)
            detector?.sessionTerminated()   // M3: latch .done; a late title can't resurrect it.
            didExit.send(status)
        default:
            break   // already terminal.
        }
    }

    // MARK: - Lifecycle

    /// User-requested stop. We do NOT signal a single guessed pid (it is often the
    /// wrong/already-dead transient helper). Instead we mark intent and ask the
    /// host to free the ghostty surface: `ghostty_surface_free` closes the PTY
    /// master, which SIGHUPs the entire foreground process group (zsh + npm +
    /// node), reliably killing the whole job tree. The session is deliberately
    /// KEPT in the manager's dict in `.exited(byUser:true)` so create-or-return
    /// does not respawn it; the RestartOverlay covers the now-empty surface area.
    func stop() {
        if persistent {
            stopPersistent()
            return
        }
        stopRequestedByUser = true
        hasEmittedExit = true          // suppress any late onClose double-emit.
        status = .exited(code: nil, byUser: true)
        detector?.sessionTerminated()  // M3: latch .done on the user-stop path too.
        surfaceShouldClose = true      // host frees the surface → child SIGHUP.
    }

    /// Persistent Stop (M4): kill the tmux session and VERIFY it is gone FIRST,
    /// THEN free the surface and flip status to `.exited(byUser:true)`. We do NOT
    /// claim `.exited` until the kill is confirmed — if the kill fails (including a
    /// hung/slow tmux that misses the timeout) the session stays live so the dot
    /// keeps telling the truth, and we log it. The kill runs off-main on a GCD
    /// queue (mirrors WorktreeService); the status flip hops back to the main actor.
    private func stopPersistent() {
        stopRequestedByUser = true
        let tmux = self.tmux
        let slug = self.slug
        DispatchQueue.global(qos: .userInitiated).async {
            let killed = tmux?.killSession(slug: slug) ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard killed else {
                    #if DEBUG
                    NSLog("[TerminalSession] persistent Stop: kill-session failed for \(slug); leaving session live")
                    #endif
                    return
                }
                guard !self.hasEmittedExit else { return }
                self.hasEmittedExit = true
                self.status = .exited(code: nil, byUser: true)
                self.detector?.sessionTerminated()
                self.surfaceShouldClose = true   // free the (now dead-server) surface.
                self.didExit.send(self.status)
            }
        }
    }

    /// Tear down this session before it is dropped (close/rebuild). With the
    /// kqueue/pid watch gone there is nothing to invalidate beyond suppressing a
    /// late exit emit and cancelling Combine subscriptions; the host frees the
    /// surface when the session leaves the dict. Does NOT emit an exit event.
    func invalidate() {
        hasEmittedExit = true
        cancellables.removeAll()
    }
}
