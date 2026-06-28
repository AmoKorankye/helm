import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var directory: String
    var services: [Service]
    /// Stable display order within the sidebar. Defaulted so existing
    /// projects.json (and existing call sites) keep working (HANDOVER §9, dec 5).
    var sortOrder: Int = 0

    init(id: UUID = UUID(), name: String, directory: String, services: [Service], sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.directory = directory
        self.services = services
        self.sortOrder = sortOrder
    }

    /// Defensive decoder mirroring `Service.init(from:)`: a missing `sortOrder`
    /// (older file) defaults rather than throwing and silently dropping projects.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decode(String.self, forKey: .directory)
        services = try c.decode([Service].self, forKey: .services)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
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
    /// Phase 4: when true, this service fans out across the project's git
    /// worktrees (one concurrent session per worktree). Additive + defaulted to
    /// `false`, so existing projects.json round-trips unchanged (HANDOVER §9, dec
    /// 5). Worktrees themselves are DERIVED at runtime, never persisted — only
    /// this opt-in boolean is.
    var worktreeEnabled: Bool = false
    /// Phase 5: agent-detection override. `nil` = AUTO (derive from `command` via
    /// `AgentKind.autodetect`); set explicitly to force on/off (`.none` forces
    /// "not an agent"). Additive + defaulted to `nil` so existing projects.json
    /// round-trips (HANDOVER §6.8/§9.5).
    var agentKindOverride: AgentKind? = nil
    /// Phase 6: when true, this service launches under tmux (socket `-L helm`) so
    /// the process survives app close and can be reattached. Additive + defaulted
    /// to `false`, so existing projects.json round-trips unchanged (HANDOVER §6.8/
    /// §9.5 — same shape as `worktreeEnabled`). The ONLY new persisted field.
    var persistent: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        autoStart: Bool = false,
        sortOrder: Int = 0,
        environment: [String: String] = [:],
        restartPolicy: RestartPolicy = .never,
        worktreeEnabled: Bool = false,
        agentKindOverride: AgentKind? = nil,
        persistent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.autoStart = autoStart
        self.sortOrder = sortOrder
        self.environment = environment
        self.restartPolicy = restartPolicy
        self.worktreeEnabled = worktreeEnabled
        self.agentKindOverride = agentKindOverride
        self.persistent = persistent
    }

    /// Resolved agent kind: an explicit override wins (`.none` → not an agent);
    /// otherwise auto-detect from the command. `nil` = not an agent.
    var resolvedAgentKind: AgentKind? {
        if let agentKindOverride {
            return agentKindOverride == .none ? nil : agentKindOverride
        }
        return AgentKind.autodetect(command: command)
    }

    /// Whether this service runs a CLI agent (so it gets a detector + badge).
    var isAgent: Bool { resolvedAgentKind != nil }

    /// Explicit decoder so additive/defaulted fields (`restartPolicy`,
    /// `worktreeEnabled`, `sortOrder`, `environment`, `autoStart`) tolerate a
    /// projects.json written by an OLDER build that lacks the key. Synthesized
    /// `Codable` throws `keyNotFound` for a missing key even when the property has
    /// a default — which, under `ProjectStore`'s `(try? load()) ?? []`, would
    /// silently drop the user's projects on upgrade. `decodeIfPresent` + default
    /// makes the field genuinely backward-compatible (the round-trip claim the
    /// plan/HANDOVER assumed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        restartPolicy = try c.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .never
        worktreeEnabled = try c.decodeIfPresent(Bool.self, forKey: .worktreeEnabled) ?? false
        agentKindOverride = try c.decodeIfPresent(AgentKind.self, forKey: .agentKindOverride)
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent) ?? false
    }
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
