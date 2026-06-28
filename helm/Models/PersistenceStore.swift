import Foundation

/// Reads/writes the project list as JSON. Pure Foundation — no SwiftUI, no
/// GhosttyTerminal (HANDOVER §9, decision 6: persistence is a deep module split
/// out of the old AppStore). Atomic temp+swap and the support-dir resolution now
/// live in the shared `JSONFileStore`; this is a thin policy shim that keeps the
/// `[Project]` (non-optional, missing → `[]`) shape `ProjectStore` expects.
struct PersistenceStore {
    private let store: JSONFileStore<[Project]>

    nonisolated init(fileURL: URL? = nil) {
        if let fileURL {
            store = JSONFileStore(filename: fileURL.lastPathComponent,
                                  directory: fileURL.deletingLastPathComponent())
        } else {
            store = JSONFileStore(filename: "projects.json")
        }
    }

    /// Missing or empty file → `[]` (first launch). A present-but-corrupt file
    /// throws so the caller can decide (we never silently clobber real data).
    func load() throws -> [Project] {
        try store.load() ?? []
    }

    /// Atomic save (temp sibling + swap), delegated to `JSONFileStore`.
    func save(_ projects: [Project]) throws {
        try store.save(projects)
    }
}
