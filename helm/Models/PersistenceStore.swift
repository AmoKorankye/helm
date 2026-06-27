import Foundation

/// Reads/writes the project list as JSON. Pure Foundation — no SwiftUI, no
/// GhosttyTerminal (HANDOVER §9, decision 6: persistence is a deep module split
/// out of the old AppStore). Writes are ATOMIC (temp file + `replaceItemAt`), an
/// upgrade over AppStore's naked `data.write`.
struct PersistenceStore {
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
            self.fileURL = dir.appendingPathComponent("projects.json")
        }
    }

    /// Missing or empty file → `[]` (first launch). A present-but-corrupt file
    /// throws so the caller can decide (we never silently clobber real data).
    func load() throws -> [Project] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([Project].self, from: data)
    }

    /// Atomic save: write to a sibling temp file, then swap it into place so a
    /// crash mid-write can never leave a half-written projects.json.
    func save(_ projects: [Project]) throws {
        let data = try JSONEncoder().encode(projects)
        let dir = fileURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent("projects.json.\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
