import SwiftUI

@main
struct HelmApp: App {
    // Init order matters (plan §11): store → sessions → supervisor. The
    // supervisor depends on both (reads policy from the store, restarts via the
    // session manager, subscribes to its exit stream).
    @StateObject private var store: ProjectStore
    @StateObject private var worktrees: WorktreeStore
    @StateObject private var sessions: SessionManager
    @StateObject private var supervisor: ProcessSupervisor
    // Phase 5: the global launch-preset library (own persistence, m4).
    @StateObject private var presets: PresetStore

    init() {
        let store = ProjectStore()
        // worktreeStore depends on nothing (zero-poll, on-demand git scans).
        let worktrees = WorktreeStore()
        let sessions = SessionManager()
        let supervisor = ProcessSupervisor(sessions: sessions, store: store)
        let presets = PresetStore()
        _store = StateObject(wrappedValue: store)
        _worktrees = StateObject(wrappedValue: worktrees)
        _sessions = StateObject(wrappedValue: sessions)
        _supervisor = StateObject(wrappedValue: supervisor)
        _presets = StateObject(wrappedValue: presets)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(store)
                .environmentObject(worktrees)
                .environmentObject(supervisor)
                .environmentObject(presets)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
