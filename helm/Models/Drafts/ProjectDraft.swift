import Foundation

/// Editable form-state for creating or editing a `Project`. Owns its own
/// `validate()` so Views stay dumb (HANDOVER §9, dec 11). Pure value type — no
/// SwiftUI, no GhosttyTerminal.
struct ProjectDraft {
    var name: String = ""
    var directory: String = ""

    /// New, empty draft for the add-project sheet.
    init() {}

    /// Seed from an existing project for the inspector.
    init(from project: Project) {
        name = project.name
        directory = project.directory
    }

    /// Name must be non-empty (trimmed); directory must be non-empty AND point at
    /// an existing directory on disk.
    func validate() -> [ValidationError] {
        var errors: [ValidationError] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ValidationError(field: .name, message: "Name is required."))
        }

        let trimmedDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDir.isEmpty {
            errors.append(ValidationError(field: .directory, message: "Choose a directory."))
        } else {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: trimmedDir, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                errors.append(ValidationError(
                    field: .directory,
                    message: "That path isn’t an existing directory."
                ))
            }
        }

        return errors
    }

    /// Apply edits onto an existing project, preserving identity, services, and
    /// sort order (only the editable fields change).
    func apply(to project: inout Project) {
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a brand-new project from this draft.
    func makeProject() -> Project {
        Project(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
            services: []
        )
    }
}
