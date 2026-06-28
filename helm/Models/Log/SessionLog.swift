import Foundation
import Combine

/// A persistent session's live log: a ring buffer fed by a `LogTail` over the
/// `pipe-pane` capture file, ANSI-stripped before storage (M6). Only the SELECTED
/// session's log is actively tailed; the panel attaches/detaches. Caps at
/// ~5000 lines in memory; the on-disk file is size-capped by `SessionLogStore`.
///
/// GhosttyTerminal-free. `@MainActor` so views observe it directly.
@MainActor
final class SessionLog: ObservableObject {
    let slug: String
    @Published private(set) var lines: [String] = []

    private static let maxLines = 5000
    private var tail: LogTail?
    private var pending = ""

    init(slug: String) {
        self.slug = slug
    }

    /// Start tailing the on-disk capture file from the start (show existing log).
    func start(fileURL: URL) {
        guard tail == nil else { return }
        tail = LogTail(url: fileURL, fromEnd: false) { [weak self] chunk in
            // LogTail fires on a background queue → hop to the main actor.
            Task { @MainActor in self?.ingest(chunk) }
        }
    }

    func stop() {
        tail?.stop()
        tail = nil
    }

    private func ingest(_ chunk: String) {
        pending += AnsiStripper.strip(chunk)
        // Split into complete lines; keep any trailing partial in `pending`.
        var newLines: [String] = []
        while let nl = pending.firstIndex(of: "\n") {
            newLines.append(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}
