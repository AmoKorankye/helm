import SwiftUI

/// Modal sheet for creating a project. Validation is delegated entirely to
/// `ProjectDraft.validate()` — this view only renders fields, errors, and routes
/// the finished `Project` out via `onCommit` (HANDOVER §9, dec 11).
struct AddProjectSheet: View {
    let onCommit: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectDraft()
    @State private var errors: [ValidationError] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(HelmFont.app.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(HelmFont.app).foregroundStyle(.secondary)
                TextField("My Project", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                FieldError(errors: errors, field: .name)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Directory").font(HelmFont.app).foregroundStyle(.secondary)
                HStack {
                    Text(draft.directory.isEmpty ? "No directory chosen" : draft.directory)
                        .foregroundStyle(draft.directory.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        if let picked = DirectoryPicker.pickDirectory(startingAt: draft.directory) {
                            draft.directory = picked
                        }
                    }
                }
                FieldError(errors: errors, field: .directory)
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
        onCommit(draft.makeProject())
        dismiss()
    }
}
