import Foundation

/// Deep module: the ONLY file that shells out to git. Narrow interface (one async
/// method), deep implementation (git invocation + porcelain parsing + every edge
/// case). GhosttyTerminal-free, SwiftUI-free.
struct WorktreeService {
    /// Absolute path to git, resolved once (grill M3: a Process with no inherited
    /// env has no PATH, so `/usr/bin/env git` can fail — probe fixed paths instead).
    let gitPath: String?

    init(gitPath: String? = WorktreeService.resolveGit()) {
        self.gitPath = gitPath
    }

    /// Run `git -C <project.directory> worktree list --porcelain` off the main
    /// thread and parse it. NEVER throws — every failure folds into `.unavailable`
    /// so a non-git project simply shows no worktrees.
    func worktrees(for project: Project) async -> WorktreeScan {
        guard let gitPath else { return .unavailable(reason: .gitNotFound) }
        let directory = project.directory

        return await withCheckedContinuation { continuation in
            // Off-main: Process IO must not block the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runGit(gitPath: gitPath, directory: directory)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Internals

    /// Blocking git invocation + parse. Injection-safe: `directory` is passed as a
    /// `-C` ARGUMENT, never interpolated into a shell string. NO `/bin/sh -c`.
    private static func runGit(gitPath: String, directory: String) -> WorktreeScan {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", directory, "worktree", "list", "--porcelain"]
        // A Process inherits no env by default here; give git a minimal explicit
        // PATH so it can locate any helpers it needs. The directory is an argument.
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            // git not located / not executable / spawn failure.
            return .unavailable(reason: .gitNotFound)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // ANY non-zero exit → feature unavailable. We do NOT locale-fragile
            // string-match stderr; exit 128 is the typical not-a-repo case.
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            #if DEBUG
            // A non-git project is the EXPECTED graceful-degradation path (exit 128
            // + "not a git repository"), not an error — don't spam the console for it.
            // Only log genuinely unexpected non-zero exits.
            let isExpectedNonRepo = stderr.localizedCaseInsensitiveContains("not a git repository")
            if !stderr.isEmpty, !isExpectedNonRepo {
                NSLog("[WorktreeService] git exit \(process.terminationStatus) for \(directory): \(stderr)")
            }
            #endif
            return .unavailable(reason: .notAGitRepo)
        }

        let porcelain = String(data: outData, encoding: .utf8) ?? ""
        let list = parse(porcelain: porcelain)
        guard !list.isEmpty else {
            // Exit 0 but nothing parsed → treat as unavailable (defensive).
            return .unavailable(reason: .gitError("empty worktree list"))
        }
        return .available(list)
    }

    /// Pure: porcelain text → [Worktree]. No I/O. The primary unit-test target.
    ///
    /// Porcelain shape: records separated by a blank line; the whole output ends
    /// with a trailing `\n\n` → a phantom empty trailing record that MUST be
    /// filtered (grill B4). Each line is `<key> <value>` or a bare flag.
    static func parse(porcelain: String) -> [Worktree] {
        let records = porcelain.components(separatedBy: "\n\n")
        var result: [Worktree] = []
        var assignedMain = false

        for record in records {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

            var path: String?
            var branch: String?
            var head: String?
            var isBare = false
            var isLocked = false
            var isDetached = false
            var isPrunable = false

            for line in lines {
                // Split on the FIRST whitespace: key = first token, value = remainder.
                let trimmed = line
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""

                switch key {
                case "worktree":
                    path = Self.standardize(value)
                case "HEAD":
                    head = value.isEmpty ? nil : value
                case "branch":
                    branch = Self.stripRefsHeads(value)
                case "detached":
                    isDetached = true
                    branch = nil
                case "bare":
                    isBare = true
                case "locked":
                    isLocked = true   // presence flag; ignore any trailing reason (B4).
                case "prunable":
                    isPrunable = true // presence flag; ignore any trailing reason (B4).
                default:
                    break             // unknown key → ignore (forward-compatible).
                }
            }

            // Filter the trailing-`\n\n` phantom (and any record lacking a
            // `worktree` line — a real record always has one, B4).
            guard let path else { continue }

            // First non-phantom record is the main worktree (git emits it first);
            // exactly one isMain (m9). Subsequent records are linked worktrees.
            let isMain = !assignedMain
            assignedMain = true

            result.append(
                Worktree(
                    path: path,
                    branch: branch,
                    head: head,
                    isMain: isMain,
                    isBare: isBare,
                    isLocked: isLocked,
                    isDetached: isDetached,
                    isPrunable: isPrunable
                )
            )
        }

        return result
    }

    /// Standardize a path so symlink-resolved git paths match across re-scans and
    /// serve as a stable hash input.
    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func stripRefsHeads(_ ref: String) -> String {
        let prefix = "refs/heads/"
        if ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// Locate git by probing fixed executable paths with `isExecutableFile`, in
    /// order: /opt/homebrew/bin/git, /usr/bin/git. Returns nil if none found
    /// (→ scan = .unavailable(.gitNotFound)). NEVER relies on PATH/`env` under an
    /// empty process environment (grill M3).
    static func resolveGit() -> String? {
        let candidates = ["/opt/homebrew/bin/git", "/usr/bin/git", "/usr/local/bin/git"]
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
