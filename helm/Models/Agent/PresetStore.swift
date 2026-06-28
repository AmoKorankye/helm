import Foundation
import Combine

/// The source of truth for the GLOBAL launch-preset library. Mirrors `ProjectStore`:
/// `@Published private(set) var presets`, atomic-persisted via the SEPARATE
/// `PresetPersistenceStore` (m4). GhosttyTerminal-free; injected at the app root.
///
/// Seeding rule (m5): on `init`, `load()` distinguishes file-absent from
/// empty/corrupt —
///   - `nil`  (file absent)          → seed `LaunchPreset.builtins` + save them.
///   - `[]`   (present, user emptied) → keep empty, do NOT reseed.
///   - throws (corrupt)              → keep empty in memory, do NOT overwrite the
///                                     file (so a corrupt read never clobbers real
///                                     presets).
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [LaunchPreset] = []

    private let persistence: PresetPersistenceStore

    init(persistence: PresetPersistenceStore = PresetPersistenceStore()) {
        self.persistence = persistence
        do {
            if let loaded = try persistence.load() {
                presets = loaded              // file present ([] or populated): trust it.
            } else {
                presets = LaunchPreset.builtins   // file absent (first launch): seed.
                persist()
            }
        } catch {
            // Corrupt file: keep empty in memory, do NOT clobber the file (m5).
            presets = []
        }
    }

    // MARK: - Mutations (mirror ProjectStore)

    func add(_ preset: LaunchPreset) {
        var preset = preset
        preset.sortOrder = (presets.map(\.sortOrder).max() ?? -1) + 1
        presets.append(preset)
        persist()
    }

    func update(_ preset: LaunchPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i] = preset
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var ordered = presets.sorted { $0.sortOrder < $1.sortOrder }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for idx in ordered.indices {
            ordered[idx].sortOrder = idx
        }
        presets = ordered
        persist()
    }

    /// Presets in stable display order.
    var sorted: [LaunchPreset] {
        presets.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func persist() {
        try? persistence.save(presets)
    }
}
