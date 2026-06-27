import Foundation

/// Structured cause of a child process's exit (Phase 3, grill M2: never lose the
/// signal by sign-overloading an exit code). GhosttyTerminal-free — deals only in
/// raw POSIX status integers.
enum ExitReason: Equatable {
    /// The process called `exit(code)` (or returned from `main`).
    case exited(code: Int32)
    /// The process was terminated by a signal (e.g. SIGSEGV=11, SIGKILL=9,
    /// SIGTERM=15). Kept distinct from `exited` so a crash signal is never
    /// confused with an exit code.
    case signalled(signal: Int32)
    /// No status was available: ghostty reaped the child before our `waitpid`
    /// (observed as `ECHILD`/`r<=0`), or we are in E-degraded mode (discovery
    /// failed and the only signal is `terminalDidClose`). Classified by
    /// stop-intent downstream, never treated as an authoritative crash code.
    case unknown
}
