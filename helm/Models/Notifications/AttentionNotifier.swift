import Foundation
import AppKit
import UserNotifications
import Combine

/// Posts local notifications for attention-worthy events (m3/m4). Two sources:
///   - PERSISTENT: server-side death from the B4 deaths.log stream (via
///     `notifyDeath`, called by `PersistenceCoordinator`).
///   - NON-PERSISTENT: the in-process `AgentStateDetector` attention ping (via
///     `notifyAttention`, wired through `SessionManager`/`TerminalSession`).
///
/// Local notifications require a real `.app` bundle launch — they don't post from a
/// bare `xcodebuild` binary (m3). If authorization is denied we fall back to the
/// menu-bar pulse (no crash). Tapping a notification deep-links via the
/// authoritative index reverse lookup (slug → SessionKey, M7).
///
/// GhosttyTerminal-FREE. `@MainActor`.
@MainActor
final class AttentionNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Set by the app root: deep-link a tapped notification to a session.
    var onDeepLink: ((SessionKey) -> Void)?

    private var authorized = false
    /// True only inside a real `.app` bundle (a bare binary has no bundle id).
    private let hasBundle: Bool

    override init() {
        self.hasBundle = Bundle.main.bundleIdentifier != nil
        super.init()
        guard hasBundle else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Request authorization once on launch (m3). Safe no-op outside a bundle.
    func requestAuthorization() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in self?.authorized = granted }
        }
    }

    // MARK: - Sources

    /// Persistent death (B4). `record` (from the index) carries the display label +
    /// the SessionKey for the deep-link payload.
    func notifyDeath(slug: String, code: Int32, record: TmuxSessionRecord?) {
        let title = record?.displayName ?? "Service"
        let body = code == 0 ? "Process exited." : "Process exited with code \(code)."
        post(identifier: "death-\(slug)", title: title, body: body, key: record?.sessionKey)
    }

    /// Non-persistent in-process attention (agent bell/notification). Posted only
    /// while the app is NOT active (you only want a banner when you're away).
    func notifyAttention(displayName: String, key: SessionKey) {
        guard !NSApp.isActive else { return }
        post(identifier: "attn-\(key.slug)", title: displayName,
             body: "Needs your attention.", key: key)
    }

    // MARK: - Posting

    private func post(identifier: String, title: String, body: String, key: SessionKey?) {
        guard hasBundle, authorized else { return }   // fallback: menu-bar pulse only.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let key {
            content.userInfo = ["slug": key.slug]
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let slug = response.notification.request.content.userInfo["slug"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let slug, let key = AttentionNotifier.slugResolver?(slug) {
                self.onDeepLink?(key)
            }
            completionHandler()
        }
    }

    /// The deep-link needs a SessionKey; the slug alone isn't reversible, so the
    /// app root injects a resolver that consults the authoritative index (M7).
    @MainActor static var slugResolver: ((String) -> SessionKey?)?
}
