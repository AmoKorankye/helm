import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var worktrees: WorktreeStore
    @EnvironmentObject var presets: PresetStore
    @EnvironmentObject var coordinator: PersistenceCoordinator
    @Binding var selectedProjectID: UUID?
    @Binding var selectedServiceID: UUID?
    @Binding var selectedInstance: SessionInstance

    let onAddProject: () -> Void
    let onAddService: (UUID) -> Void
    let onDeleteService: (UUID, UUID) -> Void
    let onDeleteProject: (UUID) -> Void
    let onStartService: (Service, Project, SessionInstance) -> Void
    let onStopService: (Service, SessionInstance) -> Void
    let onRestartService: (Service, Project, SessionInstance) -> Void
    let onLaunchPreset: (LaunchPreset) -> Void

    @State private var serviceToDelete: ServiceDeletion?
    @State private var projectToDelete: ProjectDeletion?
    @State private var showManagePresets = false
    @State private var expanded: Set<UUID> = []
    @State private var collapsedProjects: Set<UUID> = []
    @State private var hoveredProjectID: UUID?
    @State private var hoveredServiceKey: SessionKey?

    private var sortedProjects: [Project] {
        store.projects.sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            scrollContent
            footerBar
        }
        .background {
            // Native macOS sidebar vibrancy, clipped to the rounded panel shape.
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .clipShape(SidebarShape(cornerRadius: HelmRadius.panel))
                .ignoresSafeArea(.all)
        }
        .sheet(isPresented: $showManagePresets) { ManagePresetsSheet() }
        .confirmationDialog(
            "Delete service \"\(serviceToDelete?.name ?? "")\"?",
            isPresented: serviceDeleteBinding, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let t = serviceToDelete { onDeleteService(t.serviceID, t.projectID) }
                serviceToDelete = nil
            }
            Button("Cancel", role: .cancel) { serviceToDelete = nil }
        } message: {
            Text("This stops and removes the service. Any running terminal is closed.")
        }
        .confirmationDialog(
            "Delete project \"\(projectToDelete?.name ?? "")\"?",
            isPresented: projectDeleteBinding, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let t = projectToDelete { onDeleteProject(t.projectID) }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("This removes the project and all its services. Any running terminals are closed.")
        }
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sortedProjects) { project in
                    projectRow(project)

                    if !collapsedProjects.contains(project.id) {
                        let services = project.services.sorted { $0.sortOrder < $1.sortOrder }
                        ForEach(services) { service in
                            serviceEntry(service, in: project)
                        }
                    }
                }

                if !coordinator.orphans.isEmpty {
                    orphansSection
                }
            }
            .padding(.top, HelmSpacing.sm)
            .padding(.bottom, HelmSpacing.md)
        }
    }

    // MARK: - Project row

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        let isExpanded = !collapsedProjects.contains(project.id)
        let isHovered  = hoveredProjectID == project.id

        HStack(spacing: 0) {
            // Disclosure arrow — left of the icon; points right (closed) / down (open).
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.helmMeta)
                .rotationEffect(isExpanded ? .degrees(90) : .degrees(0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
                .frame(width: HelmLayout.rowChevronColumn, alignment: .center)
                .padding(.trailing, HelmLayout.rowChevronGap)

            ProjectIcon(name: project.name)
                .frame(width: HelmLayout.rowIconColumn, height: HelmLayout.rowIconColumn)
                .padding(.trailing, HelmLayout.rowIconGap)

            Text(project.name)
                .font(HelmFont.app.weight(.medium))
                .foregroundStyle(Color.helmText)
                .lineLimit(1)

            Spacer(minLength: 6)

            // Add-service button, appears on hover
            if isHovered {
                Button { onAddService(project.id) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.helmMeta)
                }
                .buttonStyle(.borderless)
                .help("Add service to \(project.name)")
            }
        }
        .padding(.vertical, HelmSpacing.rowV)
        .padding(.horizontal, HelmSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HelmRadius.md, style: .continuous)
                .fill(isHovered ? Color.helmBgHover : Color.clear)
        )
        .padding(.horizontal, HelmSpacing.xs)
        .contentShape(Rectangle())
        .onHover { hoveredProjectID = $0 ? project.id : nil }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsedProjects.contains(project.id) {
                    collapsedProjects.remove(project.id)
                } else {
                    collapsedProjects.insert(project.id)
                }
            }
            selectedProjectID = project.id
        }
        .contextMenu {
            Button("Add Service…") { onAddService(project.id) }
            Divider()
            Button("Delete Project", role: .destructive) {
                projectToDelete = ProjectDeletion(projectID: project.id, name: project.name)
            }
        }
    }

    // MARK: - Service entry

    @ViewBuilder
    private func serviceEntry(_ service: Service, in project: Project) -> some View {
        let scan       = worktrees.scan(for: project.id)
        let showFanOut = service.worktreeEnabled && (scan?.hasFanOut ?? false)

        if showFanOut, let children = scan?.fanOutChildren {
            serviceRow(service, project, instance: .primary, label: service.name,
                       spawnable: true,
                       refresh: { Task { await worktrees.refresh(project) } },
                       rollUp: expanded.contains(service.id) ? nil : childRollUp(service, children),
                       isFanOutParent: true)

            if expanded.contains(service.id) {
                ForEach(children) { wt in
                    serviceRow(service, project,
                               instance: wt.sessionInstance(),
                               label: wt.displayName,
                               spawnable: wt.isSpawnableChild,
                               refresh: nil, rollUp: nil,
                               isFanOutParent: false)
                }
            }
        } else {
            serviceRow(service, project, instance: .primary, label: service.name,
                       spawnable: true, refresh: nil, rollUp: nil, isFanOutParent: false)
        }
    }

    @ViewBuilder
    private func serviceRow(_ service: Service,
                            _ project: Project,
                            instance: SessionInstance,
                            label: String,
                            spawnable: Bool,
                            refresh: (() -> Void)?,
                            rollUp: RollUpStatus?,
                            isFanOutParent: Bool) -> some View {
        let key        = SessionKey(serviceID: service.id, instance: instance)
        let isSelected = selectedServiceID == service.id && selectedInstance == instance
        let isHovered  = hoveredServiceKey == key
        let session    = sessions.session(for: key)

        HStack(spacing: 0) {
            // Column 1 (chevron): worktree fan-out toggle for a parent, else empty.
            // Empty keeps the service name aligned under the project name.
            Group {
                if isFanOutParent {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if expanded.contains(service.id) { expanded.remove(service.id) }
                            else { expanded.insert(service.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.helmMeta)
                            .rotationEffect(expanded.contains(service.id) ? .degrees(90) : .degrees(0))
                            .animation(.easeInOut(duration: 0.15), value: expanded.contains(service.id))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Color.clear
                }
            }
            .frame(width: HelmLayout.rowChevronColumn, alignment: .center)
            .padding(.trailing, HelmLayout.rowChevronGap)

            // Column 2 (icon position): the status light, on the LEFT of the service,
            // sitting under the project's icon column.
            Group {
                if let session {
                    StatusDot(session: session)
                } else {
                    Color.clear
                }
            }
            .frame(width: HelmLayout.rowIconColumn, alignment: .center)
            .padding(.trailing, HelmLayout.rowIconGap)

            Text(label)
                .font(HelmFont.small)
                .foregroundStyle(isSelected ? Color.helmTextSelected : Color.helmTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let rollUp { RollUpBadge(status: rollUp).padding(.leading, 4) }

            Spacer(minLength: 6)

            // Trailing: hover controls, else persistent pin + agent badge.
            HStack(spacing: 5) {
                if isHovered {
                    if let refresh {
                        trailingBtn("arrow.clockwise.circle", "Rescan", refresh)
                    }
                    ServiceControls(session: session, showControls: true,
                                    spawnable: spawnable,
                                    onStart:   { onStartService(service, project, instance) },
                                    onStop:    { onStopService(service, instance) },
                                    onRestart: { onRestartService(service, project, instance) })
                } else {
                    if service.persistent {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.helmMeta)
                    }
                    if service.isAgent, let session {
                        AgentBadge(session: session)
                    }
                }
            }
        }
        .padding(.vertical, HelmSpacing.rowV)
        .padding(.horizontal, HelmSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HelmRadius.md, style: .continuous)
                .fill(isSelected ? Color.helmBgSelected : (isHovered ? Color.helmBgHover : Color.clear))
        )
        .padding(.horizontal, HelmSpacing.xs)
        .contentShape(Rectangle())
        .onHover { hoveredServiceKey = $0 ? key : nil }
        .onTapGesture {
            selectedProjectID = project.id
            selectedServiceID = service.id
            selectedInstance  = instance
            session?.clearAttention()
        }
        .contextMenu {
            Button("Add Service…") { onAddService(project.id) }
            Divider()
            Button("Delete Service", role: .destructive) {
                serviceToDelete = ServiceDeletion(serviceID: service.id,
                                                  projectID: project.id,
                                                  name: service.name)
            }
        }
    }

    // MARK: - Orphans

    private var orphansSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DETACHED")
                .font(HelmFont.app.weight(.medium))
                .tracking(0.4)
                .foregroundStyle(Color.helmMeta)
                .padding(.horizontal, 16)
                .padding(.top, HelmSpacing.lg)
                .padding(.bottom, HelmSpacing.xs)

            ForEach(coordinator.orphans) { orphan in
                HStack(spacing: 0) {
                    Color.clear.frame(width: 36)
                    Text(orphan.label)
                        .font(HelmFont.small)
                        .foregroundStyle(Color.helmTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button("Kill") { coordinator.killOrphan(slug: orphan.slug) }
                        .buttonStyle(.borderless)
                        .font(HelmFont.small)
                        .foregroundStyle(Color.helmMeta)
                }
                .padding(.vertical, HelmSpacing.rowV)
                .padding(.horizontal, HelmSpacing.lg)
            }
        }
    }

    // MARK: - Footer bar

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                // Settings
                footerIconBtn("gearshape", "Settings") {
                    // Settings — wired in a later pass
                }

                // Add project
                footerIconBtn("plus", "New project", onAddProject)

                Spacer()

                // Launch preset menu
                Menu {
                    if presets.sorted.isEmpty {
                        Text("No presets")
                    } else {
                        ForEach(presets.sorted) { preset in
                            Button(preset.name) { onLaunchPreset(preset) }
                                .disabled(selectedProjectID == nil)
                        }
                    }
                    Divider()
                    Button("Manage Presets…") { showManagePresets = true }
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.helmIcon)
                        .frame(width: 36, height: 36)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 36, height: 36)
                .help("Launch preset")
            }
            .padding(.horizontal, HelmSpacing.xs)
        }
        // No opaque fill — the sidebar vibrancy shows through; the top divider
        // is the only separation, matching native bottom sidebar bars.
    }

    private func footerIconBtn(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.helmIcon)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tip)
    }

    private func trailingBtn(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.helmMeta)
        .help(tip)
    }

    // MARK: - Helpers

    private func childRollUp(_ service: Service, _ children: [Worktree]) -> RollUpStatus? {
        var sawCrash = false; var sawExit = false; var sawAttn = false
        for wt in children {
            let key = SessionKey(serviceID: service.id, instance: wt.sessionInstance())
            guard let s = sessions.session(for: key) else { continue }
            switch s.status {
            case .crashed:                              sawCrash = true
            case let .exited(_, byUser) where !byUser: sawExit  = true
            default: break
            }
            if s.agentState == .attention { sawAttn = true }
        }
        if sawCrash { return .crashed }
        if sawAttn  { return .attention }
        if sawExit  { return .exited }
        return nil
    }

    private var serviceDeleteBinding: Binding<Bool> {
        Binding(get: { serviceToDelete != nil }, set: { if !$0 { serviceToDelete = nil } })
    }
    private var projectDeleteBinding: Binding<Bool> {
        Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })
    }
}

// MARK: - SidebarShape

/// Sidebar background shape.
///
/// Left edge: square — flush with the window frame.
/// Right edge: flush at `maxX`, with **convex** (outward) rounded corners at the
/// top-right and bottom-right — a standard rounded panel. The corners cut the
/// path in by `r` from the right edge; the straight right edge stays at `maxX`.
private struct SidebarShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.height / 2, rect.width / 2)
        var p = Path()

        // Top-left (square — flush with the window corner).
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top edge across to the start of the top-right corner.
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))

        // Convex top-right corner: sweeps from the top of the arc (12 o'clock)
        // round to the right (3 o'clock), bulging up-and-right.
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(270),
            endAngle:   .degrees(0),
            clockwise:  false         // false → visually clockwise (y-down)
        )

        // Right edge straight down to the bottom-right corner.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))

        // Convex bottom-right corner: from the right (3 o'clock) round to the
        // bottom (6 o'clock).
        p.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle:   .degrees(90),
            clockwise:  false
        )

        // Bottom edge back to the left.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

        // Left edge back to start (square).
        p.closeSubpath()
        return p
    }
}

// MARK: - Private model types

private struct ServiceDeletion: Identifiable {
    let serviceID: UUID; let projectID: UUID; let name: String
    var id: UUID { serviceID }
}
private struct ProjectDeletion: Identifiable {
    let projectID: UUID; let name: String
    var id: UUID { projectID }
}

// MARK: - RollUpStatus

enum RollUpStatus { case crashed, exited, attention }

// MARK: - ServiceControls

private struct ServiceControls: View {
    let session: TerminalSession?
    let showControls: Bool
    let spawnable: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    var body: some View {
        if let session {
            ObservingControls(session: session, showControls: showControls,
                              spawnable: spawnable,
                              onStart: onStart, onStop: onStop, onRestart: onRestart)
        } else if showControls && spawnable {
            iconBtn("play.fill", "Start", onStart)
        }
    }

    private func iconBtn(_ sym: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym).font(.system(size: 9)).frame(width: 14, height: 14)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).help(tip)
    }
}

private struct ObservingControls: View {
    @ObservedObject var session: TerminalSession
    let showControls: Bool
    let spawnable: Bool
    let onStart, onStop, onRestart: () -> Void

    private var isLive: Bool {
        switch session.status { case .starting, .running: return true; default: return false }
    }

    var body: some View {
        // The status light now lives on the LEFT of the row (always visible), so
        // these hover controls are buttons only — no trailing dot.
        HStack(spacing: 4) {
            if showControls {
                if isLive        { iconBtn("stop.fill",       "Stop",    onStop) }
                else if spawnable { iconBtn("play.fill",       "Start",   onStart) }
                if spawnable     { iconBtn("arrow.clockwise", "Restart", onRestart) }
            }
        }
    }

    private func iconBtn(_ sym: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym).font(.system(size: 9)).frame(width: 14, height: 14)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).help(tip)
    }
}

// MARK: - AgentBadge

private struct AgentBadge: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        switch session.agentState {
        case .attention:
            Image(systemName: "bell.badge.fill").font(.system(size: 9)).foregroundStyle(Color.helmStatusAttention)
                .symbolEffect(.pulse, options: .repeating)
        case .working:
            Image(systemName: "ellipsis").font(.system(size: 9)).foregroundStyle(.secondary)
        case .waiting:
            Image(systemName: "questionmark.circle").font(.system(size: 9)).foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(.tertiary)
        case .idle, .unknown:
            Color.clear
        }
    }
}

// MARK: - RollUpBadge

private struct RollUpBadge: View {
    let status: RollUpStatus
    var body: some View {
        switch status {
        case .attention:
            Image(systemName: "bell.badge.fill").font(.system(size: 9)).foregroundStyle(Color.helmStatusAttention)
                .symbolEffect(.pulse, options: .repeating)
        case .crashed: Circle().fill(Color.helmStatusCrashed).frame(width: 5, height: 5)
        case .exited:  Circle().fill(Color.helmStatusExited).frame(width: 5, height: 5)
        }
    }
}

// MARK: - ProjectIcon

/// A project's avatar: a custom icon image when one is provided, otherwise the
/// project's initials on a blue rounded square. (Projects have no icon field
/// yet, so `image` is nil today and initials render — wire `image` through when
/// `Project` gains a custom-icon source.)
private struct ProjectIcon: View {
    let name: String
    var image: Image? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: HelmRadius.sm, style: .continuous)
            .fill(Color.helmAccent)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Text(initials)
                        .font(HelmFont.app.weight(.semibold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HelmRadius.sm, style: .continuous))
    }

    private var initials: String {
        let parts = name.split(whereSeparator: { " -_/".contains($0) })
        let letters = parts.count >= 2
            ? String(parts[0].prefix(1)) + String(parts[1].prefix(1))
            : String(name.prefix(2))
        return letters.uppercased()
    }
}

// MARK: - StatusDot

private struct StatusDot: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        Circle().fill(dotColor).frame(width: 5, height: 5).help(helpText)
    }
    private var dotColor: Color {
        switch session.status {
        case .starting: return .helmStatusStarting
        case .running:  return .helmStatusRunning
        case .exited:   return .helmStatusExited
        case .crashed:  return .helmStatusCrashed
        case .detached: return .helmStatusDetached
        }
    }
    private var helpText: String {
        switch session.status {
        case .starting:               return "Starting…"
        case .running:                return "Running"
        case let .exited(_, byUser):  return byUser ? "Stopped" : "Exited"
        case .crashed:                return "Crashed"
        case .detached:               return "Detached"
        }
    }
}
