import Foundation

/// Reads/writes the launch-preset library as JSON. SEPARATE from `PersistenceStore`
/// (m4 — do NOT graft preset I/O onto the single-URL projects store), with its own
/// injectable `fileURL` (`~/Library/Application Support/Helm/presets.json`).
/// Mirrors `PersistenceStore`'s atomic temp+swap exactly. Pure Foundation — no
/// SwiftUI, no GhosttyTerminal.
struct PresetPersistenceStore {
    private let fileURL: URL

    nonisolated init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let dir = support.appendingPathComponent("Helm", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("presets.json")
        }
    }

    /// Returns `nil` ONLY when the file does NOT exist (first launch → the caller
    /// seeds builtins, m5). A present-but-empty file returns `[]` (user deleted all
    /// — do NOT reseed). A corrupt file THROWS so the caller can keep the user's
    /// real presets rather than silently reseed over them (m5 / §6.8).
    func load() throws -> [LaunchPreset]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([LaunchPreset].self, from: data)
    }

    /// Atomic save: write to a sibling temp file, then swap it into place so a crash
    /// mid-write can never leave a half-written presets.json.
    func save(_ presets: [LaunchPreset]) throws {
        let data = try JSONEncoder().encode(presets)
        let dir = fileURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent("presets.json.\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
