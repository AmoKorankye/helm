import Foundation

/// Deep module: the ONLY file in Helm that shells out to tmux. Narrow interface
/// (command construction + discovery/liveness + lifecycle + log piping), deep
/// implementation (path resolution, config management, the launcher's three quote
/// layers, `-F` format-string parsing, every edge). Mirrors `WorktreeService`:
/// `Process` with `executableURL`, args-as-ARRAY (never `/bin/sh -c`, injection-
/// safe), explicit minimal PATH, off-main, parse `-F` output.
///
/// GhosttyTerminal-free, SwiftUI-free.
///
/// B2: EVERY tmux invocation passes `-L helm` as the FIRST arg. Helm owns its own
/// tmux server on this dedicated socket, isolated from the user's default-socket
/// tmux, which makes `-f helm.conf` deterministic (Helm controls the first server
/// start) and means Helm's `set -g` never stomps the user's sessions.
struct TmuxService: Sendable {
    /// The dedicated socket name — `-L helm`, used on EVERY invocation (B2).
    static let socket = "helm"

    /// Absolute path to tmux, resolved once via fixed-path probe (a `Process` with
    /// no inherited env has no PATH, so `/usr/bin/env tmux` can fail — probe
    /// instead, exactly like `WorktreeService.resolveGit`).
    let tmuxPath: String?

    nonisolated init(tmuxPath: String? = TmuxService.resolveTmux()) {
        self.tmuxPath = tmuxPath
    }

    var isAvailable: Bool { tmuxPath != nil }

    // MARK: - Liveness result

    /// Outcome of a single liveness query. `paneDead` carries the inner command's
    /// exit code (readable thanks to `remain-on-exit on`). `gone` = the session no
    /// longer exists (list-panes errored/empty).
    enum Liveness: Equatable {
        case alive(attached: Bool)
        case paneDead(code: Int32)
        case gone
    }

    // MARK: - Command construction (delegates to pure TmuxLauncher, B1)

    /// The full `/bin/zsh -lc "<launcher>"` string handed to ghostty's
    /// `config.custom("command", …)` for a PERSISTENT service. The three quote
    /// layers are PURE string construction and live in `TmuxLauncher`; this method
    /// only supplies the resolved tmux path (the one piece of IO-derived state) and
    /// the socket, then delegates. Byte-identical to the pre-extraction output.
    func attachCommand(slug: String,
                       innerCommand: String,
                       workingDirectory: String,
                       confPath: String) -> String {
        TmuxLauncher.attachCommand(
            slug: slug,
            innerCommand: innerCommand,
            workingDirectory: workingDirectory,
            confPath: confPath,
            tmuxPath: tmuxPath ?? "/opt/homebrew/bin/tmux",
            socket: Self.socket
        )
    }

    // MARK: - Discovery / liveness (bounded; off-main; -L helm; M1 ordering)

    /// ONE `list-sessions` for app-activate refresh + launch reattach (m1 — never
    /// O(N) per-session spawns). Returns `[]` on any error/empty server.
    func listSessions() -> [(slug: String, dead: Bool, attached: Bool)] {
        let out = run(["list-sessions", "-F", "#{session_name} #{pane_dead} #{session_attached}"])
        guard let out else { return [] }
        var result: [(slug: String, dead: Bool, attached: Bool)] = []
        for line in out.split(separator: "\n") {
            // Fixed-position fields: `pane_dead` (middle) can be empty, so DON'T omit
            // empty subsequences — that would shift `session_attached` left.
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            result.append((slug: String(f[0]), dead: f[1] == "1", attached: f[2] == "1"))
        }
        return result
    }

    /// Liveness for one session. Queries `list-panes` FIRST (M1) — NEVER
    /// `has-session` (a dead-pane session returns `has-session`==0, audit G). An
    /// error/empty result → `.gone`.
    func sessionLiveness(slug: String) -> Liveness {
        let out = run(["list-panes", "-t", slug, "-F",
                       "#{pane_dead} #{pane_dead_status} #{session_attached}"])
        guard let out else { return .gone }
        let line = out.split(separator: "\n").first.map(String.init) ?? ""
        // Fixed-position fields `pane_dead pane_dead_status session_attached`:
        // `pane_dead_status` (middle) is empty for a live pane, so DON'T omit empty
        // subsequences — that would shift `session_attached` left and misread it.
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { return .gone }
        if f[0] == "1" {
            let code = Int32(f[1]) ?? 0
            return .paneDead(code: code)
        }
        let attached = f[2] == "1"
        return .alive(attached: attached)
    }

    // MARK: - Lifecycle

    /// Kill a session and VERIFY it is gone (M4): returns true iff after the kill
    /// `sessionLiveness == .gone`. A kill of a non-existent session is treated as
    /// success (already gone). Used by Stop/Restart/Delete kill-first ordering.
    @discardableResult
    func killSession(slug: String) -> Bool {
        _ = run(["kill-session", "-t", slug])
        if case .gone = sessionLiveness(slug: slug) { return true }
        return false
    }

    /// Write `helm.conf` (idempotent) and return its path. Always overwrites with
    /// the current canonical contents so an upgrade refreshes the conf. The
    /// `pane-died` hook (B4) embeds the absolute deaths.log path.
    @discardableResult
    func ensureConfig() -> String? {
        guard let dir = Self.supportDirectory() else { return nil }
        let confURL = dir.appendingPathComponent("helm.conf")
        let deathsPath = dir.appendingPathComponent("deaths.log").path
        let contents = Self.configContents(deathsLogPath: deathsPath)
        do {
            try contents.write(to: confURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return confURL.path
    }

    /// Canonical helm.conf (§6.2). The `pane-died` hook is the PRIMARY status
    /// source (B4): on inner-pane death it appends `<slug> <exitcode>` to
    /// deaths.log, which Helm tails via EVFILT_VNODE — fires even while detached.
    static func configContents(deathsLogPath: String) -> String {
        // The hook value is itself a quoted run-shell string; the path is single-
        // quoted inside it so a space in "Application Support" is safe.
        let pathSQ = TmuxLauncher.shellSingleQuote(deathsLogPath)
        return """
        set  -g  remain-on-exit on
        set  -g  destroy-unattached off
        set  -g  status off
        set  -g  default-terminal 'tmux-256color'
        set  -g  allow-passthrough on
        set  -g  set-titles on
        set  -g  set-titles-string '#T'
        setw -g  allow-rename on
        setw -g  monitor-bell on
        set  -g  visual-bell off
        set-hook -g pane-died 'run-shell "echo \\"#{session_name} #{pane_dead_status}\\" >> \(pathSQ)"'

        """
    }

    // MARK: - Log panel (§8)

    /// Begin piping the session's pane to a file (RAW PTY bytes incl. ANSI — the
    /// caller ANSI-strips before display, M6). `-o` toggles the pipe on.
    func startPipePane(slug: String, toFile path: String) {
        let pathSQ = TmuxLauncher.shellSingleQuote(path)
        _ = run(["pipe-pane", "-t", slug, "-o", "cat >> \(pathSQ)"])
    }

    /// Stop piping (a bare `pipe-pane` with no command turns it off).
    func stopPipePane(slug: String) {
        _ = run(["pipe-pane", "-t", slug])
    }

    // MARK: - Internals

    /// Blocking tmux invocation with `-L helm` prepended (B2). Returns stdout on
    /// exit 0, else nil. Injection-safe: args are an ARRAY, never a shell string.
    /// Explicit minimal env (a `Process` inherits none here).
    @discardableResult
    private func run(_ args: [String]) -> String? {
        guard let tmuxPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-L", Self.socket] + args
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }
        // Bound the wait so a hung tmux can never stall a caller (M4: a Stop that
        // never resolves would let the dot lie). Watchdog terminates a process that
        // overruns; the read then completes and we report failure (nil).
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: outData, encoding: .utf8)
    }

    /// The `~/Library/Application Support/Helm` directory, created if absent.
    static func supportDirectory() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Helm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Absolute deaths.log path (the B4 marker file the conf hook appends to).
    static func deathsLogPath() -> URL? {
        supportDirectory()?.appendingPathComponent("deaths.log")
    }

    /// The per-session log file path for the log panel (§8).
    static func sessionLogPath(slug: String) -> URL? {
        guard let dir = supportDirectory() else { return nil }
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("\(slug).log")
    }

    /// Locate tmux by probing fixed paths (NEVER PATH/`env` under an empty process
    /// environment). Mirrors `WorktreeService.resolveGit`.
    nonisolated static func resolveTmux() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
