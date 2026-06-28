import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var worktrees: WorktreeStore
    @EnvironmentObject private var supervisor: ProcessSupervisor

    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedProjectID: UUID?
    @State private var selectedServiceID: UUID?
    @State private var selectedInstance: SessionInstance = .primary

    @State private var showAddProject = false
    @State private var addServiceTargetProjectID: UUID?
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 220

    private static let sidebarMinWidth: CGFloat = 160
    private static let sidebarMaxWidth: CGFloat = 400

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
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
                    },
                    onLaunchPreset: { launchPreset($0) }
                )
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fill up to the window top — the toolbar reserves a title-bar
                // safe area that would otherwise leave dead space above the
                // terminal (the sidebar already ignores it via its background).
                .ignoresSafeArea(edges: .top)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(colorScheme == .dark ? Color(white: 0.07) : Color.white)
        // The resize handle lives in an overlay straddling the sidebar/detail
        // seam, so it adds NO layout width — the two panes sit flush together.
        .overlay(alignment: .leading) {
            if sidebarVisible {
                SidebarDivider(sidebarWidth: $sidebarWidth,
                               min: Self.sidebarMinWidth,
                               max: Self.sidebarMaxWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: sidebarWidth - 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 13))
                }
                .help("Toggle sidebar")
            }
        }
        .sheet(isPresented: $showAddProject) {
            AddProjectSheet { store.addProject($0) }
        }
        .sheet(item: addServiceSheetItem) { item in
            AddServiceSheet(projectID: item.projectID) { store.addService($0, to: item.projectID) }
        }
        .task(id: selectedProjectID) {
            guard let project = store.project(id: selectedProjectID) else { return }
            await worktrees.refresh(project)
        }
    }

    /// The pure, NON-mutating resolution of the current detail selection. Reads
    /// only (`store.service(id:)`, `resolveSelectedInstance`, `SessionKey`,
    /// `worktrees.workingDirectory`); it NEVER creates a session. The actual
    /// create-or-return is a side effect (`ensureSession`) keyed off `key`, so the
    /// view body can publish nothing during SwiftUI's render pass.
    private var detailSelection: DetailSelection? {
        guard let sel = store.service(id: selectedServiceID) else { return nil }
        // §8.5 / m8: validate the selected instance so a vanished/prunable worktree
        // never resolves to a junk session in project root.
        let instance = resolveSelectedInstance(service: sel.service, project: sel.project)
        let key = SessionKey(serviceID: sel.service.id, instance: instance)
        let cwd = worktrees.workingDirectory(for: instance, in: sel.project)
                  ?? sel.project.directory
        return DetailSelection(
            service: sel.service,
            project: sel.project,
            instance: instance,
            key: key,
            cwd: cwd
        )
    }

    private var detail: some View {
        // A single view (the Group), so the detail area fills the full leftover
        // width. The create-or-return runs from `.task` on this same view — still a
        // SIDE EFFECT outside the body update (so publishing the new session is
        // allowed), NOT a second sibling view that would claim its own column.
        Group {
            if let d = detailSelection {
                // Non-mutating lookup ONLY (no create in body — that's
                // `ensureSession`, the `.task` side effect). The session and its
                // PTY/process outlive this view, so switching services never tears
                // it down. No `.id()`.
                if let session = sessions.session(for: d.key) {
                    SessionHostView(manager: sessions, selectedKey: d.key)
                        .overlay {
                            RestartOverlay(session: session) {
                                manualRestart(
                                    key: d.key,
                                    command: d.service.command,
                                    workingDirectory: d.cwd
                                )
                            }
                        }
                } else {
                    // Brief (~1 frame) placeholder the first time a given session is
                    // created: `ensureSession` creates it as a side effect, then the
                    // republish re-renders here. An already-created session renders
                    // immediately (no flicker on switch).
                    Color(colorScheme == .dark ? NSColor(white: 0.07, alpha: 1) : .white)
                }
            } else {
                WelcomeView()
            }
        }
        // Create-or-return + reattach as a SIDE EFFECT. Re-runs whenever the
        // selection key changes — lazy attach builds the surface on first selection.
        .task(id: detailSelection?.key) { ensureSession() }
    }

    /// Create-or-return the long-lived session for the current selection, then
    /// reattach it if it's a detached persistent session. Runs from a `.task`
    /// side effect — NEVER the view body — so the `@Published var sessions` mutation
    /// the create performs happens outside SwiftUI's render pass.
    private func ensureSession() {
        guard let d = detailSelection else { return }
        _ = sessions.session(
            forServiceID: d.service.id,
            instance: d.instance,
            command: d.service.command,
            workingDirectory: d.cwd,
            isAgent: d.service.isAgent,
            persistent: d.service.persistent,
            displayName: SessionManager.displayName(service: d.service, project: d.project, instance: d.instance)
        )
        reattachIfDetached(d.key)
    }

    /// Reattach a `.detached` persistent session when it becomes the selection.
    private func reattachIfDetached(_ key: SessionKey) {
        guard let session = sessions.session(for: key), session.persistent else { return }
        if case .detached = session.status {
            sessions.reattach(key: key)
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
                workingDirectory: cwd,
                isAgent: service.isAgent
            )
        } else {
            _ = sessions.session(
                forServiceID: service.id,
                instance: instance,
                command: service.command,
                workingDirectory: cwd,
                isAgent: service.isAgent,
                persistent: service.persistent,
                displayName: SessionManager.displayName(service: service, project: project, instance: instance)
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

    // MARK: - Preset launch (B1 — add a real service from a template, then start it)

    /// Launch a preset into the selected project (plan §4.2 / B1): build a real
    /// `Service` from the template, ADD it to the store (so it appears in the
    /// sidebar, is inspectable/stoppable/restartable/persisted), then start +
    /// select it via the EXISTING `startService` path. No `.adHoc` — the new
    /// service flows through detail/sidebar/inspector/status/badge for free.
    /// `agentKindOverride: preset.agentKind` seeds the badge.
    private func launchPreset(_ preset: LaunchPreset) {
        guard let project = store.project(id: selectedProjectID) else { return }
        let service = Service(
            name: preset.name,
            command: preset.command,
            agentKindOverride: preset.agentKind
        )
        store.addService(service, to: project.id)
        // Re-read the project so `startService` sees the freshly added service in a
        // current snapshot (selection + cwd resolution).
        guard let updated = store.project(id: project.id) else { return }
        startService(service, in: updated, instance: .primary)
    }

    // MARK: - Coordination (the only place SessionManager + store meet)

    private func deleteService(id serviceID: UUID, in projectID: UUID) {
        let ids = store.deleteService(id: serviceID, from: projectID)
        let keys = sessions.keys(forServiceIDs: Set(ids))
        keys.forEach { supervisor.cancel($0); sessions.close($0) }
        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }
    }

    private func deleteProject(id projectID: UUID) {
        let ids = store.deleteProject(id: projectID)
        let keys = sessions.keys(forServiceIDs: Set(ids))
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

/// The pure, fully-resolved detail selection: WHICH service/project/instance is
/// shown, its `SessionKey`, and the resolved cwd. Computed by `detailSelection`
/// with reads only (no mutation), so it's safe to evaluate inside the view body
/// and to use as a `.task(id:)` trigger for the create-or-return side effect.
private struct DetailSelection {
    let service: Service
    let project: Project
    let instance: SessionInstance
    let key: SessionKey
    let cwd: String
}

/// Identifiable wrapper so the add-service sheet can bind to a target project.
private struct AddServiceTarget: Identifiable {
    let projectID: UUID
    var id: UUID { projectID }
}

// MARK: - SidebarDivider

private struct SidebarDivider: View {
    @Binding var sidebarWidth: CGFloat
    let min: CGFloat
    let max: CGFloat

    @State private var isHovering  = false
    @State private var isDragging  = false
    @State private var dragStartWidth: CGFloat?
    // Tracks how many times we've pushed so we can always balance the stack.
    @State private var cursorDepth = 0

    var body: some View {
        Color.white.opacity(0.001)  // invisible but hittable; no visible line
            .frame(width: 8)
            .contentShape(Rectangle())
            .ignoresSafeArea(.all, edges: .top)
        .onHover { hovering in
            isHovering = hovering
            // During a drag the cursor is already up; ignore hover changes
            // so we don't mis-count pushes.
            guard !isDragging else { return }
            if hovering { pushCursor() } else { popAllCursors() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartWidth = sidebarWidth
                        // If onHover didn't already push (e.g. fast click at the edge),
                        // push now so the resize cursor stays for the whole drag.
                        if cursorDepth == 0 { pushCursor() }
                    }
                    let proposed = (dragStartWidth ?? sidebarWidth) + value.translation.width
                    sidebarWidth = Swift.min(Swift.max(proposed, min), max)
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartWidth = nil
                    // Balance the stack completely, then re-push if still hovering.
                    popAllCursors()
                    if isHovering { pushCursor() }
                }
        )
        // The sidebar can be toggled off (or this view torn down) mid-hover/drag,
        // so onHover(false) never fires — always balance the cursor stack here.
        .onDisappear { popAllCursors() }
    }

    private func pushCursor() {
        NSCursor.resizeLeftRight.push()
        cursorDepth += 1
    }

    private func popAllCursors() {
        for _ in 0..<cursorDepth { NSCursor.pop() }
        cursorDepth = 0
    }
}

struct WelcomeView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a service")
                .font(HelmFont.ui)
                .foregroundStyle(.secondary)
            Text("Choose a project and service from the sidebar")
                .font(HelmFont.mono)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.07) : .white)
    }
}
