import Foundation

/// Reads/writes the launch-preset library as JSON. SEPARATE file
/// (`~/Library/Application Support/Helm/presets.json`, m4). Atomic temp+swap and
/// support-dir resolution live in the shared `JSONFileStore`; this is a thin policy
/// shim that preserves the preset TRI-STATE the seeding rule (m5 / §6.8) depends on:
/// `nil` ONLY when the file is ABSENT (caller seeds builtins), `[]` when the file is
/// PRESENT-but-empty (user emptied — do NOT reseed), `throws` when corrupt (do NOT
/// clobber). Pure Foundation — no SwiftUI, no GhosttyTerminal.
struct PresetPersistenceStore {
    private let store: JSONFileStore<[LaunchPreset]>

    nonisolated init(fileURL: URL? = nil) {
        if let fileURL {
            store = JSONFileStore(filename: fileURL.lastPathComponent,
                                  directory: fileURL.deletingLastPathComponent())
        } else {
            store = JSONFileStore(filename: "presets.json")
        }
    }

    /// Returns `nil` ONLY when the file does NOT exist (first launch → the caller
    /// seeds builtins, m5). A present-but-empty file returns `[]` (user deleted all
    /// — do NOT reseed). A corrupt file THROWS so the caller keeps the user's real
    /// presets rather than silently reseed over them (m5 / §6.8). The shared store
    /// collapses absent and empty to `nil`, so we re-split them on file existence —
    /// the one place the preset tri-state legitimately diverges from the others.
    func load() throws -> [LaunchPreset]? {
        guard FileManager.default.fileExists(atPath: store.fileURL.path) else { return nil }
        return try store.load() ?? []
    }

    /// Atomic save (temp sibling + swap), delegated to `JSONFileStore`.
    func save(_ presets: [LaunchPreset]) throws {
        try store.save(presets)
    }
}
