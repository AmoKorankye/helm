import SwiftUI
import Combine

/// Collapsible bottom log panel (M5/M6). PERSISTENT-ONLY: a persistent session
/// streams its `pipe-pane` capture (ANSI-stripped, ring-buffered) via a
/// `SessionLog`. A non-persistent session shows "Enable Persistent for a live log"
/// (there is no `readViewportText` on the macOS `.exec` path — M5). The session is
/// passed in (value-typed status), so this view stays GhosttyTerminal-free.
struct LogPanelView: View {
    let session: TerminalSession?

    @State private var isExpanded = false
    /// One live `SessionLog` per selected persistent slug; recreated when the
    /// selected persistent session changes. Tails only while the panel is shown.
    @StateObject private var logHolder = LogHolder()

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider()
                content
                    .frame(height: 180)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .onChange(of: session?.slug) { _, _ in syncLog() }
        .onChange(of: isExpanded) { _, _ in syncLog() }
        .onAppear { syncLog() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Log")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        if let session, session.persistent {
            if let log = logHolder.log {
                LogScroll(log: log)
            } else {
                placeholder("Starting log…")
            }
        } else {
            placeholder("Enable Persistent for a live log.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func syncLog() {
        guard isExpanded, let session, session.persistent,
              let url = TmuxService.sessionLogPath(slug: session.slug) else {
            logHolder.clear()
            return
        }
        logHolder.attach(slug: session.slug, url: url)
    }
}

/// Owns the active `SessionLog` so SwiftUI body re-evaluation doesn't churn tails.
@MainActor
final class LogHolder: ObservableObject {
    @Published private(set) var log: SessionLog?
    private var currentSlug: String?

    func attach(slug: String, url: URL) {
        guard currentSlug != slug else { return }
        clear()
        let newLog = SessionLog(slug: slug)
        newLog.start(fileURL: url)
        log = newLog
        currentSlug = slug
    }

    func clear() {
        log?.stop()
        log = nil
        currentSlug = nil
    }
}

/// Scrolling, monospaced view of the ring-buffered (stripped) log lines.
private struct LogScroll: View {
    @ObservedObject var log: SessionLog

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { idx, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(idx)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .onChange(of: log.lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}
