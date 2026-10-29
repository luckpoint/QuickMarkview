import XCTest
@testable import QuickMarkview

final class RecentFilesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "quickmarkview-recent-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name).standardizedFileURL
        try Data().write(to: url)
        return url
    }

    func testMostRecentFirstWithoutDuplicates() throws {
        let recent = RecentFiles(defaults: defaults)
        let a = try file("a.md"), b = try file("b.md")
        recent.add(a); recent.add(b); recent.add(a)
        XCTAssertEqual(recent.urls.map(\.path), [a.path, b.path])
    }

    func testSkipsMissingFiles() throws {
        let recent = RecentFiles(defaults: defaults)
        let a = try file("a.md"), b = try file("b.md")
        recent.add(a); recent.add(b)
        try FileManager.default.removeItem(at: b)
        XCTAssertEqual(recent.urls.map(\.path), [a.path])
    }

    func testKeepsAtMostLimit() throws {
        let recent = RecentFiles(defaults: defaults)
        let urls = try (0...RecentFiles.limit).map { try file("\($0).md") }
        urls.forEach(recent.add)
        XCTAssertEqual(recent.urls.count, RecentFiles.limit)
        XCTAssertEqual(recent.urls.first?.path, urls.last?.path)
        XCTAssertFalse(recent.urls.contains { $0.path == urls[0].path })
    }
}
