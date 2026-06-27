import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var directory: String
    var services: [Service]
    /// Stable display order within the sidebar. Defaulted so existing
    /// projects.json (and existing call sites) keep working (HANDOVER §9, dec 5).
    var sortOrder: Int = 0
}

struct Service: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var autoStart = false
    /// Stable display order within its project. Additive + defaulted.
    var sortOrder: Int = 0
    /// Per-service environment overrides. Placeholder for a later phase — there
    /// is NO editing UI this phase, but the field is persisted so it round-trips.
    var environment: [String: String] = [:]
    /// How Helm responds when this service's process exits (Phase 3). Additive +
    /// defaulted to `.never`, so existing projects.json round-trips unchanged
    /// (HANDOVER §9, dec 5). Read by `ProcessSupervisor` at decide-time.
    var restartPolicy: RestartPolicy = .never
}

/// Auto-restart policy for a service's process (Phase 3). Codable as its raw
/// string so the JSON stays human-readable and forward-compatible.
enum RestartPolicy: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Never auto-restart; the user restarts manually from the overlay/inspector.
    case never
    /// Restart only on a crash (non-zero exit / unexpected signal we didn't ask
    /// for). A clean exit (code 0) or a user-requested Stop is left alone.
    case onCrash
    /// Restart on any non-user-requested exit (crash OR clean exit). A user Stop
    /// is still never auto-restarted.
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .onCrash: return "On crash"
        case .always: return "Always"
        }
    }
}
