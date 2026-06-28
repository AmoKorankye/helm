import XCTest
@testable import helm

/// Safety net for the scariest string in the app: the three-layer launcher quoting.
/// Pure table tests over worst-case inner commands. NO Process, NO IO — TmuxLauncher
/// is pure string construction, so these run as a host-app-less logic bundle.
final class TmuxLauncherTests: XCTestCase {

    private let tmux = "/opt/homebrew/bin/tmux"
    private let conf = "/Users/me/Library/Application Support/Helm/helm.conf"
    private let dir = "/Users/me/proj"

    // MARK: - shellSingleQuote (the core escape primitive)

    func testShellSingleQuoteWrapsPlainValue() {
        XCTAssertEqual(TmuxLauncher.shellSingleQuote("abc"), "'abc'")
    }

    func testShellSingleQuoteLeavesDoubleQuotesLiteral() {
        // Inside single quotes, `"` is literal — no escaping.
        XCTAssertEqual(TmuxLauncher.shellSingleQuote("a\"b"), "'a\"b'")
    }

    func testShellSingleQuoteEscapesSingleQuote() {
        // Every `'` becomes the 4-char sequence `'\''`.
        XCTAssertEqual(TmuxLauncher.shellSingleQuote("a'b"), "'a'\\''b'")
    }

    func testShellSingleQuoteRoundTripsStringWithBothQuoteKinds() throws {
        // The audit-N guarantee: a value with BOTH `'` and `"` survives an
        // eval round-trip through a real POSIX shell, recovering the exact bytes.
        let original = "he said 'hi' and \"bye\""
        let quoted = TmuxLauncher.shellSingleQuote(original)

        let recovered = try evalEcho(quoted)
        XCTAssertEqual(recovered, original)
    }

    func testShellSingleQuoteRoundTripsShellMetacharacters() throws {
        let original = "x $(date) && y; z | w `cmd` *"
        let quoted = TmuxLauncher.shellSingleQuote(original)
        let recovered = try evalEcho(quoted)
        XCTAssertEqual(recovered, original)
    }

    // MARK: - innerShellCommand (Layer 3)

    func testInnerShellCommandEmptyIsPlainLoginInteractiveShell() {
        XCTAssertEqual(TmuxLauncher.innerShellCommand(""), "/bin/zsh -lic")
    }

    func testInnerShellCommandWrapsAndEscapes() {
        XCTAssertEqual(
            TmuxLauncher.innerShellCommand("npm run dev"),
            "/bin/zsh -lic \"npm run dev\""
        )
        // Double quote in the command is backslash-escaped inside the wrapper.
        XCTAssertEqual(
            TmuxLauncher.innerShellCommand("echo \"hi\""),
            "/bin/zsh -lic \"echo \\\"hi\\\"\""
        )
        // Backslash is doubled.
        XCTAssertEqual(
            TmuxLauncher.innerShellCommand("a\\b"),
            "/bin/zsh -lic \"a\\\\b\""
        )
    }

    // MARK: - attachCommand structural invariants (table over worst-case commands)

    /// The worst-case inner commands the launcher must survive: quotes of both
    /// kinds, command substitution, logical/sequence operators, spaces, plus the
    /// real heartbeat / `npm run dev` / `claude` commands.
    private var worstCaseCommands: [String] {
        [
            "",                                            // plain login shell
            "claude",
            "npm run dev",
            "while true; do echo beat; sleep 5; done",     // heartbeat
            "echo 'single'",
            "echo \"double\"",
            "echo 'both' and \"both\"",
            "echo $(date)",
            "a && b",
            "a; b",
            "a | b",
            "ls -la /a b/c",
            "grep -r 'x' . && echo done",
            "x=$(foo); echo \"$x\"",
        ]
    }

    func testAttachCommandHasLoginShellWrapper() {
        for cmd in worstCaseCommands {
            let out = TmuxLauncher.attachCommand(
                slug: "helm-abc12345", innerCommand: cmd,
                workingDirectory: dir, confPath: conf, tmuxPath: tmux
            )
            XCTAssertTrue(
                out.hasPrefix("/bin/zsh -lc \""),
                "missing /bin/zsh -lc \"…\" wrapper for command: \(cmd)"
            )
            XCTAssertTrue(out.hasSuffix("\""), "wrapper not closed for command: \(cmd)")
        }
    }

    func testAttachCommandSocketFlagOnEveryTmuxCall() {
        for cmd in worstCaseCommands {
            let out = TmuxLauncher.attachCommand(
                slug: "helm-abc12345", innerCommand: cmd,
                workingDirectory: dir, confPath: conf, tmuxPath: tmux
            )
            // Every tmux invocation immediately follows the single-quoted tmux path
            // with `-L helm`. Count the tmux-path occurrences and the `-L helm`
            // occurrences; each tmux call must carry the socket flag.
            let tmuxSQ = TmuxLauncher.shellSingleQuote(tmux)
            let tmuxCalls = out.components(separatedBy: tmuxSQ).count - 1
            let socketFlags = out.components(separatedBy: "\(tmuxSQ) -L helm").count - 1
            XCTAssertEqual(
                tmuxCalls, socketFlags,
                "every tmux call must carry `-L helm` (command: \(cmd))"
            )
            // has-session, list-panes, kill-session, new-session x2, attach = 6 calls.
            XCTAssertEqual(tmuxCalls, 6, "expected 6 tmux invocations (command: \(cmd))")
        }
    }

    func testAttachCommandInterpolatedValuesAreSingleQuoted() {
        // dir/conf/tmux are always single-quoted into the launcher.
        let out = TmuxLauncher.attachCommand(
            slug: "helm-abc12345", innerCommand: "npm run dev",
            workingDirectory: "/a b/c", confPath: "/x/helm.conf", tmuxPath: tmux
        )
        // dir/conf/tmux have no `"`/`\`, so their single-quoted form passes through
        // Layer 1 unchanged and appears verbatim.
        XCTAssertTrue(out.contains(TmuxLauncher.shellSingleQuote("/a b/c")))
        XCTAssertTrue(out.contains(TmuxLauncher.shellSingleQuote("/x/helm.conf")))
        XCTAssertTrue(out.contains(TmuxLauncher.shellSingleQuote(tmux)))
        // The inner command is single-quoted as ONE tmux argument, then carried
        // through Layer 1 (which escapes the wrapper's `"`). Compare against the
        // value as it must appear AFTER Layer 1.
        let innerSQ = TmuxLauncher.shellSingleQuote(TmuxLauncher.innerShellCommand("npm run dev"))
        XCTAssertTrue(out.contains(layer1Escape(innerSQ)))
    }

    func testAttachCommandSingleQuoteInWorkingDirectorySurvives() {
        // A working directory containing a `'` must be escaped, not break the
        // launcher: shellSingleQuote turns `'` into `'\''`, then Layer 1 doubles
        // the backslash, so the final output contains `'\\''`.
        let evil = "/Users/me/it's mine"
        let out = TmuxLauncher.attachCommand(
            slug: "helm-q", innerCommand: "claude",
            workingDirectory: evil, confPath: conf, tmuxPath: tmux
        )
        XCTAssertTrue(out.contains(layer1Escape(TmuxLauncher.shellSingleQuote(evil))))
        XCTAssertTrue(out.contains("'\\\\''"), "single quote should survive as '\\\\'' after Layer 1")
    }

    /// Apply the same Layer-1 escaping the launcher's outer `/bin/zsh -lc "…"`
    /// wrapper applies: double backslashes, then escape double quotes.
    private func layer1Escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func testAttachCommandHasDeadPaneGuardAndExecAttach() {
        let out = TmuxLauncher.attachCommand(
            slug: "helm-abc12345", innerCommand: "claude",
            workingDirectory: dir, confPath: conf, tmuxPath: tmux
        )
        XCTAssertTrue(out.contains("has-session -t helm-abc12345"))
        XCTAssertTrue(out.contains("list-panes -t helm-abc12345 -F '#{pane_dead}'"))
        XCTAssertTrue(out.contains("kill-session -t helm-abc12345"))
        XCTAssertTrue(out.contains("exec "))
        XCTAssertTrue(out.contains("-u attach -t helm-abc12345"))
    }

    func testAttachCommandRespectsCustomSocket() {
        let out = TmuxLauncher.attachCommand(
            slug: "helm-x", innerCommand: "claude",
            workingDirectory: dir, confPath: conf, tmuxPath: tmux, socket: "custom"
        )
        XCTAssertTrue(out.contains("-L custom"))
        XCTAssertFalse(out.contains("-L helm "))
    }

    // MARK: - Helpers

    /// `eval echo <quoted>` through `/bin/sh` and return the recovered single
    /// argument. Proves the single-quoting is shell-safe (the audit-N round-trip).
    /// This runs `/bin/sh` only as a TEST oracle against the pure string — the
    /// production TmuxLauncher itself never invokes anything.
    private func evalEcho(_ quoted: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `printf %s` avoids echo's trailing newline / flag quirks.
        p.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
