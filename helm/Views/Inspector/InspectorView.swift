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
    /// Which session instance the detail pane currently shows — the restart banner
    /// is per-session, so it must compare against THIS instance's resolved cwd.
    let selectedInstance: SessionInstance

    var body: some View {
        Group {
            if let sel = store.service(id: selectedServiceID) {
                // `.id` re-seeds the editor's draft when the selection changes.
                ServiceInspector(service: sel.service, project: sel.project, instance: selectedInstance)
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
    @EnvironmentObject private var worktrees: WorktreeStore
    @EnvironmentObject private var supervisor: ProcessSupervisor

    let service: Service
    let project: Project
    let instance: SessionInstance

    @State private var draft: ServiceDraft
    @State private var errors: [ValidationError] = []

    init(service: Service, project: Project, instance: SessionInstance) {
        self.service = service
        self.project = project
        self.instance = instance
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
                            // Real restart (grill m4): rebuild-in-place under the
                            // same key with the CURRENT saved command/dir, so the
                            // running session picks up the edits. Replaces the
                            // Phase-2 close+reselect stub. Cancel any supervisor
                            // backoff so a manual restart wins the race.
                            supervisor.cancel(banner.key)
                            let cwd = worktrees.workingDirectory(for: instance, in: project)
                                      ?? project.directory
                            sessions.rebuild(
                                key: banner.key,
                                command: service.command,
                                workingDirectory: cwd
                            )
                        }
                    }
                }
            }

            Section("Service") {
                TextField("Name", text: $draft.name)
                errorText(for: .name)

                TextField("Command (empty = shell)", text: $draft.command)
                Toggle("Auto-start with the app", isOn: $draft.autoStart)
                Picker("Auto-restart", selection: $draft.restartPolicy) {
                    ForEach(RestartPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Toggle("Run per git worktree", isOn: $draft.worktreeEnabled)
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
            || draft.restartPolicy != service.restartPolicy
            || draft.worktreeEnabled != service.worktreeEnabled
    }

    /// Drift detection (instance-aware, grill M1): if the live session for THIS
    /// instance was spawned with a command/cwd differing from the saved settings,
    /// surface a restart affordance. The expected cwd for `.primary` is
    /// `project.directory` VERBATIM (never the scan's symlink-resolved path), so a
    /// `/tmp` vs `/private/tmp` mismatch can no longer raise a false banner.
    private var restartBanner: (key: SessionKey, message: String)? {
        let key = SessionKey(serviceID: service.id, instance: instance)
        guard let session = sessions.session(for: key) else { return nil }
        let expectedCwd = worktrees.workingDirectory(for: instance, in: project)
                          ?? project.directory
        let commandDrift = session.command != service.command
        let dirDrift = session.workingDirectory != expectedCwd
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
