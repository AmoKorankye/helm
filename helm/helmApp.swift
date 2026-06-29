import SwiftUI
import AppKit

@main
struct HelmApp: App {
    // Init order matters (plan §11): store → tmux/index → sessions → supervisor.
    // The supervisor depends on both (reads policy from the store, restarts via the
    // session manager, subscribes to its exit stream).
    @StateObject private var store: ProjectStore
    @StateObject private var worktrees: WorktreeStore
    @StateObject private var sessions: SessionManager
    @StateObject private var supervisor: ProcessSupervisor
    // Phase 5: the global launch-preset library (own persistence, m4).
    @StateObject private var presets: PresetStore
    // Phase 6: tmux-backed persistence — index, coordinator, notifier.
    @StateObject private var index: TmuxSessionIndex
    @StateObject private var coordinator: PersistenceCoordinator
    @StateObject private var notifier: AttentionNotifier

    // Always-on survival (m2): keep the app alive when the window closes so
    // persistence + notifications keep working; reopen via the menu bar.
    @NSApplicationDelegateAdaptor(HelmAppDelegate.self) private var appDelegate

    init() {
        // Register the bundled Inter faces before any view renders.
        HelmFont.registerBundledFonts()

        let store = ProjectStore()
        let worktrees = WorktreeStore()
        // Phase 6: one TmuxService + one authoritative index, shared by the manager
        // and the coordinator (the manager owns the only tmux caller).
        let tmux = TmuxService()
        let index = TmuxSessionIndex()
        let sessions = SessionManager(tmux: tmux, index: index)
        let supervisor = ProcessSupervisor(sessions: sessions, store: store)
        let presets = PresetStore()
        let notifier = AttentionNotifier()
        let coordinator = PersistenceCoordinator(sessions: sessions, store: store, notifier: notifier)

        _store = StateObject(wrappedValue: store)
        _worktrees = StateObject(wrappedValue: worktrees)
        _sessions = StateObject(wrappedValue: sessions)
        _supervisor = StateObject(wrappedValue: supervisor)
        _presets = StateObject(wrappedValue: presets)
        _index = StateObject(wrappedValue: index)
        _coordinator = StateObject(wrappedValue: coordinator)
        _notifier = StateObject(wrappedValue: notifier)

        // Wire the non-persistent attention-ping forwarding + notification deep-link.
        sessions.notifier = notifier
        AttentionNotifier.slugResolver = { slug in
            index.record(forSlug: slug)?.sessionKey
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(store)
                .environmentObject(worktrees)
                .environmentObject(supervisor)
                .environmentObject(presets)
                .environmentObject(coordinator)
                .environmentObject(notifier)
                .onAppear {
                    notifier.requestAuthorization()
                    coordinator.reattachOnLaunch()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        // Phase 6 menu-bar (m2): aggregate state + reopen affordance. Always-on.
        MenuBarExtra {
            HelmMenuBarContent(sessions: sessions, coordinator: coordinator) {
                NSApp.activate(ignoringOtherApps: true)
                // Reopen a closed main window.
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        } label: {
            HelmMenuBarLabel(sessions: sessions)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the process alive when the last window closes (m2): always-on persistence
/// + notifications require the app NOT to terminate on last-window-close.
final class HelmAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
