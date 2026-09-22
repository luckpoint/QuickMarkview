#if canImport(WebKit)
import XCTest
import WebKit

@MainActor
final class VimKeyTests: XCTestCase, WKNavigationDelegate, WKScriptMessageHandler {
    private var loaded: XCTestExpectation?
    private var awaited: (type: String, expectation: XCTestExpectation)?
    private var lastSelection: [String: Any]?
    private var result: String?

    func testMotionsVisualSelectionAndRequestSequence() {
        let view = loadViewer("# One\n\nalpha beta\n\ngamma delta\n")
        XCTAssertEqual(js(view, "String(!document.getElementById('cursor').hidden)"), "true")

        press(view, "j")
        XCTAssertEqual(js(view, "getSelection().focusNode.parentElement.dataset.sourceStart"), "3")

        press(view, "v", "l", "l", "l", "l", "l")
        XCTAssertEqual(js(view, "getSelection().toString()"), "alpha")
        XCTAssertEqual(lastSelection?["text"] as? String, "alpha")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 3)

        press(view, "Escape")
        XCTAssertEqual(js(view, "getSelection().isCollapsed"), "1")

        press(view, "G")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent + '@' + getSelection().focusOffset"), "gamma delta@11")
        press(view, "g", "g")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "One")

        awaitMessage("requestInput") { press(view, " ", "a", "a") }
    }

    func testLinewiseVisualSelectsWholeLinesAroundTheAnchor() {
        let view = loadViewer("# One\n\nalpha beta\n\ngamma delta\n")
        press(view, "j", "l", "l", "V")
        XCTAssertEqual(js(view, "getSelection().toString()"), "alpha beta")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 3)

        press(view, "j")
        XCTAssertEqual(js(view, "getSelection().toString().replace(/\\s+/g, ' ')"), "alpha beta gamma delta")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 3)
        XCTAssertEqual(lastSelection?["lineEnd"] as? Int, 5)

        press(view, "k", "k")
        XCTAssertEqual(js(view, "getSelection().toString().replace(/\\s+/g, ' ')"), "One alpha beta")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 1)
        XCTAssertEqual(lastSelection?["lineEnd"] as? Int, 3)

        press(view, "Escape")
        XCTAssertEqual(js(view, "getSelection().isCollapsed"), "1")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "One")
    }

    func testLinewiseVisualStopsAtSoftWraps() {
        let paragraph = Array(repeating: "word", count: 200).joined(separator: " ")
        let view = loadViewer(paragraph + "\n")
        press(view, "V")
        let one = js(view, "getSelection().toString()") ?? ""
        press(view, "j")
        let two = js(view, "getSelection().toString()") ?? ""
        XCTAssertTrue(one.hasPrefix("word"))
        XCTAssertGreaterThan(two.count, one.count)
        XCTAssertLessThan(two.count, paragraph.count)
    }

    func testControlFAndControlBMoveHalfAPage() {
        let view = loadViewer((1...200).map { "line \($0)" }.joined(separator: "\n\n") + "\n")
        press(view, "<C-f>")
        XCTAssertEqual(js(view, "String(scrollY)"), "300")
        XCTAssertGreaterThan(Int(js(view, "getSelection().focusNode.parentElement.dataset.sourceStart") ?? "") ?? 0, 1)
        XCTAssertEqual(js(view, "String(document.getElementById('cursor').getBoundingClientRect().top < innerHeight)"), "true")

        press(view, "<C-b>")
        XCTAssertEqual(js(view, "String(scrollY)"), "0")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "line 1")

        press(view, "v", "<C-f>")
        XCTAssertEqual(js(view, "getSelection().isCollapsed"), "0")
    }

    func testFocusRestoresSelectionClearedWhileAnotherViewHadFocus() {
        let view = loadViewer("alpha beta\n")
        press(view, "v", "l", "l")
        _ = js(view, "getSelection().removeAllRanges(); window.dispatchEvent(new FocusEvent('focus')); ''")
        XCTAssertEqual(js(view, "getSelection().toString()"), "al")
    }

    func testUnboundKeysAreNotSwallowed() {
        let view = loadViewer("text\n")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', cancelable: true})))"), "true")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'j', cancelable: true})))"), "false")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', ctrlKey: true, cancelable: true})))"), "true")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'f', ctrlKey: true, cancelable: true})))"), "false")
    }

    func testSidebarStartsHiddenAndToggles() {
        let view = loadViewer("# One\n\ntext\n")
        let width = "String(document.getElementById('toc').offsetWidth)"
        XCTAssertEqual(js(view, width), "0")
        _ = js(view, "window.quickMarkview.toggleSidebar(); ''")
        XCTAssertEqual(js(view, width), "210")
        XCTAssertEqual(js(view, "document.querySelector('#toc a').textContent"), "One")
        _ = js(view, "window.quickMarkview.toggleSidebar(); ''")
        XCTAssertEqual(js(view, width), "0")
    }

    private func loadViewer(_ markdown: String) -> WKWebView {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuickMarkview/Resources")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "quickMarkview")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        loaded = expectation(description: "viewer loads")
        view.loadFileURL(root.appendingPathComponent("viewer.html"), allowingReadAccessTo: root)
        wait(for: [loaded!], timeout: 5)
        let source = String(data: try! JSONEncoder().encode(markdown), encoding: .utf8)!
        _ = js(view, "window.quickMarkview.setDocument(\(source), null, 1); getSelection().collapse(document.querySelector('[data-source-start]').firstChild, 0); ''")
        return view
    }

    private func press(_ view: WKWebView, _ keys: String...) {
        for key in keys {
            let control = key.hasPrefix("<C-")
            let name = control ? String(key.dropFirst(3).dropLast()) : key
            _ = js(view, "document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(name)', ctrlKey: \(control), cancelable: true})); ''")
        }
    }

    private func awaitMessage(_ type: String, during action: () -> Void) {
        let received = expectation(description: type)
        awaited = (type, received)
        action()
        wait(for: [received], timeout: 5)
        awaited = nil
    }

    private func js(_ view: WKWebView, _ script: String) -> String? {
        let done = expectation(description: script)
        view.evaluateJavaScript(script) { [weak self] value, error in
            XCTAssertNil(error)
            self?.result = value.map { "\($0)" }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "selection" { lastSelection = body }
        if type == awaited?.type { awaited?.expectation.fulfill() }
    }
}
#endif
