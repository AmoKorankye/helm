import Foundation

/// Editable form-state for creating or editing a `Service`. A service inherits
/// its directory from the parent project, so there is no directory field here.
/// An empty command is valid — it means "just a shell" (HANDOVER §5/§6).
struct ServiceDraft {
    var name: String = ""
    var command: String = ""
    var autoStart: Bool = false

    init() {}

    init(from service: Service) {
        name = service.name
        command = service.command
        autoStart = service.autoStart
    }

    /// Name must be non-empty (trimmed). Command MAY be empty (= shell).
    func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ValidationError(field: .name, message: "Name is required."))
        }
        return errors
    }

    /// Apply edits onto an existing service, preserving identity, sort order, and
    /// environment (none of which this form edits).
    func apply(to service: inout Service) {
        service.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        service.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        service.autoStart = autoStart
    }

    func makeService() -> Service {
        Service(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            autoStart: autoStart
        )
    }
}
