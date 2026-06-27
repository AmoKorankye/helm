import Foundation

/// Identifies *which* instance of a service a session belongs to.
/// `.primary` is the default one-session-per-service case. `.worktree`
/// arrives in Phase 4 (git worktrees) and `.adHoc` covers throwaway sessions.
/// Keeping this as a closed enum makes Phase 4 additive rather than a rewrite.
enum SessionInstance: Hashable {
    case primary
    case worktree(branch: String)
    case adHoc(UUID)
}

/// Composite, value-type identity for a terminal session. Decouples session
/// lifetime from any SwiftUI view identity. The `slug` is tmux-safe so Phase 6
/// (tmux-backed persistence) can reuse it directly as a session name.
struct SessionKey: Hashable {
    let serviceID: UUID
    let instance: SessionInstance

    init(serviceID: UUID, instance: SessionInstance = .primary) {
        self.serviceID = serviceID
        self.instance = instance
    }

    /// Stable, tmux-safe identifier. Lowercased, `[a-z0-9-]` only.
    /// `.primary` → `helm-<first 8 of serviceID>`.
    /// `.worktree`/`.adHoc` append a sanitized segment.
    var slug: String {
        let base = "helm-" + Self.shortID(serviceID)
        switch instance {
        case .primary:
            return base
        case let .worktree(branch):
            return base + "-" + Self.sanitize(branch)
        case let .adHoc(id):
            return base + "-" + Self.shortID(id)
        }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    private static func sanitize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || (ch.isNumber && ch.isASCII) ? ch : "-"
        }
        return String(mapped)
    }
}
