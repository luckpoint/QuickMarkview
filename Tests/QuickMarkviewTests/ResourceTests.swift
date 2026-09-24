import XCTest

final class ResourceTests: XCTestCase {
    func testBundledRendererUsesOfficialOfflineAssetsAndSourceMaps() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let viewer = try String(contentsOf: sourceRoot.appendingPathComponent("viewer.html"), encoding: .utf8)
        let renderer = try String(contentsOf: sourceRoot.appendingPathComponent("markdown_renderer.js"), encoding: .utf8)
        XCTAssertTrue(viewer.contains("markdown-it.min.js")); XCTAssertTrue(viewer.contains("mermaid.min.js"))
        XCTAssertTrue(viewer.contains("highlight.min.js"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("github.min.css").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("github-dark.min.css").path))
        XCTAssertTrue(renderer.contains("token.map")); XCTAssertTrue(renderer.contains("data-source-start")); XCTAssertTrue(renderer.contains("mermaid.render"))
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: sourceRoot.appendingPathComponent("mermaid.min.js").path)[.size] as? Int ?? 0, 1_000_000)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: sourceRoot.appendingPathComponent("markdown-it.min.js").path)[.size] as? Int ?? 0, 50_000)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: sourceRoot.appendingPathComponent("highlight.min.js").path)[.size] as? Int ?? 0, 100_000)
    }
}
