import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedProject: Project?
    @Binding var selectedService: Service?

    var body: some View {
        List {
            ForEach(store.projects) { project in
                Section {
                    ForEach(project.services) { service in
                        ServiceRow(
                            service: service,
                            isSelected: selectedService?.id == service.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProject = project
                            selectedService = service
                        }
                    }
                } header: {
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Helm")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Phase 2: add project sheet
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
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
