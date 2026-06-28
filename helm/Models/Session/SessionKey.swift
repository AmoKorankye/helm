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
    /// `.worktree` appends a sanitized branch segment AND a short hash of the RAW
    /// branch so the slug is INJECTIVE (M3): `feature/x` and `feature-x` both
    /// sanitize to `feature-x`, but their raw-branch hashes differ, so the slugs
    /// differ. `.adHoc` appends a short id.
    var slug: String {
        let base = "helm-" + Self.shortID(serviceID)
        switch instance {
        case .primary:
            return base
        case let .worktree(branch):
            return base + "-" + Self.sanitize(branch) + "-" + Self.shortHash(branch)
        case let .adHoc(id):
            return base + "-" + Self.shortID(id)
        }
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    static func sanitize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || (ch.isNumber && ch.isASCII) ? ch : "-"
        }
        return String(mapped)
    }

    /// 8 hex chars of a STABLE (cross-launch) hash of the RAW branch — FNV-1a over
    /// the UTF-8 bytes. NOT Swift's `Hasher` (per-process seeded → unstable across
    /// launches, which would break the reattach/index keyed off the slug). Keeps
    /// the slug `[a-z0-9-]`-safe and makes distinct branches produce distinct slugs.
    static func shortHash(_ raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325        // FNV offset basis
        let prime: UInt64 = 0x100000001b3            // FNV prime
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
