import Foundation
import Combine

/// Codable mirror of `SessionInstance` (which is not Codable and carries non-
/// Codable associated values cleanly enough). Lets a record round-trip the
/// instance so reattach can rebuild the exact `SessionKey`.
enum SessionInstanceCoding: Codable, Hashable {
    case primary
    case worktree(branch: String)
    case adHoc(id: UUID)

    init(_ instance: SessionInstance) {
        switch instance {
        case .primary: self = .primary
        case let .worktree(branch): self = .worktree(branch: branch)
        case let .adHoc(id): self = .adHoc(id: id)
        }
    }

    var instance: SessionInstance {
        switch self {
        case .primary: return .primary
        case let .worktree(branch): return .worktree(branch: branch)
        case let .adHoc(id): return .adHoc(id)
        }
    }
}

/// One authoritative record for a persistent tmux session, keyed by its slug.
struct TmuxSessionRecord: Codable, Hashable {
    let slug: String
    let serviceID: UUID
    let instance: SessionInstanceCoding
    /// Human label for the orphan sidebar group + notification deep-link copy,
    /// e.g. "Project / Service [branch]".
    let displayName: String
    let command: String
    let cwd: String
    let isAgent: Bool

    var sessionKey: SessionKey {
        SessionKey(serviceID: serviceID, instance: instance.instance)
    }
}

/// AUTHORITATIVE slug → record map (M7). The source of truth for labeling,
/// reverse lookup (launch reattach + notification deep-link), written on
/// persistent-session CREATE, cleaned on delete/reap. Forward-scan of saved
/// Services is only a cross-check for index misses. Persisted in its own file
/// (`sessions.json`), mirroring `PresetStore`/`PersistenceStore`.
///
/// GhosttyTerminal-free, SwiftUI-free except `ObservableObject` conformance.
@MainActor
final class TmuxSessionIndex: ObservableObject {
    @Published private(set) var records: [String: TmuxSessionRecord] = [:]

    private let store: TmuxIndexPersistenceStore

    init(store: TmuxIndexPersistenceStore = TmuxIndexPersistenceStore()) {
        self.store = store
        let loaded = (try? store.load()) ?? []
        records = Dictionary(uniqueKeysWithValues: loaded.map { ($0.slug, $0) })
    }

    /// Record (or replace) a persistent session on CREATE.
    func record(slug: String,
                serviceID: UUID,
                instance: SessionInstance,
                displayName: String,
                command: String,
                cwd: String,
                isAgent: Bool) {
        records[slug] = TmuxSessionRecord(
            slug: slug,
            serviceID: serviceID,
            instance: SessionInstanceCoding(instance),
            displayName: displayName,
            command: command,
            cwd: cwd,
            isAgent: isAgent
        )
        persist()
    }

    /// Drop a record on delete / Stop reap.
    func forget(slug: String) {
        guard records[slug] != nil else { return }
        records[slug] = nil
        persist()
    }

    /// Reverse lookup — launch reattach + notification deep-link.
    func record(forSlug slug: String) -> TmuxSessionRecord? {
        records[slug]
    }

    /// Label for an orphan slug (record exists but its Service was deleted).
    func label(forOrphan slug: String) -> String? {
        records[slug]?.displayName
    }

    private func persist() {
        try? store.save(Array(records.values))
    }
}
