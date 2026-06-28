import Foundation

/// Reads/writes the authoritative tmux session index as JSON (M7). Its own file
/// (`~/Library/Application Support/Helm/sessions.json`), separate from projects/
/// presets. Atomic temp+swap and support-dir resolution live in the shared
/// `JSONFileStore`; this is a thin policy shim keeping the non-optional `[…]`
/// (missing → `[]`) shape `TmuxSessionIndex` expects. Pure Foundation — no SwiftUI,
/// no GhosttyTerminal.
struct TmuxIndexPersistenceStore {
    private let store: JSONFileStore<[TmuxSessionRecord]>

    nonisolated init(fileURL: URL? = nil) {
        if let fileURL {
            store = JSONFileStore(filename: fileURL.lastPathComponent,
                                  directory: fileURL.deletingLastPathComponent())
        } else {
            store = JSONFileStore(filename: "sessions.json")
        }
    }

    /// Missing or empty file → `[]`. A corrupt file throws so the caller keeps the
    /// user's real records rather than silently clobbering.
    func load() throws -> [TmuxSessionRecord] {
        try store.load() ?? []
    }

    /// Atomic save (temp sibling + swap), delegated to `JSONFileStore`.
    func save(_ records: [TmuxSessionRecord]) throws {
        try store.save(records)
    }
}
