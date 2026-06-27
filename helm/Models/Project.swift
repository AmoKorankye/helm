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
}
