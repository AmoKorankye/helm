import Foundation
import CryptoKit   // for the path-derived stable hash (detached worktrees)

/// A single git worktree, derived at runtime from `git worktree list --porcelain`.
/// NEVER persisted (HANDOVER §9 #5). Pure value type; GhosttyTerminal-free,
/// SwiftUI-free, git-free (parsing lives in WorktreeService; this is the result).
struct Worktree: Identifiable, Hashable {
    /// Absolute path to the worktree directory (the `worktree` porcelain line),
    /// stored standardized (symlinks resolved) so it matches across re-scans and
    /// is a stable hash input. This is the spawn working directory for the row.
    let path: String
    /// Branch short name (e.g. "feature-x"), or nil for a detached/branchless
    /// worktree. Derived by stripping `refs/heads/` from the porcelain `branch` line.
    let branch: String?
    /// HEAD commit SHA (porcelain `HEAD` line). **Optional** — a bare worktree
    /// record is literally `worktree <path>\nbare` with NO HEAD line (grill B2).
    let head: String?
    /// The repository's main worktree. Assigned to the FIRST non-phantom record
    /// (git emits the main worktree first); exactly one record is `isMain` (m9).
    let isMain: Bool
    /// `bare` line present. A bare main has no checkout → NOT spawnable (excluded
    /// from fan-out rows, B2). Linked worktrees of a bare repo are normal — keep them.
    let isBare: Bool
    /// `locked` line present (with or without a trailing reason — B4). Still spawnable.
    let isLocked: Bool
    /// `detached` line present (no branch). Keyed by path-hash, not SHA (M2).
    let isDetached: Bool
    /// `prunable` line present (with or without a reason — B4). The worktree dir is
    /// gone from disk but git still LISTS it until `git worktree prune` (grill B3).
    /// Prunable rows are excluded from fan-out (no Play) — spawning in a vanished
    /// cwd is undefined/unsafe.
    let isPrunable: Bool

    var id: String { path }   // unique within one `git worktree list`.

    /// Human label for the sidebar row.
    var displayName: String {
        if let branch { return branch }
        if isDetached, let head { return "(detached) " + head.prefix(7) }
        if isBare { return "(bare)" }
        return (path as NSString).lastPathComponent
    }

    /// Spawnable into a fan-out row? Main is `.primary` (its own un-expanded row),
    /// so the *children* are: not main, not bare, not prunable.
    var isSpawnableChild: Bool { !isMain && !isBare && !isPrunable }

    /// The stable `SessionInstance` for this worktree. MAIN → `.primary` (D7,
    /// preserves pre-Phase-4 identity). Branched → `.worktree(branch:)`.
    /// Detached/branchless → PATH-derived stable hash (grill M2 — SHA is neither
    /// stable nor unique; two `--detach` worktrees on the same commit must not
    /// collide). `path` is always present (also why head can be nil, B2).
    func sessionInstance() -> SessionInstance {
        if isMain { return .primary }
        if let branch { return .worktree(branch: branch) }
        return .worktree(branch: "wt-" + Self.shortHash(path))
    }

    /// First 8 hex of SHA-256 over the standardized path. Stable across re-scans,
    /// unique per worktree directory, tmux-safe after SessionKey.slug sanitize.
    static func shortHash(_ standardizedPath: String) -> String {
        let digest = SHA256.hash(data: Data(standardizedPath.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()  // 8 hex chars
    }
}

/// Result of one scan. Distinguishes "not a git repo / git unavailable" (feature
/// silently absent) from "git repo, one worktree" (no fan-out) from "multiple".
enum WorktreeScan: Equatable {
    /// Not a git repo, git missing, or any non-zero git exit / parse failure.
    /// The feature is silently absent for this project (grill M4: ONE control-flow
    /// case — we never branch the UI on *why*).
    case unavailable(reason: WorktreeUnavailable)
    /// A git repo. `worktrees` always contains at least the main worktree.
    case available([Worktree])

    var worktrees: [Worktree] {
        if case let .available(list) = self { return list }
        return []
    }
    /// Additional spawnable children (excludes main, bare, prunable — D7, B2, B3).
    var fanOutChildren: [Worktree] { worktrees.filter(\.isSpawnableChild) }
    /// Fan-out is meaningful only when there's at least one spawnable child.
    var hasFanOut: Bool { !fanOutChildren.isEmpty }
    var main: Worktree? { worktrees.first(where: \.isMain) }
}

/// Kept for logging only. Control flow collapses every failure to "unavailable"
/// (grill M4) — the UI is identical regardless of reason; we never string-match
/// locale-fragile stderr to distinguish notAGitRepo from a generic error.
enum WorktreeUnavailable: Equatable {
    case notAGitRepo       // exit 128 (inferred, logging label only)
    case gitNotFound       // Process.run() threw / git not located
    case gitError(String)  // any other non-zero exit / parse failure; message logged only
}
