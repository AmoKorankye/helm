import SwiftUI

@main
struct HelmApp: App {
    @StateObject private var sessions = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessions)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
