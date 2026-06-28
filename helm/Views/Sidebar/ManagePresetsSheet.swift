import SwiftUI

/// Manage the global launch-preset library: list + add/edit/delete/reorder, bound
/// to `PresetStore` (mirrors `AddServiceSheet`'s shape). GhosttyTerminal-free.
struct ManagePresetsSheet: View {
    @EnvironmentObject private var presets: PresetStore
    @Environment(\.dismiss) private var dismiss

    /// The preset currently being edited in the inline form (nil = the add form).
    @State private var draft = PresetDraft()
    @State private var editingID: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Launch Presets")
                .font(.headline)

            // Existing presets.
            if presets.sorted.isEmpty {
                Text("No presets. Add one below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(presets.sorted) { preset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.system(size: 13, weight: .medium))
                                Text(preset.command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                beginEdit(preset)
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Edit")
                            Button(role: .destructive) {
                                presets.delete(id: preset.id)
                                if editingID == preset.id { resetForm() }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete")
                        }
                    }
                    .onMove { offsets, destination in
                        presets.move(from: offsets, to: destination)
                    }
                }
                .frame(height: 180)
            }

            Divider()

            // Add / edit form.
            Text(editingID == nil ? "New Preset" : "Edit Preset")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Claude (resume)", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextField("claude --resume", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Agent kind", selection: $draft.agentKind) {
                ForEach(AgentKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if editingID != nil {
                    Button("Cancel Edit") { resetForm() }
                }
                Spacer()
                Button(editingID == nil ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func beginEdit(_ preset: LaunchPreset) {
        editingID = preset.id
        draft = PresetDraft(name: preset.name, command: preset.command, agentKind: preset.agentKind)
        error = nil
    }

    private func resetForm() {
        editingID = nil
        draft = PresetDraft()
        error = nil
    }

    private func commit() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { error = "Name is required."; return }
        let command = draft.command.trimmingCharacters(in: .whitespaces)
        if let editingID,
           var existing = presets.presets.first(where: { $0.id == editingID }) {
            existing.name = name
            existing.command = command
            existing.agentKind = draft.agentKind
            presets.update(existing)
        } else {
            presets.add(LaunchPreset(name: name, command: command, agentKind: draft.agentKind))
        }
        resetForm()
    }
}

private struct PresetDraft {
    var name: String = ""
    var command: String = ""
    var agentKind: AgentKind = .claude
}
