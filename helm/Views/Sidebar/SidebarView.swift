import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var worktrees: WorktreeStore
    @EnvironmentObject var presets: PresetStore
    @Binding var selectedProjectID: UUID?
    @Binding var selectedServiceID: UUID?
    @Binding var selectedInstance: SessionInstance

    // Injected coordination closures. The sidebar stays dumb: it never touches
    // SessionManager and never deletes from the store directly — deletes and
    // adds route up to ContentView, which owns session teardown.
    let onAddProject: () -> Void
    let onAddService: (UUID) -> Void
    let onDeleteService: (UUID, UUID) -> Void
    let onDeleteProject: (UUID) -> Void
    // Per-service lifecycle actions (revealed on row hover). Still dumb: the row
    // only reports intent; ContentView owns SessionManager/supervisor coordination.
    // Phase 4: each carries the WHICH-instance so worktree children act on their
    // own session, not the service's `.primary`.
    let onStartService: (Service, Project, SessionInstance) -> Void
    let onStopService: (Service, SessionInstance) -> Void
    let onRestartService: (Service, Project, SessionInstance) -> Void
    // Phase 5 (B1): launching a preset ADDS a real service to the selected project
    // and starts it. The sidebar stays dumb — ContentView owns the add+start flow.
    let onLaunchPreset: (LaunchPreset) -> Void

    // Pending confirmation targets for destructive actions.
    @State private var serviceToDelete: ServiceDeletion?
    @State private var projectToDelete: ProjectDeletion?
    @State private var showManagePresets = false
    // Phase 4: expansion state for worktree-enabled services. A DisclosureGroup's
    // expansion has no defined home in a List that republishes on every store
    // mutation (grill M6) — we own it explicitly here.
    @State private var expanded: Set<UUID> = []

    private var sortedProjects: [Project] {
        store.projects.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        List {
            ForEach(sortedProjects) { project in
                Section {
                    let services = project.services.sorted { $0.sortOrder < $1.sortOrder }
                    ForEach(services) { service in
                        serviceEntry(service, in: project)
                    }
                    // `.onMove` is scoped to the SERVICE-level ForEach (grill M6):
                    // reordering operates on whole services (label rows); worktree
                    // children are not independently reorderable.
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
                Menu {
                    if presets.sorted.isEmpty {
                        Text("No presets")
                    } else {
                        ForEach(presets.sorted) { preset in
                            Button(preset.name) { onLaunchPreset(preset) }
                                .disabled(selectedProjectID == nil)
                                .help(selectedProjectID == nil ? "Select a project first" : preset.command)
                        }
                    }
                    Divider()
                    Button("Manage Presets…") { showManagePresets = true }
                } label: {
                    Label("Launch", systemImage: "bolt.fill")
                }
                .help(selectedProjectID == nil
                      ? "Select a project, then launch a preset into it"
                      : "Launch an agent preset into the selected project")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAddProject) {
                    Image(systemName: "plus")
                }
                .help("Add project")
            }
        }
        .sheet(isPresented: $showManagePresets) {
            ManagePresetsSheet()
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

    // MARK: - Service entry (normal row OR worktree DisclosureGroup)

    /// One service in the sidebar. A worktree-enabled service WITH spawnable
    /// children renders a `DisclosureGroup` (label = main/`.primary`; children =
    /// the additional worktrees). Otherwise — the common path, including a
    /// worktree-enabled service with only a main worktree — it's a plain row.
    @ViewBuilder
    private func serviceEntry(_ service: Service, in project: Project) -> some View {
        let scan = worktrees.scan(for: project.id)
        let showFanOut = service.worktreeEnabled && (scan?.hasFanOut ?? false)

        if showFanOut, let children = scan?.fanOutChildren {
            DisclosureGroup(isExpanded: expansionBinding(service.id)) {
                ForEach(children) { wt in
                    serviceRow(service, project,
                               instance: wt.sessionInstance(),
                               label: wt.displayName,
                               spawnable: wt.isSpawnableChild,
                               refresh: nil)
                }
            } label: {
                // Label = the main/`.primary` row, with a re-scan affordance and a
                // roll-up badge for collapsed-child crashes (grill M7).
                serviceRow(service, project,
                           instance: .primary,
                           label: service.name,
                           spawnable: true,
                           refresh: { Task { await worktrees.refresh(project) } },
                           rollUp: expanded.contains(service.id) ? nil : childRollUp(service, children))
            }
        } else {
            serviceRow(service, project,
                       instance: .primary,
                       label: service.name,
                       spawnable: true,
                       refresh: nil)
        }
    }

    /// A single tappable row for a (service, instance). Looks up its OWN session by
    /// the full key, reports intent via instance-carrying closures, and computes
    /// selection per `(serviceID, instance)`.
    @ViewBuilder
    private func serviceRow(_ service: Service,
                            _ project: Project,
                            instance: SessionInstance,
                            label: String,
                            spawnable: Bool,
                            refresh: (() -> Void)?,
                            rollUp: RollUpStatus? = nil) -> some View {
        let key = SessionKey(serviceID: service.id, instance: instance)
        ServiceRow(
            service: service,
            label: label,
            isSelected: selectedServiceID == service.id && selectedInstance == instance,
            spawnable: spawnable,
            session: sessions.session(for: key),
            rollUp: rollUp,
            onRefresh: refresh,
            onStart: { onStartService(service, project, instance) },
            onStop: { onStopService(service, instance) },
            onRestart: { onRestartService(service, project, instance) }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProjectID = project.id
            selectedServiceID = service.id
            selectedInstance = instance
            // M2: re-selecting an attention session clears its pulse even if it
            // never regains focus (a backgrounded, never-reselected session would
            // otherwise pulse forever). No-op for non-agent sessions.
            sessions.session(for: key)?.clearAttention()
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

    private func expansionBinding(_ serviceID: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(serviceID) },
            set: { isOn in
                if isOn { expanded.insert(serviceID) } else { expanded.remove(serviceID) }
            }
        )
    }

    /// Roll-up over a collapsed service's worktree-child sessions (grill M7): if any
    /// child session is crashed or non-user-exited, surface it on the label so a
    /// crash isn't hidden behind a collapsed chevron. Reads the live session dict.
    private func childRollUp(_ service: Service, _ children: [Worktree]) -> RollUpStatus? {
        var sawCrash = false
        var sawExit = false
        var sawAttention = false
        for wt in children {
            let key = SessionKey(serviceID: service.id, instance: wt.sessionInstance())
            guard let session = sessions.session(for: key) else { continue }
            switch session.status {
            case .crashed:
                sawCrash = true
            case let .exited(_, byUser) where byUser == false:
                sawExit = true
            default:
                break
            }
            // m7: surface a collapsed child's agent attention on the label too.
            if session.agentState == .attention { sawAttention = true }
        }
        // Attention is the draw-the-eye case — surface it ahead of a quiet exit but
        // behind a crash (a crash is the most urgent liveness signal).
        if sawCrash { return .crashed }
        if sawAttention { return .attention }
        if sawExit { return .exited }
        return nil
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

/// Roll-up status shown on a collapsed worktree-service label so a hidden child's
/// crash/exit isn't invisible behind the chevron (grill M7).
enum RollUpStatus {
    case crashed
    case exited
    /// A collapsed worktree child's agent is in `.attention` (m7). Rendered as the
    /// pulsing bell SF Symbol, not the small Circle the other cases use.
    case attention
}

struct ServiceRow: View {
    let service: Service
    /// The display label — the service name for a `.primary`/main row, or the
    /// worktree's branch/short label for a child row.
    let label: String
    let isSelected: Bool
    /// Whether this row's instance can be (re)started. False for a vanished/
    /// prunable worktree → start/restart controls are suppressed (grill m12/B3).
    let spawnable: Bool
    /// The live session for this row's instance, if one exists. Passed in (not
    /// looked up here) so the row stays dumb. When present, its status drives the dot.
    let session: TerminalSession?
    /// Collapsed-child roll-up badge for a worktree-service label (M7); nil otherwise.
    let rollUp: RollUpStatus?
    /// Manual re-scan affordance, shown only on a worktree-service label.
    let onRefresh: (() -> Void)?
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
            // m7: FIXED LEADING slot for the agent badge, left of the label. An
            // agent row renders the glyph; a non-agent row renders an empty
            // fixed-width spacer so labels stay column-aligned and `.onMove` /
            // hover hit-areas are unaffected (the slot is fixed-width, not in the
            // trailing cluster). The badge observes its session for zero-poll repaint.
            if service.isAgent, let session {
                AgentBadge(session: session)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Text(label)
                .font(.system(size: 13))
            if let rollUp {
                RollUpBadge(status: rollUp)
            }
            Spacer()
            if isHovering, let onRefresh {
                ControlButton(symbol: "arrow.clockwise.circle", help: "Rescan worktrees", action: onRefresh)
            }
            // Hover controls (start/stop/restart) appear on hover; the status dot
            // is always visible. `ServiceControls` observes the session so the
            // button set tracks status with zero polling.
            ServiceControls(
                session: session,
                showControls: isHovering,
                spawnable: spawnable,
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
    /// When false (a vanished/prunable worktree) start & restart are suppressed so
    /// we never spawn into a non-existent cwd or relaunch in the wrong tree (m12/B3).
    let spawnable: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    var body: some View {
        if let session {
            // Observe the live session so buttons follow its status.
            ObservingControls(
                session: session,
                showControls: showControls,
                spawnable: spawnable,
                onStart: onStart,
                onStop: onStop,
                onRestart: onRestart
            )
        } else {
            // No session yet: only a Play button (on hover, and only if spawnable);
            // no dot. A prunable/vanished worktree gets neither.
            HStack(spacing: 6) {
                if showControls && spawnable {
                    ControlButton(symbol: "play.fill", help: "Start", action: onStart)
                }
            }
        }
    }
}

private struct ObservingControls: View {
    @ObservedObject var session: TerminalSession
    let showControls: Bool
    let spawnable: Bool
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
                    // A live session can always be stopped, even if its worktree
                    // vanished — stop just frees the surface.
                    ControlButton(symbol: "stop.fill", help: "Stop", action: onStop)
                } else if spawnable {
                    ControlButton(symbol: "play.fill", help: "Start", action: onStart)
                }
                // Restart is offered only when the instance is spawnable (a vanished
                // worktree's restart is disabled — m12, no wrong-tree relaunch).
                if spawnable {
                    ControlButton(symbol: "arrow.clockwise", help: "Restart", action: onRestart)
                }
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

/// Zero-poll agent-state badge in the FIXED LEADING slot (m7), left of the label.
/// Observes one `TerminalSession` (`@ObservedObject`) and repaints ONLY when its
/// `@Published agentState` changes (republished from the detector — event-driven,
/// no timer). `.attention` is the headline draw-the-eye state: a pulsing
/// `bell.badge.fill` via `.symbolEffect`. Quiet/absent for idle/unknown.
/// GhosttyTerminal-free: reads only `TerminalSession.agentState` (a plain enum).
private struct AgentBadge: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        switch session.agentState {
        case .attention:
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
                .help("Agent needs attention")
        case .working:
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Agent working")
        case .waiting:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Agent waiting")
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("Agent finished")
        case .idle, .unknown:
            // Empty: keep the fixed slot reserved (the caller's .frame holds width).
            Color.clear
        }
    }
}

/// Collapsed-child roll-up badge (m7). `.crashed`/`.exited` keep the existing small
/// circle; `.attention` renders the pulsing bell SF Symbol (the grill flagged the
/// Circle path can't pulse).
private struct RollUpBadge: View {
    let status: RollUpStatus

    var body: some View {
        switch status {
        case .attention:
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
                .help("A worktree session needs attention")
        case .crashed:
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .help("A worktree session crashed")
        case .exited:
            Circle()
                .fill(Color.gray)
                .frame(width: 6, height: 6)
                .help("A worktree session exited")
        }
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
