import Foundation
import Combine
import GhosttyTerminal

/// Derives a single `AgentState` from a session's libghostty `@Published` signals
/// (title / bell / desktop-notification / focus) PLUS OSC 9;4 progress fed in by
/// the forwarding delegate (§6). ZERO-POLL: Combine sinks on the existing
/// `@Published` properties; no timer (bell debounce is a timestamp compare, not a
/// scheduler).
///
/// INSIDE the session seal (Decision #6): imports GhosttyTerminal to consume
/// `TerminalViewState`/`TerminalProgressState`. No ghostty type is re-exported —
/// the only output is the plain-value `@Published agentState`.
///
/// Interface contract (narrow, deep): input = a `TerminalViewState` + three pokes
/// (`sessionTerminated`, `progressDidReport`, `clearAttention`); output = one
/// `@Published agentState`. Owned by `TerminalSession`; subscriptions torn down
/// with the session.
@MainActor
final class AgentStateDetector: ObservableObject {
    @Published private(set) var agentState: AgentState = .unknown

    /// Fires on each FRESH bell/notification latch (m4) so a repeat ping isn't lost
    /// the way `$agentState` collapses identical values. `TerminalSession`
    /// republishes it; `AttentionNotifier` posts a banner while the app is away.
    let attentionPing = PassthroughSubject<Void, Never>()

    private let viewState: TerminalViewState
    private let heuristic: AgentTitleHeuristic   // .disabled by default
    private var cancellables: Set<AnyCancellable> = []

    // M3 — once terminated, recompute() always returns .done.
    private var isTerminated = false
    // M2 — attention latch.
    private var attentionLatched = false
    private var lastBellSeenAt: Date?
    private var lastNotificationSeenAt: Date?
    private var lastBellLatchAt: Date?            // m9 debounce window
    // §6 — progress-driven working (set via progressDidReport).
    private var progressActive = false

    init(viewState: TerminalViewState, heuristic: AgentTitleHeuristic = .disabled) {
        self.viewState = viewState
        self.heuristic = heuristic
        // Seed "seen" timestamps so any bell/notif that ALREADY happened before the
        // detector attached does not retroactively latch attention.
        self.lastBellSeenAt = viewState.lastBellAt
        self.lastNotificationSeenAt = viewState.lastDesktopNotificationAt
        subscribe()
        recompute()
    }

    /// Called by the owning session when liveness ends (exit/stop, M3). Latches
    /// terminated so a late title/bell can never resurrect a dead session.
    func sessionTerminated() {
        isTerminated = true
        recompute()
    }

    /// Called by the forwarding delegate (§6) when OSC 9;4 progress arrives. The
    /// delegate fires this while libghostty parses bytes, which can happen during a
    /// SwiftUI view update on attach. The `progressActive` latch is updated
    /// SYNCHRONOUSLY (so no progress event is lost or reordered), but the resulting
    /// `recompute()` — which mutates the observed `@Published agentState` — is hopped
    /// to the next runloop tick so it never runs inside a view update. Event-driven,
    /// not a poll; one-tick delay only.
    func progressDidReport(state: TerminalProgressState, percent: Int?) {
        switch state {
        case .set, .indeterminate:
            progressActive = true
        case .remove, .error, .pause:
            progressActive = false
        }
        DispatchQueue.main.async { [weak self] in self?.recompute() }
    }

    /// M2 — explicit clear-on-select hook (sidebar row tap, §5.10). Drops the
    /// attention latch even when the session never regains focus.
    func clearAttention() {
        attentionLatched = false
        recompute()
    }

    // MARK: - Subscriptions (zero-poll)

    private func subscribe() {
        // Merge the relevant @Published streams to a single Void trigger → recompute.
        // Event-driven only; NO debounce scheduler (bells are debounced by a
        // timestamp compare in updateAttentionLatch).
        let title = viewState.$title.map { _ in () }
        let bell = viewState.$bellCount.map { _ in () }
        let notif = viewState.$lastDesktopNotificationAt.map { _ in () }
        let focus = viewState.$isFocused.map { _ in () }

        // `.receive(on: DispatchQueue.main)`: these four libghostty signals can fire
        // SYNCHRONOUSLY while a SwiftUI view update is hosting the surface (title /
        // focus set during `updateNSView` on attach). Recomputing — and thus mutating
        // the observed `@Published agentState` — inside that update triggers SwiftUI's
        // "Publishing changes from within view updates" warning. Hopping to the next
        // runloop tick moves `recompute()` OUT of the view-update cycle. This is NOT a
        // poll: it stays purely event-driven (only fires when a signal fires), just
        // delivered one tick later. The attention latch is timestamp-compared
        // (`updateAttentionLatch`), so a one-tick delay does not lose or reorder a
        // bell/notif ping.
        Publishers.Merge4(title, bell, notif, focus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)
    }

    // MARK: - State machine (precedence, highest first — plan §2.2)

    private func recompute() {
        if isTerminated { agentState = .done; return }               // §2.4 / M3
        updateAttentionLatch()                                        // §2.3 / M2 / m9
        if attentionLatched { agentState = .attention; return }
        if progressActive { agentState = .working; return }          // §6 reliable working
        if heuristic.enabled {                                        // best-effort, off by default
            switch heuristic.classify(title: viewState.title) {
            case .working: agentState = .working; return
            case .waiting: agentState = .waiting; return
            default: break
            }
        }
        agentState = .idle
    }

    private func updateAttentionLatch() {
        // m9 gate: only latch while the session is NOT focused (you only see the
        // badge when you're away). A new notif is high-confidence; a new bell is
        // medium-confidence and debounced.
        guard !viewState.isFocused else { return }

        if let n = viewState.lastDesktopNotificationAt, n != lastNotificationSeenAt {
            lastNotificationSeenAt = n
            attentionLatched = true                                   // high-confidence
            attentionPing.send()                                      // m4: fresh ping
        }
        if let b = viewState.lastBellAt, b != lastBellSeenAt {        // medium-confidence
            lastBellSeenAt = b
            // m9 debounce: ignore bells within 1s of the last latch.
            if lastBellLatchAt == nil || b.timeIntervalSince(lastBellLatchAt!) > 1.0 {
                attentionLatched = true
                lastBellLatchAt = b
                attentionPing.send()                                  // m4: fresh ping
            }
        }
    }
}

/// The ONLY fragile part — a swappable title pattern table, DISABLED by default.
/// When enabled it classifies a window title as `.working` / `.waiting` / `.idle`
/// (used only by `AgentStateDetector.recompute` step 4). Guesses dressed as
/// patterns; ship disabled, tune only after observing real Claude titles (⚠️O3).
struct AgentTitleHeuristic: Sendable {
    var enabled: Bool
    var workingMarkers: [String]
    var waitingMarkers: [String]

    /// Returns `.working`, `.waiting`, or `.idle` (the catch-all "no opinion").
    func classify(title: String) -> AgentState {
        guard enabled else { return .idle }
        let lowered = title.lowercased()
        for m in waitingMarkers where lowered.contains(m.lowercased()) { return .waiting }
        for m in workingMarkers where lowered.contains(m.lowercased()) { return .working }
        return .idle
    }

    nonisolated static let disabled = AgentTitleHeuristic(
        enabled: false, workingMarkers: [], waitingMarkers: []
    )

    /// Opt-in; ⚠️O3 verify against real titles before enabling.
    nonisolated static let experimental = AgentTitleHeuristic(
        enabled: true,
        workingMarkers: ["✳", "esc to interrupt", "running", "working"],
        waitingMarkers: ["?", "waiting", "(y/n)", "approve", "allow"]
    )
}
