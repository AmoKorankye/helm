import Foundation

/// Push-based file tail using `DispatchSource.makeFileSystemObjectSource`
/// (Swift's `EVFILT_VNODE`). Zero-poll: the kernel notifies on `.write`/`.extend`;
/// we read only the bytes appended since the last offset and hand them to a
/// callback. Used for BOTH the per-session log panel (§8) and the deaths.log
/// status marker stream (B4) — the one tail mechanism the plan reuses.
///
/// GhosttyTerminal-free, SwiftUI-free. Not an actor — callers drive it on the main
/// actor (PersistenceCoordinator / SessionLog).
final class LogTail {
    private let url: URL
    private let onAppend: (String) -> Void

    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    /// Bytes read but not yet decodable as UTF-8 (a multibyte sequence split at the
    /// read boundary). Prepended to the next read so no bytes are ever dropped.
    private var carry = Data()
    /// The serial queue the vnode source fires on; reads happen here, the callback
    /// is hopped to the main queue by the owner if needed.
    private let queue = DispatchQueue(label: "helm.logtail")

    /// - Parameters:
    ///   - url: file to tail (created if absent so the descriptor opens).
    ///   - fromEnd: start at EOF (deaths.log: only NEW deaths) or from the start
    ///     (log panel: show existing content first).
    ///   - onAppend: invoked with each newly-appended chunk (already UTF-8 decoded).
    init(url: URL, fromEnd: Bool, onAppend: @escaping (String) -> Void) {
        self.url = url
        self.onAppend = onAppend
        start(fromEnd: fromEnd)
    }

    deinit { stop() }

    private func start(fromEnd: Bool) {
        // Ensure the file exists so we can open + watch it.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        // Seed the offset: from current EOF, or 0 (then drain existing content).
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        offset = fromEnd ? size : 0

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent(src.data)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd) }
            self?.fileDescriptor = -1
        }
        source = src
        src.resume()

        // Drain any pre-existing content (log panel from-start case).
        if !fromEnd {
            queue.async { [weak self] in self?.drain() }
        }
    }

    private func handleEvent(_ data: DispatchSource.FileSystemEvent) {
        // If the file was deleted/rotated, reset the offset so we don't read garbage.
        if data.contains(.delete) || data.contains(.rename) {
            offset = 0
        }
        drain()
    }

    /// Read appended bytes from `offset` to current EOF and forward them.
    private func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            offset = 0
            return
        }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        offset += UInt64(data.count)
        // Prepend any carried bytes from a previous boundary-split sequence.
        var combined = carry
        combined.append(data)
        if let text = String(data: combined, encoding: .utf8) {
            carry.removeAll(keepingCapacity: true)
            onAppend(text)
        } else {
            // A trailing multibyte sequence is incomplete. Decode the largest valid
            // prefix, carry the remainder for the next read. Walk back up to 3 bytes
            // (max UTF-8 continuation length we'd be missing for BMP; 4 for astral —
            // walk back up to 3 trailing continuation bytes + lead = 4).
            var keep = combined.count
            while keep > 0 && combined.count - keep < 4 {
                keep -= 1
                if let text = String(data: combined.prefix(keep), encoding: .utf8) {
                    carry = combined.suffix(combined.count - keep)
                    if !text.isEmpty { onAppend(text) }
                    return
                }
            }
            // Could not decode at all — carry everything and wait for more bytes.
            carry = combined
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
