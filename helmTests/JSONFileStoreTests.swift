import XCTest
@testable import helm

/// Tests for the atomic-JSON persistence primitive. Uses the `init(filename:directory:)`
/// seam with a per-test temp directory under NSTemporaryDirectory — NEVER touches
/// the real `~/Library/Application Support/Helm/*` files.
final class JSONFileStoreTests: XCTestCase {

    private struct Payload: Codable, Equatable {
        var name: String
        var count: Int
        var tags: [String]
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func store(_ filename: String = "store.json") -> JSONFileStore<Payload> {
        JSONFileStore<Payload>(filename: filename, directory: tempDir)
    }

    func testRoundTripSaveThenLoadEqualsInput() throws {
        let value = Payload(name: "alpha", count: 3, tags: ["a", "b"])
        let s = store()
        try s.save(value)
        let loaded = try s.load()
        XCTAssertEqual(loaded, value)
    }

    func testMissingFileLoadsNil() throws {
        let loaded = try store("does-not-exist.json").load()
        XCTAssertNil(loaded)
    }

    func testEmptyFileLoadsNil() throws {
        let s = store("empty.json")
        let url = tempDir.appendingPathComponent("empty.json")
        try Data().write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let loaded = try s.load()
        XCTAssertNil(loaded, "present-but-empty file must be treated as first launch")
    }

    func testCorruptFileThrowsAndNeverReturnsPartial() throws {
        let s = store("corrupt.json")
        let url = tempDir.appendingPathComponent("corrupt.json")
        try Data("{ this is not valid json".utf8).write(to: url)
        XCTAssertThrowsError(try s.load(), "corrupt file must throw, never return partial data")
    }

    func testAtomicOverwriteReplacesContent() throws {
        let s = store()
        try s.save(Payload(name: "first", count: 1, tags: []))
        try s.save(Payload(name: "second", count: 2, tags: ["x"]))
        let loaded = try s.load()
        XCTAssertEqual(loaded, Payload(name: "second", count: 2, tags: ["x"]))
    }

    func testSaveLeavesNoTempFilesBehind() throws {
        let s = store()
        try s.save(Payload(name: "x", count: 1, tags: []))
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let temps = contents.filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(temps.isEmpty, "atomic save must clean up its temp file, found: \(temps)")
    }
}
