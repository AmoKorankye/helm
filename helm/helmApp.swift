import SwiftUI

@main
struct HelmApp: App {
    @StateObject private var sessions = SessionManager()
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
