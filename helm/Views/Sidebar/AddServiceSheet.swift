import SwiftUI

/// Modal sheet for adding a service to a project. No directory field — a service
/// inherits the project's directory. Validation lives in `ServiceDraft`.
struct AddServiceSheet: View {
    let projectID: UUID
    let onCommit: (Service) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ServiceDraft()
    @State private var errors: [ValidationError] = []

    private var tmuxAvailable: Bool { TmuxService().isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Service")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline).foregroundStyle(.secondary)
                TextField("claude", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                errorText(for: .name)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.subheadline).foregroundStyle(.secondary)
                TextField("Leave empty for a plain shell", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
                Text("Empty command opens a shell in the project directory.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Toggle("Auto-start with the app", isOn: $draft.autoStart)
            Toggle("Run per git worktree", isOn: $draft.worktreeEnabled)
            Toggle("Persistent (survives app close)", isOn: $draft.persistent)
                .disabled(!tmuxAvailable)
            if !tmuxAvailable {
                Text("Requires tmux — `brew install tmux`.")
                    .font(.caption)
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

    @ViewBuilder
    private func errorText(for field: ValidationError.Field) -> some View {
        if let error = errors.first(where: { $0.field == field }) {
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func save() {
        errors = draft.validate()
        guard errors.isEmpty else { return }
        onCommit(draft.makeService())
        dismiss()
    }
}
