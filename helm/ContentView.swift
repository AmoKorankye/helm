import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var worktrees: WorktreeStore
    @EnvironmentObject private var supervisor: ProcessSupervisor

    // Selection is by ID, not by value: the model can mutate (rename, reorder)
    // without invalidating the selection, and it survives a store reload.
    @State private var selectedProjectID: UUID?
    @State private var selectedServiceID: UUID?
    // Phase 4: a service can now have N concurrent sessions (one per worktree), so
    // selection must carry WHICH instance is shown in the detail pane.
    @State private var selectedInstance: SessionInstance = .primary

    // Sheet / inspector presentation.
    @State private var showAddProject = false
    @State private var addServiceTargetProjectID: UUID?
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedProjectID: $selectedProjectID,
                selectedServiceID: $selectedServiceID,
                selectedInstance: $selectedInstance,
                onAddProject: { showAddProject = true },
                onAddService: { addServiceTargetProjectID = $0 },
                onDeleteService: { serviceID, projectID in
                    deleteService(id: serviceID, in: projectID)
                },
                onDeleteProject: { deleteProject(id: $0) },
                onStartService: { service, project, instance in
                    startService(service, in: project, instance: instance)
                },
                onStopService: { service, instance in
                    stopService(service, instance: instance)
                },
                onRestartService: { service, project, instance in
                    restartService(service, in: project, instance: instance)
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
                selectedServiceID: selectedServiceID,
                selectedInstance: selectedInstance
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
        // Zero-poll worktree refresh: re-scan ONLY when the selected project
        // changes (the §3 selection trigger). No interval timer ever scans git.
        .task(id: selectedProjectID) {
            guard let project = store.project(id: selectedProjectID) else { return }
            await worktrees.refresh(project)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let sel = store.service(id: selectedServiceID) {
            // Create-or-return the long-lived session, then host it. The session
            // (and its PTY/process) outlives this view, so switching services no
            // longer tears it down. No `.id()`.
            //
            // §8.5 / m8: validate the selected instance BEFORE create-or-return so a
            // vanished/prunable worktree never spawns a junk session in project root.
            let instance = resolveSelectedInstance(service: sel.service, project: sel.project)
            let key = SessionKey(serviceID: sel.service.id, instance: instance)
            let cwd = worktrees.workingDirectory(for: instance, in: sel.project)
                      ?? sel.project.directory
            let session = sessions.session(
                forServiceID: sel.service.id,
                instance: instance,
                command: sel.service.command,
                workingDirectory: cwd
            )
            SessionHostView(manager: sessions, selectedKey: key)
                .overlay {
                    RestartOverlay(session: session) {
                        manualRestart(
                            key: key,
                            command: sel.service.command,
                            workingDirectory: cwd
                        )
                    }
                }
        } else {
            WelcomeView()
        }
    }

    /// Validate the selected instance for the detail pane (grill m8). `.primary`
    /// is always valid. A `.worktree(...)` instance is valid only if it's still a
    /// spawnable child in the latest scan OR already has a live session (so a
    /// running-but-now-prunable worktree stays reachable, §8.1). Otherwise fall
    /// back to `.primary` so create-or-return never spawns a stray session in the
    /// project root.
    private func resolveSelectedInstance(service: Service, project: Project) -> SessionInstance {
        if case .primary = selectedInstance { return .primary }
        let key = SessionKey(serviceID: service.id, instance: selectedInstance)
        if sessions.session(for: key) != nil { return selectedInstance }
        let scan = worktrees.scan(for: project.id)
        let stillAChild = scan?.fanOutChildren.contains {
            $0.sessionInstance() == selectedInstance
        } ?? false
        return stillAChild ? selectedInstance : .primary
    }

    // MARK: - Per-service actions (driven by sidebar-row hover controls)

    /// Start (or relaunch in place) a service and select it so the terminal shows.
    /// If a dead session already exists for the key, `rebuild` it so it relaunches
    /// under the same `SessionKey` (surface swapped in place); otherwise
    /// create-or-return spawns a fresh one.
    private func startService(_ service: Service, in project: Project, instance: SessionInstance) {
        let key = SessionKey(serviceID: service.id, instance: instance)
        let cwd = worktrees.workingDirectory(for: instance, in: project) ?? project.directory
        // A deliberate start must not race a pending auto-restart/backoff.
        supervisor.cancel(key)
        if let existing = sessions.session(for: key), isDead(existing.status) {
            sessions.rebuild(
                key: key,
                command: service.command,
                workingDirectory: cwd
            )
        } else {
            _ = sessions.session(
                forServiceID: service.id,
                instance: instance,
                command: service.command,
                workingDirectory: cwd
            )
        }
        selectedProjectID = project.id
        selectedServiceID = service.id
        selectedInstance = instance
    }

    /// Stop a service's session. Mirrors the old toolbar Stop: cancel any pending
    /// backoff (so the `.exited(byUser:true)` doesn't auto-restart) then `stop`,
    /// which KEEPS the session in the dict (never `close`). Selection unchanged.
    private func stopService(_ service: Service, instance: SessionInstance) {
        let key = SessionKey(serviceID: service.id, instance: instance)
        supervisor.cancel(key)
        sessions.stop(key)
    }

    /// Restart a service's session in place. Selection unchanged. Restart of an
    /// orphaned/vanished worktree is DISABLED (grill m12): when the cwd cannot be
    /// resolved AND there's no live session, do nothing — never relocate to the
    /// project root, which could relaunch in the wrong tree.
    private func restartService(_ service: Service, in project: Project, instance: SessionInstance) {
        let key = SessionKey(serviceID: service.id, instance: instance)
        guard let cwd = restartCwd(for: instance, in: project, key: key) else { return }
        manualRestart(key: key, command: service.command, workingDirectory: cwd)
    }

    /// Resolve a SAFE cwd for restarting an instance. `.primary` → project.directory.
    /// A worktree instance → its resolved path; if it has vanished (nil) we fall
    /// back to the cwd the LIVE session already launched with (so an
    /// already-running, now-prunable worktree can still restart in its real path),
    /// otherwise return nil to DISABLE restart (m12 — no wrong-tree relaunch).
    private func restartCwd(for instance: SessionInstance, in project: Project, key: SessionKey) -> String? {
        if let resolved = worktrees.workingDirectory(for: instance, in: project) {
            return resolved
        }
        if let live = sessions.session(for: key) {
            return live.workingDirectory
        }
        return nil
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
        let ids = store.deleteService(id: serviceID, from: projectID)        // now [UUID]
        let keys = sessions.keys(forServiceIDs: Set(ids))                    // live keys (B1)
        keys.forEach { supervisor.cancel($0); sessions.close($0) }
        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }
    }

    private func deleteProject(id projectID: UUID) {
        let ids = store.deleteProject(id: projectID)                        // now [UUID]
        let keys = sessions.keys(forServiceIDs: Set(ids))                   // live keys (B1)
        keys.forEach { supervisor.cancel($0); sessions.close($0) }
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
