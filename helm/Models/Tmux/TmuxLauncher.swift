import Foundation

/// Pure, dependency-free string construction for the tmux launcher command — the
/// three quote layers that were the riskiest string in the app, now extracted from
/// `TmuxService`'s IO so they are table-testable in isolation.
///
/// **§9 seal note:** This type performs NO tmux invocation, NO `Process`, NO IO,
/// NO filesystem access — it is pure string building only. `TmuxService` remains
/// the ONLY tmux *invoker*; this is pure *string construction*. The "only tmux
/// caller" decision still holds. Keep it that way: TmuxLauncher must not run
/// anything.
///
/// Foundation-only — no SwiftUI, no GhosttyTerminal.
enum TmuxLauncher {
    /// The dedicated socket name — `-L helm`, used on EVERY invocation (B2).
    /// Mirrors `TmuxService.socket`; `TmuxService` passes its own value in so the
    /// two never drift.
    static let defaultSocket = "helm"

    /// The full `/bin/zsh -lc "<launcher>"` string handed to ghostty's
    /// `config.custom("command", …)` for a PERSISTENT service. ghostty argv-splits
    /// this and execs token 0 (`/bin/zsh`) with args `-lc` and the double-quoted
    /// launcher — so the launcher itself runs under a login shell (Layer 1).
    ///
    /// The launcher (Layer 2) is a single `;`-joined shell line: has-session →
    /// dead-pane guard (M2) → create-or-skip → `exec attach`. Every interpolated
    /// value (dir, inner command, conf, tmux) is `shellSingleQuote`d so a value
    /// containing `'` and/or `"` survives intact (verified round-trip, audit N).
    ///
    /// `innerCommand` (Layer 3) is the user's command; it is wrapped as
    /// `/bin/zsh -lic "<command>"` — byte-identical environment semantics to the
    /// non-persistent path — then single-quoted as ONE tmux argument.
    static func attachCommand(slug: String,
                              innerCommand: String,
                              workingDirectory: String,
                              confPath: String,
                              tmuxPath: String,
                              socket: String = defaultSocket) -> String {
        let inner = innerShellCommand(innerCommand)
        let innerSQ = shellSingleQuote(inner)
        let dirSQ = shellSingleQuote(workingDirectory)
        let confSQ = shellSingleQuote(confPath)
        let tmuxSQ = shellSingleQuote(tmuxPath)

        // Layer 2 — the launcher shell line. `slug` is `[a-z0-9-]`-safe so it needs
        // no quoting; dir/inner/conf/tmux are single-quoted.
        let create = "\(tmuxSQ) -L \(socket) -f \(confSQ) new-session -d -s \(slug) -c \(dirSQ) \(innerSQ)"
        let launcher =
            "if \(tmuxSQ) -L \(socket) has-session -t \(slug) 2>/dev/null; then "
            + "if [ \"$(\(tmuxSQ) -L \(socket) list-panes -t \(slug) -F '#{pane_dead}' 2>/dev/null | head -1)\" = \"1\" ]; then "
            + "\(tmuxSQ) -L \(socket) kill-session -t \(slug); \(create); fi; "
            + "else \(create); fi; "
            + "exec \(tmuxSQ) -L \(socket) -u attach -t \(slug)"

        // Layer 1 — wrap for ghostty: /bin/zsh -lc "<launcher>". Escape only what a
        // double-quoted zsh string needs: `\` and `"`. The launcher contains no
        // bare `` ` `` or `$` outside the single-quoted `$(...)` (which we WANT zsh
        // to evaluate), so they're left intact.
        let escaped = launcher
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/zsh -lc \"\(escaped)\""
    }

    /// The Layer-3 inner command: `/bin/zsh -lic "<command>"` (matches the non-
    /// persistent path exactly). An empty command → a plain login interactive shell.
    static func innerShellCommand(_ command: String) -> String {
        if command.isEmpty {
            return "/bin/zsh -lic"
        }
        // Inside the double-quoted inner string, escape `\` and `"` (the same rule
        // the non-persistent path relies on implicitly).
        let esc = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/zsh -lic \"\(esc)\""
    }

    /// Wrap a value for safe inclusion in a POSIX shell line: enclose in single
    /// quotes, replacing every `'` with the 4-char sequence `'\''`. Double quotes
    /// and every other metacharacter are literal inside single quotes. Verified
    /// `eval`-round-trip against a value containing BOTH `'` and `"` (audit N).
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
