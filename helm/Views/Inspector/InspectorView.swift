import SwiftUI

/// The inspector edits the current selection: a service if one is selected,
/// otherwise its project, otherwise nothing. It reads the live model from the
/// store and writes edits back through `updateService` / `updateProject`. It
/// never imports GhosttyTerminal; it only reads value-typed metadata off a
/// `TerminalSession` to detect drift for the "restart to apply" banner.
struct InspectorView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionManager

    let selectedProjectID: UUID?
    let selectedServiceID: UUID?

    var body: some View {
        Group {
            if let sel = store.service(id: selectedServiceID) {
                // `.id` re-seeds the editor's draft when the selection changes.
                ServiceInspector(service: sel.service, project: sel.project)
                    .id(sel.service.id)
            } else if let project = store.project(id: selectedProjectID) {
                ProjectInspector(project: project)
                    .id(project.id)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing selected")
                .foregroundStyle(.secondary)
            Text("Select a project or service to edit it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Project inspector

private struct ProjectInspector: View {
    @EnvironmentObject private var store: ProjectStore
    let project: Project

    @State private var draft: ProjectDraft
    @State private var errors: [ValidationError] = []

    init(project: Project) {
        self.project = project
        _draft = State(initialValue: ProjectDraft(from: project))
    }

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $draft.name)
                errorText(for: .name)

                HStack {
                    Text(draft.directory.isEmpty ? "No directory" : draft.directory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        if let picked = DirectoryPicker.pickDirectory(startingAt: draft.directory) {
                            draft.directory = picked
                        }
                    }
                }
                errorText(for: .directory)
            }

            Section {
                Button("Save") { save() }
                    .disabled(!isDirty)
            }
        }
        .formStyle(.grouped)
    }

    private var isDirty: Bool {
        draft.name != project.name || draft.directory != project.directory
    }

    @ViewBuilder
    private func errorText(for field: ValidationError.Field) -> some View {
        if let error = errors.first(where: { $0.field == field }) {
            Text(error.message).font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        errors = draft.validate()
        guard errors.isEmpty else { return }
        var updated = project
        draft.apply(to: &updated)
        store.updateProject(updated)
    }
}

// MARK: - Service inspector

private struct ServiceInspector: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionManager

    let service: Service
    let project: Project

    @State private var draft: ServiceDraft
    @State private var errors: [ValidationError] = []

    init(service: Service, project: Project) {
        self.service = service
        self.project = project
        _draft = State(initialValue: ServiceDraft(from: service))
    }

    var body: some View {
        Form {
            if let banner = restartBanner {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Restart to apply", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                        Text(banner.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Restart Session") {
                            sessions.close(banner.key)
                        }
                    }
                }
            }

            Section("Service") {
                TextField("Name", text: $draft.name)
                errorText(for: .name)

                TextField("Command (empty = shell)", text: $draft.command)
                Toggle("Auto-start with the app", isOn: $draft.autoStart)
            }

            Section {
                Button("Save") { save() }
                    .disabled(!isDirty)
            }
        }
        .formStyle(.grouped)
    }

    private var isDirty: Bool {
        draft.name != service.name
            || draft.command != service.command
            || draft.autoStart != service.autoStart
    }

    /// Drift detection: if a live session exists for this service and its spawned
    /// command/cwd differ from what's saved, surface a restart affordance.
    private var restartBanner: (key: SessionKey, message: String)? {
        let key = SessionKey(serviceID: service.id, instance: .primary)
        guard let session = sessions.session(for: key) else { return nil }
        let commandDrift = session.command != service.command
        let dirDrift = session.workingDirectory != project.directory
        guard commandDrift || dirDrift else { return nil }
        return (key, "The running session was started with a different command or directory. Restart to pick up the saved settings.")
    }

    @ViewBuilder
    private func errorText(for field: ValidationError.Field) -> some View {
        if let error = errors.first(where: { $0.field == field }) {
            Text(error.message).font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        errors = draft.validate()
        guard errors.isEmpty else { return }
        var updated = service
        draft.apply(to: &updated)
        store.updateService(updated, in: project.id)
    }
}
