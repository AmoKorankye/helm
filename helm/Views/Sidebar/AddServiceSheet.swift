import SwiftUI

/// Modal sheet for adding a service to a project. No directory field — a service
/// inherits the project's directory. Validation lives in `ServiceDraft`.
struct AddServiceSheet: View {
    let projectID: UUID
    let onCommit: (Service) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ServiceDraft()
    @State private var errors: [ValidationError] = []

    /// Resolved once (not per `body` read): `isAvailable` does up to 3 disk probes.
    private let tmuxAvailable = TmuxService().isAvailable

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Service")
                .font(HelmFont.app.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(HelmFont.app).foregroundStyle(.secondary)
                TextField("claude", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                FieldError(errors: errors, field: .name)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(HelmFont.app).foregroundStyle(.secondary)
                TextField("Leave empty for a plain shell", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
                Text("Empty command opens a shell in the project directory.")
                    .font(HelmFont.app)
                    .foregroundStyle(.tertiary)
            }

            Toggle("Auto-start with the app", isOn: $draft.autoStart)
            Toggle("Run per git worktree", isOn: $draft.worktreeEnabled)
            Toggle("Persistent (survives app close)", isOn: $draft.persistent)
                .disabled(!tmuxAvailable)
            if !tmuxAvailable {
                Text("Requires tmux — `brew install tmux`.")
                    .font(HelmFont.app)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        errors = draft.validate()
        guard errors.isEmpty else { return }
        onCommit(draft.makeService())
        dismiss()
    }
}
