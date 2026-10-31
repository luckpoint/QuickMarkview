import XCTest
@testable import QuickMarkview

final class ChangeReviewTests: XCTestCase {
    func testInsertionDoesNotMarkShiftedLinesChanged() {
        let changes = ReviewChange.compare("a\nb\nc\n", "x\na\nb\nc\n")
        XCTAssertEqual(changes, [ReviewChange(oldStart: 0, oldEnd: 0, newStart: 0, newEnd: 1, oldText: "")])
    }

    func testDeletionBoundariesAtStartMiddleEndAndEntireFile() {
        let old = "a\nb\nc\n"
        XCTAssertEqual(ReviewChange.compare(old, "b\nc\n"), [ReviewChange(oldStart: 0, oldEnd: 1, newStart: 0, newEnd: 0, oldText: "a")])
        XCTAssertEqual(ReviewChange.compare(old, "a\nc\n"), [ReviewChange(oldStart: 1, oldEnd: 2, newStart: 1, newEnd: 1, oldText: "b")])
        XCTAssertEqual(ReviewChange.compare(old, "a\nb\n"), [ReviewChange(oldStart: 2, oldEnd: 3, newStart: 2, newEnd: 2, oldText: "c")])
        XCTAssertEqual(ReviewChange.compare(old, ""), [ReviewChange(oldStart: 0, oldEnd: 3, newStart: 0, newEnd: 0, oldText: "a\nb\nc")])
    }

    func testReplacementAndSeparatedChanges() {
        let changes = ReviewChange.compare("a\nb\nc\nd", "A\nb\nc\nD")
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.map(\.kind), ["modified", "modified"])
        XCTAssertEqual(changes.map(\.oldText), ["a", "d"])
        XCTAssertEqual(changes.map(\.newStart), [0, 3])
        XCTAssertTrue(ReviewChange.compare("a\r\nb\r\n", "a\nb\n").isEmpty)
    }

    func testRepeatedLinesPreserveDifferenceCoordinates() {
        let old = "same\nx\nsame\ny\nsame"
        let new = "same\nsame\ny\nsame\nz"
        let changes = ReviewChange.compare(old, new)
        var lines = ReviewChange.lines(old)
        let replacement = ReviewChange.lines(new)
        for change in changes.reversed() {
            lines.replaceSubrange(change.oldStart..<change.oldEnd, with: replacement[change.newStart..<change.newEnd])
        }
        XCTAssertEqual(lines, replacement)
    }

    func testSessionAccumulatesSavesAndAcknowledgesEveryVisitedFile() throws {
        var disk = ["/a.md": "a", "/b.md": "b"]
        let session = ChangeReviewSession(read: { disk[$0] })
        for (path, text) in disk { session.register(url: URL(fileURLWithPath: path), text: text) }
        disk["/a.md"] = "a\none"
        _ = try session.snapshot()
        disk["/a.md"] = "a\none\ntwo"
        disk["/b.md"] = nil
        session.register(url: URL(fileURLWithPath: "/a.md"), text: disk["/a.md"]!)
        let snapshot = try session.snapshot()
        XCTAssertEqual(snapshot["/a.md"]?.baseline, "a")
        XCTAssertEqual(snapshot["/a.md"]?.changes.first?.newEnd, 3)
        XCTAssertEqual(snapshot["/b.md"]?.changes.first?.kind, "deleted")
        XCTAssertEqual(try session.nextFile(after: "/a.md", direction: 1)?.path, "/b.md")
        XCTAssertEqual(try session.nextFile(after: "/b.md", direction: -1)?.path, "/a.md")
        XCTAssertNil(try session.nextFile(after: "/b.md", direction: 1))
        try session.acknowledge()
        XCTAssertTrue(try session.snapshot().values.allSatisfy { $0.changes.isEmpty })
        XCTAssertEqual(session.files["/a.md"]?.baseline, "a\none\ntwo")
        disk["/b.md"] = "recreated"
        XCTAssertEqual(try session.snapshot()["/b.md"]?.changes.first?.kind, "added")
        disk["/a.md"] = "a\none\ntwo"
        XCTAssertTrue(try session.snapshot()["/a.md"]!.changes.isEmpty)
    }

    func testRevertRemovesMarksAndFailedAcknowledgementKeepsAllBaselines() throws {
        enum Failure: Error { case unreadable }
        var disk = ["/a.md": "a", "/b.md": "b"]
        var fail = false
        let session = ChangeReviewSession(read: { path in
            if fail && path == "/b.md" { throw Failure.unreadable }
            return disk[path]
        })
        for (path, text) in disk { session.register(url: URL(fileURLWithPath: path), text: text) }
        disk["/a.md"] = "changed"
        XCTAssertFalse(try session.snapshot()["/a.md"]!.changes.isEmpty)
        disk["/a.md"] = "a"
        XCTAssertTrue(try session.snapshot()["/a.md"]!.changes.isEmpty)
        disk["/a.md"] = "changed"
        fail = true
        XCTAssertThrowsError(try session.acknowledge())
        XCTAssertEqual(session.files["/a.md"]?.baseline, "a")
        XCTAssertEqual(session.files["/b.md"]?.baseline, "b")
    }
}
