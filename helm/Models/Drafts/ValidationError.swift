import Foundation

/// A single form-field validation failure. Produced by draft models' `validate()`
/// and consumed by sheets/inspector to render inline error text. Validation lives
/// in the draft models (HANDOVER §9, dec 11) — never in Views or persistence.
struct ValidationError: Identifiable, Equatable {
    let id = UUID()
    let field: Field
    let message: String

    enum Field {
        case name
        case command
        case directory
    }
}
