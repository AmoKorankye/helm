import Foundation

/// Lifecycle state of a terminal session. Zero-poll by design (Phase 3): driven
/// entirely by ghostty's event-driven surface-lifecycle callbacks — no timers, no
/// read loops, no kqueue/`waitpid` on a guessed descendant pid.
///
/// Liveness is OWNED BY GHOSTTY (it owns the PTY, the child, and its reaping).
/// While the surface is open and ghostty has not reported close
/// (`terminalDidClose`), the session is `.running` — Helm never independently
/// declares it dead. The session ends ONLY when ghostty's `terminalDidClose`
/// fires (the child exited) or the user explicitly Stops it.
///
/// Stop-intent is encoded INTO the status (grill m3): `.exited(byUser:)` carries
/// whether Helm requested the stop, so the sidebar dot color and the supervisor's
/// decision both derive from `status` alone — no side flag.
///
/// `.detached` is reserved for Phase 6 (tmux-backed survival across app close).
enum SessionStatus: Equatable {
    /// Created, but the surface has not yet attached / first paint pending.
    /// Yellow dot.
    case starting
    /// The surface is open and ghostty has not reported the child's exit. The
    /// process is alive. Green dot.
    case running
    /// The child exited, or the user stopped it. `byUser` = Helm requested the
    /// stop (Stop button / explicit restart). Under ghostty's `.exec` backend the
    /// close callback carries no reliable exit code, so `code` is `nil` for a
    /// natural exit (we never fabricate a crash from an unknown disappearance).
    /// Gray dot. Neutral — "Process exited", not the alarming "crashed".
    case exited(code: Int32?, byUser: Bool)
    /// Reserved for a genuinely-observed fatal outcome (a real nonzero exit code
    /// or an observed fatal signal). Ghostty's `.exec` close callback does not
    /// currently surface one, so this is not produced today; kept so a future
    /// signal source can light the red dot without a type change. Red dot.
    case crashed(reason: ExitReason)
    /// Phase 6: offscreen/tmux-backed. Blue dot.
    case detached
}
