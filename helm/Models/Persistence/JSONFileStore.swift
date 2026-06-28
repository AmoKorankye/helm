import Foundation

/// The ONE home for Helm's atomic-JSON file persistence. A generic, pure-Foundation
/// value store that reads/writes a single `Codable` value as JSON under
/// `~/Library/Application Support/Helm/<filename>` with crash-safe atomic writes.
///
/// This unifies the three previously byte-identical concrete stores
/// (`PersistenceStore`/`PresetPersistenceStore`/`TmuxIndexPersistenceStore`). The
/// temp-file + swap logic — the part worth getting right exactly once — now lives
/// here, and only here. First-launch POLICY (seed-when-absent, empty-vs-corrupt)
/// stays with each consumer where it legitimately differs; this store only reports
/// the raw load result (`nil` for absent/empty, `throws` for corrupt).
///
/// `nonisolated` (and operating on `nonisolated` persisted value types) so it can be
/// used from any actor without main-actor-isolated-conformance warnings under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Foundation-only — no SwiftUI, no
/// GhosttyTerminal.
nonisolated struct JSONFileStore<T: Codable> {
    let fileURL: URL

    /// Resolves `~/Library/Application Support/Helm/<filename>` (creating the
    /// directory) by default. `directory` is overridable so tests can point at a
    /// temp dir — the same injectable seam the old stores exposed via `fileURL`.
    nonisolated init(filename: String, directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            dir = support.appendingPathComponent("Helm", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(filename)
    }

    /// Missing or empty file → `nil` (first launch). A present-but-corrupt file
    /// rethrows so the caller can decide — we NEVER silently clobber real data.
    nonisolated func load() throws -> T? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Atomic save: write to a sibling temp file, then swap it into place so a crash
    /// mid-write can never leave a half-written file. The `.tmp` name is derived from
    /// `fileURL.lastPathComponent` so it sorts/cleans next to its target.
    nonisolated func save(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let dir = fileURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(
            "\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
