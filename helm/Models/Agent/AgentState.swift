import Foundation

/// Inferred state of a CLI agent (e.g. Claude Code) running inside a session.
/// DISTINCT from `SessionStatus` (process liveness): a session can be `.running`
/// yet agent-`.waiting`/`.attention`. Derived ZERO-POLL from libghostty's
/// @Published signals (title / bell / notification / progress / close) — see the
/// Phase 5 plan §1.4. Pure value type: NO GhosttyTerminal import, so views and
/// stores can consume it without crossing the session seal.
enum AgentState: Equatable {
    /// Not an agent, or no signal yet → no badge.
    case unknown
    /// Agent up, no activity/attention signal.
    case idle
    /// RELIABLE when OSC 9;4 progress is active (forwarding shim, §6); otherwise
    /// only via the best-effort title heuristic (off by default).
    case working
    /// BEST-EFFORT title heuristic only (off by default).
    case waiting
    /// RELIABLE: BEL or desktop-notification while UNFOCUSED. Latched until the
    /// row is re-selected (explicit clear).
    case attention
    /// Process ended (session exited). Mirrors `SessionStatus` exit.
    case done
}
