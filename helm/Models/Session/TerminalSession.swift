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
@MainActor
final class TerminalSession: ObservableObject {
    let key: SessionKey
    /// The library-owned terminal state. Passed to `SessionHostView` to wire the
    /// hosted `AppTerminalView` (delegate + controller + configuration).
    let viewState: TerminalViewState

    @Published private(set) var status: SessionStatus = .starting
    let startedAt: Date

    /// Provisional exit signal from libghostty's close callback. `processAlive`
    /// is the only signal 1.3.1 exposes here; Phase 3 (kqueue + pid + C-shim)
    /// supplies the authoritative exit code.
    @Published private(set) var lastExitProcessAlive: Bool?

    /// The command + cwd this session was spawned with. Non-private + read-only so
    /// the inspector can diff live-vs-saved and offer a "restart to apply" when the
    /// saved config drifts. ADDITIVE; exposes no GhosttyTerminal types.
    let command: String
    let workingDirectory: String

    init(key: SessionKey, command: String, workingDirectory: String) {
        self.key = key
        self.command = command
        self.workingDirectory = workingDirectory
        self.startedAt = Date()

        // --- Config logic moved verbatim from the retired HelmTerminalPane ---
        var config = TerminalConfiguration()
        if !command.isEmpty {
            // Launch the command as the surface's process via ghostty's native
            // `command` config — no keystroke simulation. Wrap it in a login +
            // interactive zsh so it inherits the user's full PATH (homebrew,
            // node, etc.), exactly as if typed by hand (HANDOVER §6.2, §6.3).
            let wrapped = "/bin/zsh -lic \"\(command)\""
            config = config.custom("command", wrapped)
        }

        let state = TerminalViewState(
            configSource: .none,
            theme: .default,
            terminalConfiguration: config
        )
        // Spawn directly in the project directory (native ghostty cwd, §6.4).
        state.configuration = TerminalSurfaceOptions(workingDirectory: workingDirectory)
        self.viewState = state

        // --- Status seam ---
        // Provisional: libghostty's close callback hands us only `processAlive`.
        // Phase 3 (kqueue EVFILT_PROC/NOTE_EXIT on the child pid + waitpid +
        // C-shim for SHOW_CHILD_EXITED) gives the authoritative exit code.
        // DO NOT build kqueue now (HANDOVER §9, decisions 7 & 8).
        state.onClose = { [weak self] processAlive in
            guard let self else { return }
            self.lastExitProcessAlive = processAlive
            self.status = processAlive ? .running : .exited(code: 0)
        }

        // Optimistic: the surface spawns lazily once hosted in a window.
        self.status = .running
    }

    /// TODO(ProcessSupervisor) — Phase 3. A restart re-spawns the child via a
    /// fresh surface and resets status. Stubbed until the supervisor + pid patch
    /// land (HANDOVER §9, decisions 6 & 8).
    func restart() {
        // Phase 3 stub.
    }
}
