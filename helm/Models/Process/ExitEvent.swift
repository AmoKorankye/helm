import Foundation

/// A single session-exit event the `ProcessSupervisor` decides on. Carries the
/// final `SessionStatus` (intent already encoded, grill m3) so the supervisor
/// reads crash-vs-clean-vs-user from status alone. GhosttyTerminal-free.
struct ExitEvent {
    let key: SessionKey
    let status: SessionStatus
}
