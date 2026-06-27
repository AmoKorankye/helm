import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @Binding var selectedProjectID: UUID?
    @Binding var selectedServiceID: UUID?

    // Injected coordination closures. The sidebar stays dumb: it never touches
    // SessionManager and never deletes from the store directly — deletes and
    // adds route up to ContentView, which owns session teardown.
    let onAddProject: () -> Void
    let onAddService: (UUID) -> Void
    let onDeleteService: (UUID, UUID) -> Void
    let onDeleteProject: (UUID) -> Void

    // Pending confirmation targets for destructive actions.
    @State private var serviceToDelete: ServiceDeletion?
    @State private var projectToDelete: ProjectDeletion?

    private var sortedProjects: [Project] {
        store.projects.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        List {
            ForEach(sortedProjects) { project in
                Section {
                    let services = project.services.sorted { $0.sortOrder < $1.sortOrder }
                    ForEach(services) { service in
                        ServiceRow(
                            service: service,
                            isSelected: selectedServiceID == service.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProjectID = project.id
                            selectedServiceID = service.id
                        }
                        .contextMenu {
                            Button("Add Service…") { onAddService(project.id) }
                            Divider()
                            Button("Delete Service", role: .destructive) {
                                serviceToDelete = ServiceDeletion(
                                    serviceID: service.id,
                                    projectID: project.id,
                                    name: service.name
                                )
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        store.moveServices(in: project.id, from: offsets, to: destination)
                    }
                } header: {
                    HStack {
                        Text(project.name)
                            .font(.subheadline.weight(.semibold))
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            onAddService(project.id)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Add service to \(project.name)")
                    }
                    .contextMenu {
                        Button("Add Service…") { onAddService(project.id) }
                        Divider()
                        Button("Delete Project", role: .destructive) {
                            projectToDelete = ProjectDeletion(projectID: project.id, name: project.name)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Helm")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddProject) {
                    Image(systemName: "plus")
                }
                .help("Add project")
            }
        }
        .confirmationDialog(
            "Delete service “\(serviceToDelete?.name ?? "")”?",
            isPresented: serviceDeleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = serviceToDelete {
                    onDeleteService(target.serviceID, target.projectID)
                }
                serviceToDelete = nil
            }
            Button("Cancel", role: .cancel) { serviceToDelete = nil }
        } message: {
            Text("This stops and removes the service. Any running terminal is closed.")
        }
        .confirmationDialog(
            "Delete project “\(projectToDelete?.name ?? "")”?",
            isPresented: projectDeleteBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = projectToDelete {
                    onDeleteProject(target.projectID)
                }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("This removes the project and all its services. Any running terminals are closed.")
        }
    }

    private var serviceDeleteBinding: Binding<Bool> {
        Binding(
            get: { serviceToDelete != nil },
            set: { if !$0 { serviceToDelete = nil } }
        )
    }

    private var projectDeleteBinding: Binding<Bool> {
        Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )
    }
}

private struct ServiceDeletion: Identifiable {
    let serviceID: UUID
    let projectID: UUID
    let name: String
    var id: UUID { serviceID }
}

private struct ProjectDeletion: Identifiable {
    let projectID: UUID
    let name: String
    var id: UUID { projectID }
}

struct ServiceRow: View {
    let service: Service
    let isSelected: Bool

    private var icon: String {
        service.command.isEmpty ? "terminal" : "play.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            Text(service.name)
                .font(.system(size: 13))
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
