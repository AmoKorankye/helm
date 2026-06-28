import Foundation
import GhosttyTerminal

/// Helm-owned forwarding delegate set as the hosted terminal view's `delegate` in
/// place of the raw `TerminalViewState` (plan §6 / M1). It conforms to ALL the
/// surface delegate protocols the stock state conforms to, PLUS
/// `TerminalSurfaceProgressReportDelegate` (which the stock state does NOT — so
/// OSC 9;4 progress is silently dropped today, §1.2). Every stock method forwards
/// to the wrapped `TerminalViewState` (keeping its @Published state fully
/// populated, so Phase 1–4 behavior is byte-identical) AND progress is piped to
/// the session's `AgentStateDetector` for a RELIABLE `.working` signal.
///
/// This file is INSIDE the session seal (Decision #6): it imports GhosttyTerminal
/// because it conforms to ghostty protocols. No GhosttyTerminal type leaks out.
///
/// RISK (documented): if a future libghostty adds a NON-required delegate protocol,
/// this forwarder must add it too or silently drop it — exactly the bug §1.2
/// documents. Pinned to libghostty-spm 1.3.1; re-audit
/// `TerminalSurfaceViewDelegate.swift` on any version bump.
@MainActor
final class SessionSurfaceDelegate:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceProgressReportDelegate
{
    private let state: TerminalViewState
    private weak var detector: AgentStateDetector?

    init(forwardingTo state: TerminalViewState, progress detector: AgentStateDetector?) {
        self.state = state
        self.detector = detector
    }

    // MARK: - Pure forwards (every method verified `public` on TerminalViewState)

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state.terminalDidChangeFocus(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        state.terminalDidClose(processAlive: processAlive)
    }

    func terminalDidRingBell() {
        state.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        state.terminalDidChangeWorkingDirectory(path)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }

    // MARK: - The NEW capability the stock state drops (§1.2)

    func terminalDidReportProgress(state s: TerminalProgressState, percent: Int?) {
        // The stock TerminalViewState does NOT conform to the progress delegate,
        // so there is nothing to forward to — we route it straight to the detector.
        detector?.progressDidReport(state: s, percent: percent)
    }
}
