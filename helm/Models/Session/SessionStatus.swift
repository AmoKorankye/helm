import Foundation

/// Lifecycle state of a terminal session. Zero-poll by design: Phase 3 drives
/// transitions from a kqueue `EVFILT_PROC`/`NOTE_EXIT` watch on the child pid
/// plus `waitpid` for the authoritative exit code — no timers, no read loops.
///
/// `.detached` is reserved for Phase 6 (LRU eviction of offscreen sessions and
/// tmux-backed survival across app close).
enum SessionStatus: Equatable {
    case starting
    case running
    case exited(code: Int)
    case crashed(code: Int)
    case detached
}
