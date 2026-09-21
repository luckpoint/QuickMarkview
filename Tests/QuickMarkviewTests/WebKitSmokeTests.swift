#if canImport(WebKit)
import XCTest
import AppKit
import WebKit
@testable import QuickMarkview

@MainActor
final class WebKitSmokeTests: XCTestCase, WKNavigationDelegate, WKScriptMessageHandler {
    private var loaded: XCTestExpectation?
    private var rendered: XCTestExpectation?

    func testQClosesViewerOnlyOutsideTextInput() {
        XCTAssertTrue(AppDelegate.closesViewer(characters: "q", firstResponder: WKWebView()))
        XCTAssertFalse(AppDelegate.closesViewer(characters: "q", firstResponder: NSTextView()))
        XCTAssertFalse(AppDelegate.closesViewer(characters: "Q", firstResponder: WKWebView()))
        XCTAssertFalse(AppDelegate.closesViewer(characters: "w", firstResponder: nil))
    }

    func testViewerLoadsBundledMarkdownAndMermaidLibraries() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "quickMarkview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        let loaded = expectation(description: "viewer loads")
        self.loaded = loaded
        rendered = expectation(description: "markdown and mermaid render")
        view.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
        wait(for: [loaded, rendered!], timeout: 8)
        let result = view.value(forKey: "URL") as? URL
        XCTAssertEqual(result?.lastPathComponent, "viewer.html")
    }

    func testViewerLayoutFillsWindowBelowToolbarWithRequestPanelHidden() {
        let controller = ViewerViewController(options: try! LaunchOptions(arguments: []))
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        let webViews = descendants(of: controller.view).compactMap { $0 as? WKWebView }
        XCTAssertEqual(webViews.count, 1)
        XCTAssertEqual(webViews[0].frame.width, 1200)
        XCTAssertEqual(webViews[0].frame.height, 820 - 46)
        XCTAssertTrue(controller.requestPanel.isHidden)
        XCTAssertTrue(descendants(of: controller.view).compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("typeof markdownit + ':' + typeof mermaid") { [weak self, weak webView] value, error in
            XCTAssertNil(error)
            XCTAssertEqual(value as? String, "function:object")
            self?.loaded?.fulfill()
            webView?.evaluateJavaScript("window.quickMarkview.setDocument('# Title\\n\\n```mermaid\\nflowchart LR\\nA[One] --> B[Two]\\n```', null, 7);")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                webView?.evaluateJavaScript("document.querySelector('h1')?.textContent + ':' + (document.querySelector('.mermaid svg') ? 'svg' : 'missing')") { value, error in
                    XCTAssertNil(error)
                    XCTAssertEqual(value as? String, "Title:svg")
                    self?.rendered?.fulfill()
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // The bridge message is expected; assertions are made through JS.
    }
}
#endif
