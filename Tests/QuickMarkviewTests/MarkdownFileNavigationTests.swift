import XCTest
@testable import QuickMarkview

final class MarkdownFileNavigationTests: XCTestCase {
    private func fixture(_ paths: [String], check: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quickmarkview-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try check(root)
    }

    func testSameFolderUsesFilenameOrderAndOnlyMarkdown() throws {
        try fixture(["notes/a.md", "notes/b.txt", "notes/c.MD", "notes/d.markdown", "notes/e.mdown", "notes/f.mkd", "notes/.hidden.md"]) { root in
            let paths = ["a.md", "c.MD", "d.markdown", "e.mdown", "f.mkd"].map { root.appendingPathComponent("notes/" + $0) }
            for index in 0..<(paths.count - 1) {
                XCTAssertEqual(MarkdownFileNavigation.adjacent(to: paths[index], direction: .next)?.path, paths[index + 1].path)
                XCTAssertEqual(MarkdownFileNavigation.adjacent(to: paths[index + 1], direction: .previous)?.path, paths[index].path)
            }
            XCTAssertNil(MarkdownFileNavigation.adjacent(to: paths[0], direction: .previous))
            XCTAssertNil(MarkdownFileNavigation.adjacent(to: paths.last!, direction: .next))
        }
    }

    func testCrossFolderSkipsEmptyAndHiddenFoldersAndUsesTreeOrder() throws {
        try fixture([
            "01-previous/a-child/z.md", "01-previous/a.md", "01-previous/z.md",
            "02-empty/readme.txt", "03-current/only.md", "04-empty/readme.txt",
            "05-next/a-child/b-child/a.md", "05-next/a-child/z.md", "05-next/a.md",
            ".hidden/secret.md"
        ]) { root in
            let current = root.appendingPathComponent("03-current/only.md")
            XCTAssertEqual(MarkdownFileNavigation.adjacent(to: current, direction: .previous)?.path, root.appendingPathComponent("01-previous/z.md").path)
            XCTAssertEqual(MarkdownFileNavigation.adjacent(to: current, direction: .next)?.path, root.appendingPathComponent("05-next/a-child/b-child/a.md").path)
        }
    }

    func testPreviousFolderWithoutDirectMarkdownUsesLastDescendant() throws {
        try fixture(["01-previous/a-child/a.md", "01-previous/z-child/a.md", "01-previous/z-child/z.md", "02-current/a.md"]) { root in
            XCTAssertEqual(MarkdownFileNavigation.adjacent(to: root.appendingPathComponent("02-current/a.md"), direction: .previous)?.path,
                           root.appendingPathComponent("01-previous/z-child/z.md").path)
        }
    }

    func testSymlinkCycleDoesNotPreventFindingMarkdown() throws {
        try fixture(["01-current/a.md", "02-next/z.md"]) { root in
            let next = root.appendingPathComponent("02-next")
            try FileManager.default.createSymbolicLink(at: next.appendingPathComponent("a-loop"), withDestinationURL: next)
            XCTAssertEqual(MarkdownFileNavigation.adjacent(to: root.appendingPathComponent("01-current/a.md"), direction: .next)?.path,
                           next.appendingPathComponent("z.md").path)
        }
    }
}
