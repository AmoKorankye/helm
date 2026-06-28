import XCTest
@testable import helm

/// Cheap-win coverage of the pure porcelain parser (`git worktree list --porcelain`
/// → [Worktree]). No git, no IO — fixtures only.
final class WorktreeParseTests: XCTestCase {

    func testBareMainAndLinkedBranch() {
        // Bare main (no HEAD line) + a linked branch worktree. Trailing `\n\n`.
        let porcelain = """
        worktree /repo/main
        bare

        worktree /repo/wt-feature
        HEAD abc123
        branch refs/heads/feature/x

        """
        let list = WorktreeService.parse(porcelain: porcelain)
        XCTAssertEqual(list.count, 2)

        let main = list[0]
        XCTAssertTrue(main.isMain)
        XCTAssertTrue(main.isBare)
        XCTAssertNil(main.head, "bare record has no HEAD line")
        XCTAssertNil(main.branch)

        let linked = list[1]
        XCTAssertFalse(linked.isMain)
        XCTAssertEqual(linked.head, "abc123")
        XCTAssertEqual(linked.branch, "feature/x", "refs/heads/ prefix is stripped")
    }

    func testDetachedWorktreeHasNoBranch() {
        let porcelain = """
        worktree /repo/main
        HEAD aaa
        branch refs/heads/main

        worktree /repo/detached
        HEAD deadbeef
        detached

        """
        let list = WorktreeService.parse(porcelain: porcelain)
        XCTAssertEqual(list.count, 2)
        let detached = list[1]
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head, "deadbeef")
    }

    func testPrunableFlag() {
        let porcelain = """
        worktree /repo/main
        HEAD aaa
        branch refs/heads/main

        worktree /repo/gone
        HEAD bbb
        branch refs/heads/old
        prunable

        """
        let list = WorktreeService.parse(porcelain: porcelain)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[1].isPrunable)
        XCTAssertFalse(list[1].isSpawnableChild, "prunable rows are not spawnable")
    }

    func testPrunableWithReasonIsStillJustAFlag() {
        let porcelain = """
        worktree /repo/main
        HEAD aaa
        branch refs/heads/main

        worktree /repo/gone
        HEAD bbb
        prunable gitdir file points to non-existent location

        """
        let list = WorktreeService.parse(porcelain: porcelain)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[1].isPrunable, "trailing reason must not break flag detection")
    }

    func testTrailingBlankPhantomRecordIsFiltered() {
        // Exactly one real record; the trailing `\n\n` must NOT produce a phantom.
        let porcelain = """
        worktree /repo/main
        HEAD aaa
        branch refs/heads/main

        """
        let list = WorktreeService.parse(porcelain: porcelain)
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].isMain)
    }
}
