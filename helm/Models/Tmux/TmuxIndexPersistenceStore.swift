import Foundation

/// Reads/writes the authoritative tmux session index as JSON (M7). Its own file
/// (`~/Library/Application Support/Helm/sessions.json`), separate from projects/
/// presets. Atomic temp+swap, mirroring `PresetPersistenceStore`. Pure Foundation
/// — no SwiftUI, no GhosttyTerminal.
struct TmuxIndexPersistenceStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let dir = support.appendingPathComponent("Helm", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("sessions.json")
        }
    }

    /// Missing or empty file → `[]`. A corrupt file throws so the caller keeps the
    /// user's real records rather than silently clobbering. Uses `decodeIfPresent`
    /// semantics per-record via the synthesized decoder (all fields required, but a
    /// future additive field would be handled by adding `decodeIfPresent`).
    func load() throws -> [TmuxSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([TmuxSessionRecord].self, from: data)
    }

    func save(_ records: [TmuxSessionRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let dir = fileURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent("sessions.json.\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
