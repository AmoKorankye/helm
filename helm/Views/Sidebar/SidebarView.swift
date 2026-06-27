import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var sessions: SessionManager
    @Binding var selectedProjectID: UUID?
    @Binding var selectedServiceID: UUID?

    // Injected coordination closures. The sidebar stays dumb: it never touches
    // SessionManager and never deletes from the store directly — deletes and
    // adds route up to ContentView, which owns session teardown.
    let onAddProject: () -> Void
    let onAddService: (UUID) -> Void
    let onDeleteService: (UUID, UUID) -> Void
    let onDeleteProject: (UUID) -> Void
    // Per-service lifecycle actions (revealed on row hover). Still dumb: the row
    // only reports intent; ContentView owns SessionManager/supervisor coordination.
    let onStartService: (Service, Project) -> Void
    let onStopService: (Service) -> Void
    let onRestartService: (Service, Project) -> Void

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
                            isSelected: selectedServiceID == service.id,
                            session: sessions.session(for: SessionKey(serviceID: service.id, instance: .primary)),
                            onStart: { onStartService(service, project) },
                            onStop: { onStopService(service) },
                            onRestart: { onRestartService(service, project) }
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
    /// The live session for this service, if one exists. Passed in (not looked up
    /// here) so the row stays dumb. When present, its status drives the dot.
    let session: TerminalSession?
    // Intent callbacks for the hover-revealed lifecycle controls.
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @State private var isHovering = false

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
            // Hover controls (start/stop/restart) appear on hover; the status dot
            // is always visible. `ServiceControls` observes the session so the
            // button set tracks status with zero polling.
            ServiceControls(
                session: session,
                showControls: isHovering,
                onStart: onStart,
                onStop: onStop,
                onRestart: onRestart
            )
        }
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }
}

/// Trailing controls for a service row: a hover-revealed set of lifecycle buttons
/// plus an always-visible status dot. Observes the session (`@ObservedObject`)
/// when present so the visible button set (and dot color) repaint on status
/// changes alone — event-driven (ghostty's `terminalDidClose`), no timer. Stays
/// GhosttyTerminal-free: it only touches `TerminalSession`/`SessionStatus`, never
/// builds a terminal.
private struct ServiceControls: View {
    let session: TerminalSession?
    let showControls: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    var body: some View {
        if let session {
            // Observe the live session so buttons follow its status.
            ObservingControls(
                session: session,
                showControls: showControls,
                onStart: onStart,
                onStop: onStop,
                onRestart: onRestart
            )
        } else {
            // No session yet: only a Play button (on hover); no dot.
            HStack(spacing: 6) {
                if showControls {
                    ControlButton(symbol: "play.fill", help: "Start", action: onStart)
                }
            }
        }
    }
}

private struct ObservingControls: View {
    @ObservedObject var session: TerminalSession
    let showControls: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    private var isLive: Bool {
        switch session.status {
        case .starting, .running: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if showControls {
                if isLive {
                    ControlButton(symbol: "stop.fill", help: "Stop", action: onStop)
                } else {
                    ControlButton(symbol: "play.fill", help: "Start", action: onStart)
                }
                // A session exists in any state → restart is always available.
                ControlButton(symbol: "arrow.clockwise", help: "Restart", action: onRestart)
            }
            // Status dot is always visible, even when not hovering.
            StatusDot(session: session)
        }
    }
}

/// A small, secondary-styled control button with its own hit area so clicking it
/// does not fall through to the row's tap-to-select gesture.
private struct ControlButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// Zero-poll status indicator. Observes one `TerminalSession` (`@ObservedObject`)
/// and repaints ONLY when its `@Published status` changes — driven by ghostty's
/// surface-lifecycle callback (`terminalDidClose`) or an explicit
/// start/stop/restart, never a timer. Color derives from `status` alone (grill m3).
private struct StatusDot: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(helpText)
    }

    private var color: Color {
        switch session.status {
        case .starting: return .yellow
        case .running:  return .green
        case .exited:   return .gray
        case .crashed:  return .red
        case .detached: return .blue
        }
    }

    private var helpText: String {
        switch session.status {
        case .starting: return "Starting…"
        case .running:  return "Running"
        case let .exited(code, byUser):
            if byUser { return "Stopped" }
            return code.map { "Exited (code \($0))" } ?? "Exited"
        case let .crashed(reason):
            switch reason {
            case let .exited(code): return "Crashed (exit \(code))"
            case let .signalled(sig): return "Crashed (signal \(sig))"
            case .unknown: return "Crashed"
            }
        case .detached: return "Detached"
        }
    }
}
