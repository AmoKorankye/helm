import SwiftUI

/// Renders the red caption for the first validation error matching `field`, or
/// nothing. Shared by the add sheets and the inspectors so the identical
/// `errorText(for:)` helper isn't duplicated. GhosttyTerminal-free (Views layer).
struct FieldError: View {
    let errors: [ValidationError]
    let field: ValidationError.Field

    var body: some View {
        if let error = errors.first(where: { $0.field == field }) {
            Text(error.message)
                .font(HelmFont.app)
                .foregroundStyle(.red)
        }
    }
}
