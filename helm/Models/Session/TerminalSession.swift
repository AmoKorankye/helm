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

    init(key: SessionKey, command: String, workingDirectory: String) {
        self.key = key
        self.command = command
        self.workingDirectory = workingDirectory
        self.startedAt = Date()

        // --- Config logic moved verbatim from the retired HelmTerminalPane ---
        // KEEP the Phase-1 `.exec` path exactly (Strategy E): ghostty owns the
        // PTY/spawn/reap; we only observe its lifecycle (HANDOVER §6.2, §6.3).
        var config = TerminalConfiguration()
        if !command.isEmpty {
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

        installCloseHandler()
        observeSurfaceAttach()
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
                guard !processAlive else { return }   // child still alive → stay running.
                self.endSession(byUser: self.stopRequestedByUser)
            }
        }
    }

    /// Move to `.running` once the surface attaches (the child only exists then).
    /// `surfaceSize` publishes on first resize/attach. Zero-poll: a Combine sink,
    /// not a timer.
    private func observeSurfaceAttach() {
        viewState.$surfaceSize
            .compactMap { $0 }
            .first()
            .sink { [weak self] _ in
                guard let self else { return }
                if case .starting = self.status {
                    self.status = .running
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
        stopRequestedByUser = true
        hasEmittedExit = true          // suppress any late onClose double-emit.
        status = .exited(code: nil, byUser: true)
        surfaceShouldClose = true      // host frees the surface → child SIGHUP.
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
