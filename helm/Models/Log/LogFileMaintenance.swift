import Foundation

/// On-disk size-cap / rotation for append-only log files (M6 / R3): the per-session
/// `pipe-pane` capture and the shared deaths.log are otherwise unbounded.
/// Truncate-from-head: when a file exceeds the cap, keep the last `keepBytes` and
/// rewrite. Pure Foundation, no I/O loop — invoked on session create + on launch.
enum LogFileMaintenance {
    /// Cap a file: if larger than `capBytes`, rewrite keeping the trailing
    /// `keepBytes`. Safe no-op if the file is missing or under the cap.
    ///
    /// MUST NOT run while a `LogTail` is attached to the same file: the `.atomic`
    /// rewrite below swaps the inode, which desyncs the tail's saved read offset.
    static func cap(fileURL: URL, capBytes: Int = 5 * 1024 * 1024, keepBytes: Int = 1 * 1024 * 1024) {
        let path = fileURL.path
        // `.size` is read as `UInt64` for consistency with `LogTail`.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64, size > UInt64(capBytes) else { return }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        let start = size > UInt64(keepBytes) ? size - UInt64(keepBytes) : 0
        try? handle.seek(toOffset: start)
        let tailData = handle.readDataToEndOfFile()
        try? tailData.write(to: fileURL, options: .atomic)
    }

    /// Truncate a file to empty (deaths.log after ingest on launch, R3).
    static func truncate(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? Data().write(to: fileURL, options: .atomic)
    }
}
