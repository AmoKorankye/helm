import SwiftUI

/// Overlay shown over the selected session's terminal when its process ended.
/// Under ghostty's `.exec` backend a spontaneous exit carries no exit code, so we
/// do NOT claim it "crashed" or "disappeared" — a non-user exit
/// (`.exited(byUser:false)`) shows a neutral "Process exited" with a one-click
/// Restart (plan §7, HANDOVER §9 dec 9). The ghostty surface stays mounted behind
/// it (its own "process exited" text shows, dimmed).
///
/// For `.exited(byUser:true)` — a deliberate Stop — it shows a quieter "Stopped"
/// treatment (no alarming red) that still offers one-click Restart and covers the
/// surface we tore down. `.crashed` (red) is reserved for a genuinely-observed
/// fatal outcome, which the current backend does not produce.
struct RestartOverlay: View {
    @ObservedObject var session: TerminalSession
    /// Rebuilds the session in place (same key) — wired by the parent to
    /// `SessionManager.rebuild` with the current saved command/dir.
    let onRestart: () -> Void

    var body: some View {
        Group {
            if let banner = banner {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: banner.icon)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(banner.tint)
                        Text(banner.title)
                            .font(.title3.weight(.semibold))
                        Text(banner.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(action: onRestart) {
                            Label("Restart", systemImage: "arrow.triangle.2.circlepath")
                                .frame(minWidth: 120)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 340)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: shouldShow)
    }

    private var shouldShow: Bool { banner != nil }

    private struct Banner {
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
    }

    private var banner: Banner? {
        switch session.status {
        case let .crashed(reason):
            return Banner(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "Process crashed",
                subtitle: reasonText(reason)
            )
        case let .exited(code, byUser) where byUser == false:
            return Banner(
                icon: "stop.circle",
                tint: .gray,
                title: "Process exited",
                subtitle: code.map { "Exited with code \($0). Restart to run it again." }
                    ?? "The process ended. Restart to run it again."
            )
        case .exited(_, byUser: true):
            // Deliberate Stop: quiet, non-alarming. Also covers the surface we
            // tore down in the no-pid (E-degraded) Stop path.
            return Banner(
                icon: "stop.circle",
                tint: .secondary,
                title: "Stopped",
                subtitle: "You stopped this process. Restart to run it again."
            )
        default:
            return nil
        }
    }

    private func reasonText(_ reason: ExitReason) -> String {
        switch reason {
        case let .exited(code): return "Exited with code \(code). Restart to try again."
        case let .signalled(sig): return "Terminated by signal \(sig). Restart to try again."
        case .unknown: return "The process ended. Restart to run it again."
        }
    }
}
