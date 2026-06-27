import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionManager

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
                onDeleteProject: { deleteProject(id: $0) }
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
            let _ = sessions.session(for: sel.service, in: sel.project)
            SessionHostView(
                manager: sessions,
                selectedKey: SessionKey(serviceID: sel.service.id, instance: .primary)
            )
        } else {
            WelcomeView()
        }
    }

    // MARK: - Coordination (the only place SessionManager + store meet)

    private func deleteService(id serviceID: UUID, in projectID: UUID) {
        let affected = store.deleteService(id: serviceID, from: projectID)
        affected.forEach { sessions.close($0) }
        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }
    }

    private func deleteProject(id projectID: UUID) {
        let affected = store.deleteProject(id: projectID)
        affected.forEach { sessions.close($0) }
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
