#if canImport(WebKit)
import XCTest
import AppKit
import WebKit
@testable import QuickMarkview

@MainActor
final class WebKitSmokeTests: XCTestCase, WKNavigationDelegate, WKScriptMessageHandler {
    private var loaded: XCTestExpectation?
    private var rendered: XCTestExpectation?
    private var smokeRenderAfterLoad = true
    private var receivedTypes: [String] = []

    func testQClosesViewerOnlyOutsideTextInput() {
        XCTAssertTrue(AppDelegate.closesViewer(characters: "q", firstResponder: WKWebView()))
        XCTAssertFalse(AppDelegate.closesViewer(characters: "q", firstResponder: NSTextView()))
        XCTAssertFalse(AppDelegate.closesViewer(characters: "Q", firstResponder: WKWebView()))
        XCTAssertFalse(AppDelegate.closesViewer(characters: "w", firstResponder: nil))
    }

    func testQuitActionHidesOnlyInResidentMode() {
        XCTAssertEqual(AppDelegate.quitAction(resident: true), .hide)
        XCTAssertEqual(AppDelegate.quitAction(resident: false), .terminate)
    }

    func testCommandLTogglesSidebar() {
        let item = AppDelegate.mainMenu().items.flatMap { $0.submenu?.items ?? [] }.first { $0.keyEquivalent == "l" }
        XCTAssertEqual(item?.keyEquivalentModifierMask, .command)
        XCTAssertEqual(item?.action, #selector(ViewerViewController.toggleSidebar(_:)))
    }

    func testLaunchFrameFillsLeftTwoThirdsOfScreen() {
        let frame = AppDelegate.launchFrame(in: NSRect(x: 0, y: 25, width: 1800, height: 1100))
        XCTAssertEqual(frame, NSRect(x: 0, y: 25, width: 1195, height: 1100))
    }

    func testRequestCursorStartsOnEmptyRequestLine() {
        let prompt = PromptBuilder.build(context: MarkdownDocument(url: URL(fileURLWithPath: "/tmp/a.md"), text: "Hello"), range: SourceRange(startLine: 1, endLine: 1), request: "", selectedText: "Hello")
        let cursor = ViewerViewController.requestCursor(in: prompt)
        XCTAssertTrue((prompt as NSString).substring(to: cursor).hasSuffix("Request:\n"))
        XCTAssertTrue((prompt as NSString).substring(from: cursor).hasPrefix("\n\nSelected content:\n<selection>\nHello\n</selection>"))
        XCTAssertEqual(ViewerViewController.requestCursor(in: "no marker"), 0)
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
        rendered = expectation(description: "markdown table, highlighted fence, and mermaid render")
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

    func testCodeFilesHighlightEachLineAndContinueMultilineSpans() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        let loaded = expectation(description: "viewer loads for code highlighting")
        self.loaded = loaded
        smokeRenderAfterLoad = false
        view.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
        wait(for: [loaded], timeout: 5)
        view.evaluateJavaScript("window.quickMarkview.setDocument('let a = 1\\n/* x\\ny */', null, 1, 'swift');")
        let rendered = expectation(description: "code lines highlight")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            view.evaluateJavaScript("JSON.stringify({keyword: !!document.querySelector('.hljs-keyword'), lines: document.querySelectorAll('.line').length, third: document.querySelectorAll('.line')[2].dataset.sourceStart, comments: [...document.querySelectorAll('.line')].slice(1).every(line => !!line.querySelector('.hljs-comment'))})") { value, error in
                XCTAssertNil(error)
                let result = try? JSONSerialization.jsonObject(with: Data((value as? String ?? "{}").utf8)) as? [String: Any]
                XCTAssertEqual(result?["keyword"] as? Bool, true)
                XCTAssertEqual(result?["lines"] as? Int, 3)
                XCTAssertEqual(result?["third"] as? String, "3")
                XCTAssertEqual(result?["comments"] as? Bool, true)
                rendered.fulfill()
            }
        }
        wait(for: [rendered], timeout: 5)
    }

    func testExternalLinkClickDoesNotPostOpenLink() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "quickMarkview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        loaded = expectation(description: "viewer loads for external link")
        smokeRenderAfterLoad = false
        receivedTypes = []
        view.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
        wait(for: [loaded!], timeout: 5)
        view.evaluateJavaScript("window.quickMarkview.setDocument('[web](https://example.com)', null, 1);")
        let checked = expectation(description: "external link is not sent to local resolver")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            view.evaluateJavaScript("document.querySelector('a').click()")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertFalse(self.receivedTypes.contains("openLink"))
                checked.fulfill()
            }
        }
        wait(for: [checked], timeout: 3)
    }

    func testEditParagraphWithInlineMarkupAcrossLines() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "quickMarkview")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        loaded = expectation(description: "viewer loads for editing")
        smokeRenderAfterLoad = false
        view.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
        wait(for: [loaded!], timeout: 5)
        view.evaluateJavaScript("window.quickMarkview.setDocument('a **b**\\nc\\n\\nnext', null, 1);")
        let edited = expectation(description: "paragraph source is edited")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let script = """
            window.getSelection().collapse(document.querySelector('strong').firstChild, 0);
            document.dispatchEvent(new KeyboardEvent('keydown', {key: 'e'}));
            const input = document.querySelector('#quickmarkview-editor textarea'), original = input.value;
            input.value = 'x **y**\\nz\\n\\nw';
            input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter'}));
            window.quickMarkview.finishEdit(true, 2, null);
            const paragraphs = [...document.querySelectorAll('#content p')];
            JSON.stringify({original, strong: document.querySelector('strong').textContent, count: paragraphs.length, lines: paragraphs.map(p => p.dataset.sourceStart + '-' + p.dataset.sourceEnd)})
            """
            view.evaluateJavaScript(script) { value, error in
                XCTAssertNil(error)
                let result = try? JSONSerialization.jsonObject(with: Data((value as? String ?? "{}").utf8)) as? [String: Any]
                XCTAssertEqual(result?["original"] as? String, "a **b**\nc")
                XCTAssertEqual(result?["strong"] as? String, "y")
                XCTAssertEqual(result?["count"] as? Int, 3)
                XCTAssertEqual(result?["lines"] as? [String], ["1-2", "4-4", "6-6"])
                edited.fulfill()
            }
        }
        wait(for: [edited], timeout: 5)
    }

    func testCancelEditRestoresCaret() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "quickMarkview")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        loaded = expectation(description: "viewer loads for edit cancel")
        smokeRenderAfterLoad = false
        view.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
        wait(for: [loaded!], timeout: 5)
        view.evaluateJavaScript("window.quickMarkview.setDocument('a **bold** c', null, 1);")
        let cancelled = expectation(description: "caret returns after cancel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let script = """
            const text = document.querySelector('strong').firstChild;
            window.getSelection().collapse(text, 2);
            document.dispatchEvent(new KeyboardEvent('keydown', {key: 'e'}));
            document.querySelector('#quickmarkview-editor textarea').dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'}));
            const selection = window.getSelection();
            JSON.stringify({editor: !!document.getElementById('quickmarkview-editor'), collapsed: selection.isCollapsed, same: selection.focusNode === text, offset: selection.focusOffset})
            """
            view.evaluateJavaScript(script) { value, error in
                XCTAssertNil(error)
                let result = try? JSONSerialization.jsonObject(with: Data((value as? String ?? "{}").utf8)) as? [String: Any]
                XCTAssertEqual(result?["editor"] as? Bool, false)
                XCTAssertEqual(result?["collapsed"] as? Bool, true)
                XCTAssertEqual(result?["same"] as? Bool, true)
                XCTAssertEqual(result?["offset"] as? Int, 2)
                cancelled.fulfill()
            }
        }
        wait(for: [cancelled], timeout: 5)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("typeof markdownit + ':' + typeof mermaid") { [weak self, weak webView] value, error in
            XCTAssertNil(error)
            XCTAssertEqual(value as? String, "function:object")
            self?.loaded?.fulfill()
            guard self?.smokeRenderAfterLoad == true else { return }
            webView?.evaluateJavaScript("window.quickMarkview.setDocument('# Title\\n\\n| A | B |\\n| --- | --- |\\n| 1 | 2 |\\n\\n```swift\\nlet answer = 42\\n```\\n\\n```mermaid\\nflowchart LR\\nA[One] --> B[Two]\\n```', null, 7);")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                webView?.evaluateJavaScript("document.querySelector('h1')?.textContent + ':' + (!!document.querySelector('pre .hljs-keyword')) + ':' + (document.querySelector('.mermaid svg') ? 'svg' : 'missing') + ':' + getComputedStyle(document.querySelector('table')).borderCollapse + ':' + getComputedStyle(document.querySelector('td')).borderTopStyle") { value, error in
                    XCTAssertNil(error)
                    XCTAssertEqual(value as? String, "Title:true:svg:collapse:solid")
                    self?.rendered?.fulfill()
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let type = body["type"] as? String { receivedTypes.append(type) }
    }
}
#endif
