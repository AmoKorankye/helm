import Foundation

/// A saved quick-launch agent template. GLOBAL (not per-project). Launching one
/// ADDS A REAL SERVICE to the selected project from this template, then selects +
/// starts it (B1 / plan §4.2). It is NOT a session and NOT a persisted service
/// itself — just a template. Codable; persisted in its OWN file (m4) via
/// `PresetPersistenceStore`. Pure value type (no GhosttyTerminal).
struct LaunchPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String              // "Claude (resume)"
    var command: String           // "claude --resume"
    var sortOrder: Int = 0
    /// Seeds the new service's `agentKindOverride` so the badge shows immediately.
    var agentKind: AgentKind = .claude

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        sortOrder: Int = 0,
        agentKind: AgentKind = .claude
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.sortOrder = sortOrder
        self.agentKind = agentKind
    }

    /// Defensive decoder (HANDOVER §6.8): a missing optional key defaults rather
    /// than throwing, so an older/newer presets.json round-trips.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        agentKind = try c.decodeIfPresent(AgentKind.self, forKey: .agentKind) ?? .claude
    }

    /// Built-ins seeded ONLY on first launch when the presets FILE is ABSENT (m5).
    static let builtins: [LaunchPreset] = [
        .init(name: "Claude",          command: "claude",                                sortOrder: 0),
        .init(name: "Claude (resume)", command: "claude --resume",                       sortOrder: 1),
        .init(name: "Claude (skip)",   command: "claude --dangerously-skip-permissions", sortOrder: 2),
    ]
}
