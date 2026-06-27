import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var selectedProject: Project?
    @State private var selectedService: Service?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedProject: $selectedProject,
                selectedService: $selectedService
            )
            .environmentObject(store)
        } detail: {
            if let project = selectedProject, let service = selectedService {
                HelmTerminalPane(project: project, service: service)
                    .id(service.id)
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
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
