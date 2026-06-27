import SwiftUI

@main
struct HelmApp: App {
    // Init order matters (plan §11): store → sessions → supervisor. The
    // supervisor depends on both (reads policy from the store, restarts via the
    // session manager, subscribes to its exit stream).
    @StateObject private var store: ProjectStore
    @StateObject private var sessions: SessionManager
    @StateObject private var supervisor: ProcessSupervisor

    init() {
        let store = ProjectStore()
        let sessions = SessionManager()
        let supervisor = ProcessSupervisor(sessions: sessions, store: store)
        _store = StateObject(wrappedValue: store)
        _sessions = StateObject(wrappedValue: sessions)
        _supervisor = StateObject(wrappedValue: supervisor)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(store)
                .environmentObject(supervisor)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
