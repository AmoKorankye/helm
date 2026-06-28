import Foundation
import Combine

/// On-demand, zero-poll cache of worktree scans (HANDOVER §9 #7). NO timer ever
/// scans git. GhosttyTerminal-free.
@MainActor
final class WorktreeStore: ObservableObject {
    @Published private(set) var scans: [UUID: WorktreeScan] = [:]

    private let service: WorktreeService
    /// Coalescing (grill M5): an in-flight scan per project. A second refresh
    /// AWAITS the running Task (never early-returns stale); the before-fan-out
    /// caller awaits the COMPLETED scan so it spawns against the current set.
    private var inFlight: [UUID: Task<WorktreeScan, Never>] = [:]

    init(service: WorktreeService? = nil) {
        // Resolve the default inside the body (not as a default-arg expression) so
        // the struct init isn't pulled into this @MainActor context — keeps the
        // build warning-free. `WorktreeService` itself is actor-agnostic.
        self.service = service ?? WorktreeService()
    }

    func scan(for projectID: UUID) -> WorktreeScan? { scans[projectID] }

    /// Re-scan now (off-main via the service), coalesced. Returns the scan so
    /// callers that need the fresh set (fan-out start) can use the result.
    @discardableResult
    func refresh(_ project: Project) async -> WorktreeScan {
        let id = project.id
        if let running = inFlight[id] { return await running.value }
        let task = Task { await service.worktrees(for: project) }
        inFlight[id] = task
        let result = await task.value
        // Identity guard: only clear if THIS task is still the in-flight one, so a
        // newer refresh's task isn't clobbered. (`Task` is a value type whose `==`
        // compares the underlying job identity.)
        if inFlight[id] == task { inFlight[id] = nil }
        scans[id] = result
        return result
    }

    /// Resolve the spawn working directory for an instance of a service in a
    /// project, from the latest scan.
    /// - `.primary` → ALWAYS `project.directory` VERBATIM (grill M1 — never the
    ///   scan's symlink-resolved main path; that caused the un-dismissable drift
    ///   banner). Returns project.directory even if unscanned.
    /// - `.worktree`/`.adHoc` → the matching worktree's standardized `path`, or
    ///   `nil` if it no longer exists / is prunable (vanished — §8.1, m12).
    func workingDirectory(for instance: SessionInstance, in project: Project) -> String? {
        if case .primary = instance { return project.directory }
        guard let scan = scans[project.id] else { return nil }
        // Match by the instance the worktree would produce (branch or path-hash).
        return scan.worktrees.first { $0.isSpawnableChild
                                       && $0.sessionInstance() == instance }?.path
    }
}
