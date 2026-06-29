import SwiftUI

/// Aggregate state for the menu-bar label, derived from the live session set
/// (zero-poll: a `SessionManager` `@ObservedObject` repaint, no timer).
struct MenuBarSummary {
    let runningCount: Int
    let detachedCount: Int
    let needsAttention: Bool

    init(sessions: [SessionKey: TerminalSession]) {
        var running = 0
        var detached = 0
        var attention = false
        for session in sessions.values {
            switch session.status {
            case .running, .starting: running += 1
            case .detached: detached += 1
            default: break
            }
            if session.agentState == .attention { attention = true }
        }
        self.runningCount = running
        self.detachedCount = detached
        self.needsAttention = attention
    }

    var symbol: String {
        if needsAttention { return "bell.badge.fill" }
        if runningCount > 0 || detachedCount > 0 { return "terminal.fill" }
        return "terminal"
    }
}

/// The menu-bar label (`MenuBarExtra` label). Observes the manager so the glyph +
/// count track state with zero polling.
struct HelmMenuBarLabel: View {
    @ObservedObject var sessions: SessionManager

    var body: some View {
        let summary = MenuBarSummary(sessions: sessions.sessions)
        HStack(spacing: 2) {
            Image(systemName: summary.symbol)
            if summary.runningCount > 0 {
                Text("\(summary.runningCount)")
            }
        }
    }
}

/// The menu-bar dropdown content (`.menuBarExtraStyle(.window)`). Minimal/
/// functional (visual polish deferred): aggregate counts + a reopen-window action.
struct HelmMenuBarContent: View {
    @ObservedObject var sessions: SessionManager
    @ObservedObject var coordinator: PersistenceCoordinator
    let onReopen: () -> Void

    var body: some View {
        let summary = MenuBarSummary(sessions: sessions.sessions)
        VStack(alignment: .leading, spacing: 8) {
            Text("Helm")
                .font(HelmFont.app.weight(.semibold))
            Divider()
            Label("\(summary.runningCount) running", systemImage: "play.circle")
                .font(HelmFont.app)
            Label("\(summary.detachedCount) detached", systemImage: "pause.circle")
                .font(HelmFont.app)
            if summary.needsAttention {
                Label("A session needs attention", systemImage: "bell.badge.fill")
                    .font(HelmFont.app)
                    .foregroundStyle(.orange)
            }
            if !coordinator.orphans.isEmpty {
                Divider()
                Text("Orphan sessions")
                    .font(HelmFont.app).foregroundStyle(.secondary)
                ForEach(coordinator.orphans) { orphan in
                    HStack {
                        Text(orphan.label).font(HelmFont.app).lineLimit(1)
                        Spacer()
                        Button("Kill") { coordinator.killOrphan(slug: orphan.slug) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Divider()
            Button("Open Helm Window") { onReopen() }
            Button("Quit Helm") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }
}
