import Foundation
import Combine

/// Decides whether a crashed/exited session should auto-restart, per the
/// service's `restartPolicy`, with exponential backoff, an attempt cap, and a
/// cancellable reset window. It *decides*; it never owns a surface or spawns a
/// process — it calls `SessionManager.rebuild(key:)` and reads `ProjectStore`
/// for the live policy (HANDOVER §9 dec 6, plan §5). GhosttyTerminal-free.
///
/// Zero-poll: the only timers are the cancellable one-shot backoff delay and the
/// cancellable one-shot 30s reset window — both armed on demand, both cancelled
/// on manual stop / restart / delete (grill m1, m2).
@MainActor
final class ProcessSupervisor: ObservableObject {
    private unowned let sessions: SessionManager
    private unowned let store: ProjectStore

    private var attempts: [SessionKey: Int] = [:]
    private var backoffWork: [SessionKey: DispatchWorkItem] = [:]
    private var resetTimer: [SessionKey: DispatchSourceTimer] = [:]

    private let maxAttempts = 5
    /// Exponential backoff schedule (seconds), capped at 16s (plan §5/§10).
    private let backoffSchedule: [Double] = [1, 2, 4, 8, 16]
    private let resetWindowSeconds: Double = 30

    private var cancellable: AnyCancellable?

    init(sessions: SessionManager, store: ProjectStore) {
        self.sessions = sessions
        self.store = store
        cancellable = sessions.exitEvents
            .sink { [weak self] event in
                self?.handle(event)
            }
    }

    // MARK: - Decide

    func handle(_ event: ExitEvent) {
        let policy = store.restartPolicy(forServiceID: event.key.serviceID)
        guard shouldRestart(status: event.status, policy: policy) else {
            // A clean/user exit (or `.never`) ends any pending backoff and any
            // armed reset window for this key — nothing should resurrect it.
            cancelPending(event.key)
            return
        }

        let count = attempts[event.key, default: 0]
        guard count < maxAttempts else {
            // Crash-loop + battery cap: leave it dead, manual restart only.
            return
        }
        scheduleRestart(event.key, attempt: count)
    }

    /// Restart decision from `status` alone (intent already encoded). Under
    /// ghostty's `.exec` backend the close callback yields no exit code, so a
    /// crash and a clean spontaneous exit are indistinguishable — both surface as
    /// a non-user `.exited`. We therefore treat ANY non-user exit (or a genuinely
    /// observed `.crashed`, should a future signal source produce one) as the
    /// "the process died on its own" event that drives BOTH `.onCrash` and
    /// `.always`. A user Stop (`byUser == true`) never auto-restarts.
    private func shouldRestart(status: SessionStatus, policy: RestartPolicy) -> Bool {
        let diedOnItsOwn: Bool
        switch status {
        case .crashed:
            diedOnItsOwn = true
        case let .exited(_, byUser):
            diedOnItsOwn = (byUser == false)
        default:
            diedOnItsOwn = false
        }
        switch policy {
        case .never:
            return false
        case .onCrash, .always:
            return diedOnItsOwn
        }
    }

    // MARK: - Schedule (cancellable one-shots)

    private func scheduleRestart(_ key: SessionKey, attempt: Int) {
        let delay = backoffSchedule[min(attempt, backoffSchedule.count - 1)]
        attempts[key] = attempt + 1

        backoffWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backoffWork[key] = nil
            // Rebuild in place under the same key with the CURRENT saved config
            // (respects edits made while the session was down, m4/m5).
            if let (service, project) = self.store.service(id: key.serviceID) {
                self.sessions.rebuild(
                    key: key,
                    command: service.command,
                    workingDirectory: project.directory
                )
            } else {
                self.sessions.rebuild(key: key)
            }
            self.armResetWindow(key)
        }
        backoffWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// After a restart, if the new session survives `resetWindowSeconds`, zero the
    /// attempt counter (a stable run shouldn't count earlier crashes). Cancelled
    /// (not merely ignored) on the next exit/stop/restart/delete so it can't reset
    /// a counter for a session that already died (m1).
    private func armResetWindow(_ key: SessionKey) {
        resetTimer[key]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + resetWindowSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.attempts[key] = 0
            self.resetTimer[key]?.cancel()
            self.resetTimer[key] = nil
        }
        resetTimer[key] = timer
        timer.resume()
    }

    // MARK: - Cancellation

    /// Cancel any pending backoff + reset window for a key. Called by the app on
    /// manual Stop / manual Restart / service-or-project delete, so a stopped or
    /// removed service can never zombie-restart (m2), and a dead session's reset
    /// window can't fire (m1).
    func cancel(_ key: SessionKey) {
        cancelPending(key)
        attempts[key] = 0
    }

    private func cancelPending(_ key: SessionKey) {
        backoffWork[key]?.cancel()
        backoffWork[key] = nil
        resetTimer[key]?.cancel()
        resetTimer[key] = nil
    }
}
