import XCTest
@testable import helm

/// Cheap-win coverage of `SessionKey.slug` injectivity (M3) and `AnsiStripper`.
final class SessionKeySlugTests: XCTestCase {

    private let svc = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!

    func testPrimarySlugIsStableAndTmuxSafe() {
        let key = SessionKey(serviceID: svc, instance: .primary)
        XCTAssertEqual(key.slug, "helm-abcdef12")
        XCTAssertTrue(isTmuxSafe(key.slug))
    }

    func testWorktreeBranchesThatSanitizeAliseStillProduceDistinctSlugs() {
        // `feature/x` and `feature-x` both sanitize to `feature-x`, but their raw-
        // branch hashes differ, so the slugs MUST differ (injectivity, M3).
        let a = SessionKey(serviceID: svc, instance: .worktree(branch: "feature/x")).slug
        let b = SessionKey(serviceID: svc, instance: .worktree(branch: "feature-x")).slug
        XCTAssertNotEqual(a, b, "slug must be injective over the raw branch")
        XCTAssertTrue(isTmuxSafe(a))
        XCTAssertTrue(isTmuxSafe(b))
    }

    func testDetachedPathHashesAreDistinct() {
        // Two detached worktrees on different paths must produce distinct instances.
        let h1 = Worktree.shortHash("/repo/wt-a")
        let h2 = Worktree.shortHash("/repo/wt-b")
        XCTAssertNotEqual(h1, h2)
    }

    func testWorktreeSlugIsDistinctFromPrimary() {
        let primary = SessionKey(serviceID: svc, instance: .primary).slug
        let wt = SessionKey(serviceID: svc, instance: .worktree(branch: "main")).slug
        XCTAssertNotEqual(primary, wt)
    }

    func testShortHashIsStableAcrossCalls() {
        XCTAssertEqual(SessionKey.shortHash("feature/x"), SessionKey.shortHash("feature/x"))
    }

    private func isTmuxSafe(_ s: String) -> Bool {
        s.allSatisfy { ($0.isLowercase && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "-" }
    }
}

final class AnsiStripperTests: XCTestCase {

    func testKeepsPlainText() {
        XCTAssertEqual(AnsiStripper.strip("hello world"), "hello world")
    }

    func testStripsCSIColorSequence() {
        // ESC[31m red ESC[0m
        let input = "\u{1B}[31mred\u{1B}[0m"
        XCTAssertEqual(AnsiStripper.strip(input), "red")
    }

    func testStripsOSCSequenceTerminatedByBEL() {
        // ESC]0;title BEL  (set window title)
        let input = "\u{1B}]0;my title\u{07}body"
        XCTAssertEqual(AnsiStripper.strip(input), "body")
    }

    func testStripsOSCSequenceTerminatedByST() {
        // ESC]0;title ESC\  (string terminator)
        let input = "\u{1B}]0;my title\u{1B}\\body"
        XCTAssertEqual(AnsiStripper.strip(input), "body")
    }

    func testKeepsNewlinesAndTabs() {
        XCTAssertEqual(AnsiStripper.strip("a\tb\nc"), "a\tb\nc")
    }

    func testDropsStrayControlChars() {
        // A bare bell in the stream is dropped; surrounding text kept.
        XCTAssertEqual(AnsiStripper.strip("a\u{07}b"), "ab")
    }
}
