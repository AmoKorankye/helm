import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var supervisor: ProcessSupervisor

    // Selection is by ID, not by value: the model can mutate (rename, reorder)
    // without invalidating the selection, and it survives a store reload.
    @State private var selectedProjectID: UUID?
    @State private var selectedServiceID: UUID?

    // Sheet / inspector presentation.
    @State private var showAddProject = false
    @State private var addServiceTargetProjectID: UUID?
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedProjectID: $selectedProjectID,
                selectedServiceID: $selectedServiceID,
                onAddProject: { showAddProject = true },
                onAddService: { addServiceTargetProjectID = $0 },
                onDeleteService: { serviceID, projectID in
                    deleteService(id: serviceID, in: projectID)
                },
                onDeleteProject: { deleteProject(id: $0) },
                onStartService: { service, project in
                    startService(service, in: project)
                },
                onStopService: { service in
                    stopService(service)
                },
                onRestartService: { service, project in
                    restartService(service, in: project)
                }
            )
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Toggle inspector")
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(
                selectedProjectID: selectedProjectID,
                selectedServiceID: selectedServiceID
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .sheet(isPresented: $showAddProject) {
            AddProjectSheet { newProject in
                store.addProject(newProject)
            }
        }
        .sheet(item: addServiceSheetItem) { item in
            AddServiceSheet(projectID: item.projectID) { newService in
                store.addService(newService, to: item.projectID)
            }
        }
        // Inspector wired in checkpoint 9.
    }

    @ViewBuilder
    private var detail: some View {
        if let sel = store.service(id: selectedServiceID) {
            // Create-or-return the long-lived session, then host it. The session
            // (and its PTY/process) outlives this view, so switching services no
            // longer tears it down. No `.id()`.
            let session = sessions.session(for: sel.service, in: sel.project)
            let key = SessionKey(serviceID: sel.service.id, instance: .primary)
            SessionHostView(manager: sessions, selectedKey: key)
                .overlay {
                    RestartOverlay(session: session) {
                        manualRestart(
                            key: key,
                            command: sel.service.command,
                            workingDirectory: sel.project.directory
                        )
                    }
                }
        } else {
            WelcomeView()
        }
    }

    // MARK: - Per-service actions (driven by sidebar-row hover controls)

    /// Start (or relaunch in place) a service and select it so the terminal shows.
    /// If a dead session already exists for the key, `rebuild` it so it relaunches
    /// under the same `SessionKey` (surface swapped in place); otherwise
    /// create-or-return spawns a fresh one.
    private func startService(_ service: Service, in project: Project) {
        let key = SessionKey(serviceID: service.id, instance: .primary)
        // A deliberate start must not race a pending auto-restart/backoff.
        supervisor.cancel(key)
        if let existing = sessions.session(for: key), isDead(existing.status) {
            sessions.rebuild(
                key: key,
                command: service.command,
                workingDirectory: project.directory
            )
        } else {
            _ = sessions.session(for: service, in: project)
        }
        selectedProjectID = project.id
        selectedServiceID = service.id
    }

    /// Stop a service's session. Mirrors the old toolbar Stop: cancel any pending
    /// backoff (so the `.exited(byUser:true)` doesn't auto-restart) then `stop`,
    /// which KEEPS the session in the dict (never `close`). Selection unchanged.
    private func stopService(_ service: Service) {
        let key = SessionKey(serviceID: service.id, instance: .primary)
        supervisor.cancel(key)
        sessions.stop(key)
    }

    /// Restart a service's session in place. Selection unchanged.
    private func restartService(_ service: Service, in project: Project) {
        manualRestart(
            key: SessionKey(serviceID: service.id, instance: .primary),
            command: service.command,
            workingDirectory: project.directory
        )
    }

    /// A session is "dead" (relaunchable) when it has exited or crashed.
    private func isDead(_ status: SessionStatus) -> Bool {
        switch status {
        case .exited, .crashed: return true
        default: return false
        }
    }

    /// Manual restart (overlay / row control): cancel any supervisor backoff+reset for
    /// the key (a deliberate restart shouldn't race an auto-restart and should
    /// clear the attempt counter), then rebuild in place with current saved config.
    private func manualRestart(key: SessionKey, command: String, workingDirectory: String) {
        supervisor.cancel(key)
        sessions.rebuild(key: key, command: command, workingDirectory: workingDirectory)
    }

    // MARK: - Coordination (the only place SessionManager + store meet)

    private func deleteService(id serviceID: UUID, in projectID: UUID) {
        let affected = store.deleteService(id: serviceID, from: projectID)
        affected.forEach { supervisor.cancel($0); sessions.close($0) }
        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }
    }

    private func deleteProject(id projectID: UUID) {
        let affected = store.deleteProject(id: projectID)
        affected.forEach { supervisor.cancel($0); sessions.close($0) }
        if selectedProjectID == projectID {
            selectedProjectID = nil
            selectedServiceID = nil
        }
    }

    // Bridges the `UUID?` target into a `.sheet(item:)`-compatible Identifiable.
    private var addServiceSheetItem: Binding<AddServiceTarget?> {
        Binding(
            get: { addServiceTargetProjectID.map(AddServiceTarget.init) },
            set: { addServiceTargetProjectID = $0?.projectID }
        )
    }
}

/// Identifiable wrapper so the add-service sheet can bind to a target project.
private struct AddServiceTarget: Identifiable {
    let projectID: UUID
    var id: UUID { projectID }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a service")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Choose a project and service from the sidebar")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
