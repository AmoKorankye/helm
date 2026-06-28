import Foundation

/// The kind of CLI agent a service runs. Pure value type (no GhosttyTerminal).
/// `Service.agentKindOverride` stores an explicit user choice; `nil` means AUTO
/// (derive from the command via `autodetect`). `.none` is an explicit
/// "this is NOT an agent" override.
nonisolated enum AgentKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case none      // explicit "not an agent" override
    case claude
    case generic   // some other CLI agent the user marked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Not an agent"
        case .claude: return "Claude"
        case .generic: return "Generic agent"
        }
    }

    /// Best-effort token scan of the user's command (m6). The command is wrapped
    /// as `zsh -lic "<command>"`, so we must recognize `claude` in:
    ///   `claude`, `claude --resume`, `cd path && claude`, `FOO=bar claude`,
    ///   `cd x && FOO=1 claude --resume`.
    /// We split on `&&`/`;`, then per segment tokenize on whitespace, drop a
    /// leading `cd <arg>`, drop leading `X=Y` env-assignments, and check whether
    /// the resulting command head is `claude`. Documented best-effort; the
    /// `agentKindOverride` field is the reliable escape hatch.
    static func autodetect(command: String) -> AgentKind? {
        let segments = command
            .replacingOccurrences(of: ";", with: "&&")
            .components(separatedBy: "&&")
        for seg in segments {
            var tokens = seg
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            // Drop a leading `cd <dir>`.
            if tokens.first?.lowercased() == "cd" {
                tokens = Array(tokens.dropFirst(2))
            }
            // Drop leading `X=Y` env assignments (a `=` not at the very start).
            while let t = tokens.first, t.contains("="), !t.hasPrefix("=") {
                tokens.removeFirst()
            }
            if tokens.first?.lowercased() == "claude" { return .claude }
        }
        return nil
    }
}
