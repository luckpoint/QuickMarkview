#if canImport(WebKit)
import XCTest
import WebKit
import AppKit

@MainActor
final class VimKeyTests: XCTestCase, WKNavigationDelegate, WKScriptMessageHandler {
    private var loaded: XCTestExpectation?
    private var awaited: (type: String, expectation: XCTestExpectation)?
    private var lastSelection: [String: Any]?
    private var lastMessage: [String: Any]?
    private var zoomMessages: [[String: Any]] = []
    private var lastOpenLink: [String: Any]?
    private var lastImageSources: [String]?
    private var result: String?
    func testHTMLImageWithSmartQuotesUsesLocalImageResolutionAndPercentageWidth() {
        let view = loadViewer("<img src=“images/screenshot.png” alt=“iOSブラウザ比較アプリの画面” width=“30%”>\n")
        XCTAssertEqual(lastImageSources, ["images/screenshot.png"])
        XCTAssertEqual(js(view, "document.querySelector('img').getAttribute('alt')"), "iOSブラウザ比較アプリの画面")
        XCTAssertEqual(js(view, "document.querySelector('img').getAttribute('width')"), "30%")
        XCTAssertEqual(js(view, "document.querySelector('img').closest('[data-source-start]').dataset.sourceStart"), "1")
        let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII="
        _ = js(view, "window.quickMarkview.setImageSources(1, {'images/screenshot.png': '\(pixel)'}); ''")
        XCTAssertEqual(js(view, "document.querySelector('img').getAttribute('src')"), pixel)
        XCTAssertEqual(js(view, "String(Math.abs(document.querySelector('img').getBoundingClientRect().width / document.querySelector('img').parentElement.getBoundingClientRect().width - 0.3) < 0.01)"), "true")
    }

    func testHTMLImagesSupportInlineAndMultilineAttributesButLeaveCodeLiteral() {
        let view = loadViewer("""
        before <IMG SRC='images/a.png' alt="A &amp; B > C" width=120 height='80' /> after

        <img
          src="images/b.png"
          width="50%">

        `<img src="code.png">`

        ```html
        <img src="fence.png">
        ```

        ![Markdown](images/c.png)
        """)
        XCTAssertEqual(Set(lastImageSources ?? []), Set(["images/a.png", "images/b.png", "images/c.png"]))
        XCTAssertEqual(js(view, "String(document.querySelectorAll('#content img').length)"), "3")
        XCTAssertEqual(js(view, "document.querySelector('img').alt"), "A & B > C")
        XCTAssertEqual(js(view, "document.querySelector('img').getAttribute('height')"), "80")
        XCTAssertEqual(js(view, "document.querySelectorAll('#content img')[1].closest('[data-source-start]').dataset.sourceEnd"), "5")
        XCTAssertEqual(js(view, "document.querySelector('#content code').textContent"), "<img src=\"code.png\">")
    }

    func testHTMLImagesKeepHTMLDisabledAndFilterUnsafeAttributesAndSources() {
        let view = loadViewer("""
        <script>alert('test')</script>

        <img src="https://example.com/a.png" onerror="alert(1)" srcset="https://example.com/b.png 2x" style="position:fixed" width="bad">

        <img src="javascript&#58;alert(1)">

        <img src="//example.com/c.png">

        <iframe src="https://example.com"></iframe>
        """)
        XCTAssertEqual(js(view, "String(document.querySelectorAll('#content script, #content iframe, #content [onerror], #content [srcset], #content [style], #content img[width]').length)"), "0")
        XCTAssertEqual(js(view, "JSON.stringify([...document.querySelectorAll('#content img')].map(image => image.getAttribute('src')))"), "[\"#\",\"#\",\"#\"]")
    }

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

    func testRequestWithoutSelectionSelectsCursorLine() {
        let view = loadViewer("# One\n\nalpha beta\n\ngamma delta\n")
        press(view, "j", "l", "l")
        awaitMessage("requestInput") { press(view, " ", "a", "a") }
        XCTAssertEqual(js(view, "getSelection().toString()"), "alpha beta")
        XCTAssertEqual(lastSelection?["text"] as? String, "alpha beta")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 3)
        XCTAssertEqual(lastSelection?["lineEnd"] as? Int, 3)
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

    func testMouseDragSelectsBottomSequenceLabelWithoutJumpingScroll() throws {
        let view = loadViewer("placeholder\n")
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let messages = (1...12).map { "Alice->>Bob: Message \($0)" }.joined(separator: "\n")
        let markdown = "before\n\n```mermaid\nsequenceDiagram\nparticipant Alice\nparticipant Bob\n" + messages + "\n```\n\n" + String(repeating: "after\n\n", count: 30)
        let source = String(data: try JSONEncoder().encode(markdown), encoding: .utf8)!
        _ = js(view, "window.quickMarkview.setDocument(\(source), null, 2); ''")
        // Wait for Mermaid's SVG rather than requestAnimationFrame, which can
        // be throttled when XCTest's window is not the foreground application.
        var rendered = false
        for _ in 0..<20 {
            if js(view, "String(!!document.querySelector('.mermaid svg text.actor'))") == "true" { rendered = true; break }
            settleRender(view)
        }
        XCTAssertTrue(rendered)
        let position = try XCTUnwrap(js(view, """
        const label = [...document.querySelectorAll('.mermaid svg text.actor')]
            .filter(t => t.textContent === 'Bob')
            .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top).pop();
        label.scrollIntoView({block: 'center'});
        const rect = label.getBoundingClientRect();
        JSON.stringify({x: rect.x, y: rect.y + rect.height / 2, width: rect.width, scroll: scrollY})
        """))
        let rect = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(position.utf8)) as? [String: Double])
        let x = try XCTUnwrap(rect["x"]), y = try XCTUnwrap(rect["y"]), width = try XCTUnwrap(rect["width"])
        XCTAssertGreaterThan(try XCTUnwrap(rect["scroll"]), 0)

        func mouse(_ type: NSEvent.EventType, x: Double) throws {
            let location = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
            let delivered = expectation(description: "mouse event is processed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { delivered.fulfill() }
            wait(for: [delivered], timeout: 2)
        }

        try mouse(.leftMouseDown, x: x + 1)
        for step in 1...8 { try mouse(.leftMouseDragged, x: x + 1 + (width - 2) * Double(step) / 8) }
        try mouse(.leftMouseUp, x: x + width - 1)
        XCTAssertEqual(js(view, "getSelection().toString()"), "Bob")
        XCTAssertEqual(Double(js(view, "String(scrollY)") ?? ""), rect["scroll"])
        XCTAssertEqual(lastSelection?["text"] as? String, "Bob")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 3)
        XCTAssertEqual(lastSelection?["lineEnd"] as? Int, 19)
    }

    func testKeyboardDocumentMotionsKeepCursorVisible() {
        let view = loadViewer((1...80).map { "line \($0)" }.joined(separator: "\n\n"))
        press(view, "G")
        XCTAssertGreaterThan(Double(js(view, "String(scrollY)") ?? "") ?? 0, 0)
        XCTAssertEqual(js(view, "String(document.getElementById('cursor').getBoundingClientRect().bottom <= innerHeight)"), "true")
        press(view, "g", "g")
        XCTAssertEqual(js(view, "String(document.getElementById('cursor').getBoundingClientRect().top >= 0 && scrollY < innerHeight)"), "true")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "line 1")
    }

    func testUnboundKeysAreNotSwallowed() {
        let view = loadViewer("text\n")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', cancelable: true})))"), "true")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'j', cancelable: true})))"), "false")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'x', ctrlKey: true, cancelable: true})))"), "true")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'f', ctrlKey: true, cancelable: true})))"), "false")
    }

    func testTableKeysMoveBetweenRowsInTheSameColumn() {
        for (down, up) in [("j", "k"), ("ArrowDown", "ArrowUp")] {
            let view = loadViewer("before\n\n| Left | Right |\n| --- | --- |\n| alpha | one |\n| gamma | three |\n\nafter\n")
            _ = js(view, "getSelection().collapse(document.querySelectorAll('th')[1].firstChild, 0); ''")
            _ = js(view, "document.querySelectorAll('td')[1].innerHTML = 'one<br>two'; ''")
            press(view, down)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "one")
            press(view, down)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "three")
            press(view, down)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), down == "j" ? "after" : "three")
            _ = js(view, "getSelection().collapse(document.querySelectorAll('td')[3].firstChild, 0); ''")
            press(view, up)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "one")
            press(view, up)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "Right")
            press(view, up)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), up == "k" ? "before" : "Right")
        }
    }

    func testShiftTableKeysMoveWithinCellAndStopAtItsEdges() {
        for (down, up) in [("<S-J>", "<S-K>"), ("<S-ArrowDown>", "<S-ArrowUp>")] {
            let view = loadViewer("before\n\n| Left | Right |\n| --- | --- |\n| alpha beta | one two |\n| gamma | three |\n\nafter\n")
            // Give the rendered cell two deterministic display lines.
            _ = js(view, "document.querySelector('td').innerHTML = 'alpha<br>beta'; getSelection().collapse(document.querySelector('td').firstChild, 0); ''")
            press(view, down)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "beta")
            XCTAssertEqual(js(view, "getSelection().isCollapsed"), "1")
            press(view, down)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "beta")
            press(view, up, up)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "alpha")

            press(view, "v", down)
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "beta")
            XCTAssertEqual(js(view, "getSelection().isCollapsed"), "0")
            let selected = js(view, "getSelection().toString()")
            press(view, down)
            XCTAssertEqual(js(view, "getSelection().toString()"), selected)
            press(view, "Escape", "ArrowDown")
            XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "gamma")
        }
    }

    func testArrowsOutsideTableKeepNativeHandling() {
        let view = loadViewer("plain text\n")
        for key in ["ArrowUp", "ArrowDown"] {
            for shift in [false, true] {
                XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(key)', shiftKey: \(shift), cancelable: true})))"), "true")
            }
        }
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

    func testCodeLinewiseSelectionReportsOriginalSourceLine() {
        let view = loadViewer("placeholder\n")
        _ = js(view, "window.quickMarkview.setDocument('let a = 1\\nlet b = 2\\nlet c = 3', null, 2, 'swift'); ''")
        settleRender(view)
        _ = js(view, "getSelection().collapse(document.querySelector('.line .hljs-keyword').firstChild, 0); ''")
        awaitMessage("selection") { press(view, "j", "V") }
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 2)
        XCTAssertEqual(lastSelection?["lineEnd"] as? Int, 2)
    }

    func testFollowLocalLinksByControlKeyAndClickAndBackByControlCaret() {
        let view = loadViewer("# One\n\n[x](./b.md)\n")
        settleRender(view)
        XCTAssertEqual(js(view, "getSelection().collapse(document.querySelector('#content a').firstChild, 0); getSelection().focusNode.parentElement.closest('a').getAttribute('href')"), "./b.md")
        awaitMessage("openLink") { press(view, "<C-]>") }
        XCTAssertEqual(lastOpenLink?["href"] as? String, "./b.md")
        XCTAssertEqual(lastOpenLink?["fromLine"] as? Int, 3)

        awaitMessage("openLink") { _ = js(view, "getSelection().collapse(document.querySelector('#content a').firstChild, 0); document.querySelector('#content a').click(); ''") }
        XCTAssertEqual(lastOpenLink?["href"] as? String, "./b.md")

        awaitMessage("back") { press(view, "<C-^>") }
        XCTAssertEqual(lastMessage?["type"] as? String, "back")
        XCTAssertEqual(lastMessage?["fromLine"] as? Int, 1)
    }

    func testStashKeysPostSelectionRanges() {
        let view = loadViewer("# One\n\nalpha beta\n\ngamma delta\n")
        press(view, "j", "v", "l", "l")
        awaitMessage("stash") { press(view, " ", "a", "y") }
        XCTAssertEqual(lastSelection?["text"] as? String, "al")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 3)
        XCTAssertEqual(js(view, "getSelection().isCollapsed"), "1")

        press(view, "j")
        lastSelection = nil
        awaitMessage("stash") { press(view, " ", "a", "y") }
        XCTAssertEqual(lastSelection?["text"] as? String, "gamma delta")
        XCTAssertEqual(lastSelection?["lineStart"] as? Int, 5)

        awaitMessage("unstash") { press(view, " ", "a", "x") }
        XCTAssertEqual(lastMessage?["lineStart"] as? Int, 5)
        XCTAssertEqual(lastMessage?["lineEnd"] as? Int, 5)

        awaitMessage("clearStash") { press(view, " ", "a", "Escape") }
    }

    func testStashMarksSurviveRerender() {
        let view = loadViewer("# One\n\nalpha beta\n\ngamma delta\n")
        _ = js(view, "window.quickMarkview.setStashMarks([[3, 3]]); ''")
        XCTAssertEqual(js(view, "Array.from(document.querySelectorAll('.stashed')).map(n => n.textContent).join('|')"), "alpha beta")
        _ = js(view, "window.quickMarkview.setDocument('# One\\n\\nalpha beta\\n\\ngamma delta\\n', null, 2); ''")
        XCTAssertEqual(js(view, "document.querySelector('.stashed').dataset.sourceStart"), "3")
        _ = js(view, "window.quickMarkview.setStashMarks([]); ''")
        XCTAssertEqual(js(view, "String(document.querySelectorAll('.stashed').length)"), "0")
    }

    func testControlRightBracketOutsideLinkDoesNothing() {
        let view = loadViewer("plain text\n")
        lastOpenLink = nil
        lastMessage = nil
        _ = js(view, "document.dispatchEvent(new KeyboardEvent('keydown', {key: ']', ctrlKey: true, cancelable: true})); ''")
        XCTAssertNil(lastOpenLink)
    }

    func testControlArrowsRequestPreviousAndNextMarkdown() {
        let view = loadViewer("# One\n\ntext\n")
        awaitMessage("navigateFile") { press(view, "<C-ArrowRight>") }
        XCTAssertEqual(lastMessage?["direction"] as? String, "next")
        XCTAssertEqual(lastMessage?["fromLine"] as? Int, 1)
        awaitMessage("navigateFile") { press(view, "<C-ArrowLeft>") }
        XCTAssertEqual(lastMessage?["direction"] as? String, "previous")
        XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowRight', ctrlKey: true, shiftKey: true, cancelable: true})))"), "true")
    }

    func testReviewMarksUseSmallestBlocksAndStaySeparateFromStash() {
        let view = loadViewer("- first\n- changed\n\nlast")
        settleRender(view)
        _ = js(view, "window.quickMarkview.setStashMarks([[2, 2]]); window.quickMarkview.setReviewChanges([{oldStart:1,oldEnd:2,newStart:1,newEnd:2,oldText:'previous'}],1); ''")
        XCTAssertEqual(js(view, "String(document.querySelectorAll('#content .review-modified').length)"), "1")
        XCTAssertEqual(js(view, "document.querySelector('.review-modified').tagName"), "LI")
        XCTAssertEqual(js(view, "String(document.querySelectorAll('.stashed').length > 0 && !document.querySelector('ul').classList.contains('review-modified'))"), "true")
        XCTAssertEqual(js(view, "String(document.querySelectorAll('#review-marks button').length)"), "1")
        _ = js(view, "window.quickMarkview.setReviewChanges([],1); ''")
        XCTAssertEqual(js(view, "String(!document.querySelector('#content .review-modified') && !!document.querySelector('.stashed'))"), "true")
    }

    func testReviewNavigationAndGlobalAcknowledgeKeys() {
        let view = loadViewer("first\n\nmiddle\n\nlast")
        settleRender(view)
        _ = js(view, "window.quickMarkview.setReviewChanges([{oldStart:0,oldEnd:1,newStart:0,newEnd:1,oldText:'old first'},{oldStart:4,oldEnd:5,newStart:4,newEnd:5,oldText:'old last'}],1); ''")
        press(view, "]", "]")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "first")
        press(view, "]", "]")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "last")
        awaitMessage("navigateReviewFile") { press(view, "]", "]") }
        XCTAssertEqual(lastMessage?["direction"] as? Int, 1)
        press(view, "[", "[")
        XCTAssertEqual(js(view, "getSelection().focusNode.textContent"), "first")
        awaitMessage("navigateReviewFile") { press(view, "[", "[") }
        XCTAssertEqual(lastMessage?["direction"] as? Int, -1)
        awaitMessage("acknowledgeChanges") { press(view, " ", "c", "c") }
        XCTAssertEqual(lastMessage?["revision"] as? Int, 1)
    }

    func testDeletionAtEOFKeepsPreviousSourceOutOfCurrentSelection() {
        let view = loadViewer("survivor")
        settleRender(view)
        _ = js(view, "window.quickMarkview.setReviewChanges([{oldStart:1,oldEnd:3,newStart:1,newEnd:1,oldText:'removed\\n<script>literal</script>'}],1); document.querySelector('#review-marks button').click(); ''")
        XCTAssertEqual(js(view, "document.querySelector('#review-details textarea').value"), "removed\n<script>literal</script>")
        XCTAssertEqual(js(view, "document.getElementById('content').textContent.trim()"), "survivor")
        XCTAssertEqual(js(view, "String(document.querySelector('#review-details textarea').readOnly && !document.querySelector('#review-details [data-source-start]'))"), "true")
        XCTAssertEqual(js(view, "String(parseFloat(document.querySelector('#review-marks button').style.top) >= document.querySelector('#content p').getBoundingClientRect().bottom + scrollY)"), "true")
        _ = js(view, "window.quickMarkview.setReviewChanges([],1); ''")
        XCTAssertEqual(js(view, "String(document.querySelector('#review-details').hidden && !document.querySelector('#review-marks button'))"), "true")
    }

    func testFullDeletionAndStaleReviewRevision() {
        let view = loadViewer("before")
        settleRender(view)
        _ = js(view, "window.quickMarkview.setDocument('',null,2); window.quickMarkview.setReviewChanges([{oldStart:0,oldEnd:1,newStart:0,newEnd:0,oldText:'before'}],2); ''")
        settleRender(view)
        XCTAssertEqual(js(view, "String(document.querySelectorAll('#review-marks button').length)"), "1")
        awaitMessage("navigateReviewFile") {
            press(view, "]", "]", "]", "]")
        }
        _ = js(view, "window.quickMarkview.setReviewChanges([],1); ''")
        XCTAssertEqual(js(view, "String(document.querySelectorAll('#review-marks button').length)"), "1")
        _ = js(view, "document.querySelector('#review-marks button').click(); ''")
        XCTAssertEqual(js(view, "document.querySelector('#review-details textarea').value"), "before")
    }

    func testZoomBindingsConsumeKeysAndClearPrefix() {
        let view = loadViewer("alpha beta")
        for (key, action) in [("+", "in"), ("=", "reset"), ("-", "out")] {
            press(view, " ")
            awaitMessage("zoom") {
                XCTAssertEqual(js(view, "String(!document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(key)', shiftKey: true, repeat: true, cancelable: true})))"), "true")
            }
            XCTAssertEqual(lastMessage?["action"] as? String, action)
            XCTAssertEqual(lastMessage?["revision"] as? Int, 1)
            // 'a a' would open the request panel if the Space prefix survived.
            XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: 'a', cancelable: true})))"), "true")
        }
    }

    func testZoomExcludesModifiersCompositionAndInputs() {
        let view = loadViewer("alpha beta")
        zoomMessages = []
        for option in ["metaKey", "ctrlKey", "altKey", "isComposing"] {
            XCTAssertEqual(js(view, "String(document.dispatchEvent(new KeyboardEvent('keydown', {key: '+', \(option): true, cancelable: true})))"), "true")
        }
        for tag in ["input", "textarea", "div"] {
            XCTAssertEqual(js(view, """
                (() => {
                  const input = document.createElement('\(tag)');
                  if ('\(tag)' === 'div') input.contentEditable = 'true';
                  document.body.append(input); input.focus();
                  const allowed = ['+', '=', '-'].every(key => input.dispatchEvent(new KeyboardEvent('keydown', {key, bubbles: true, cancelable: true})));
                  input.remove(); return String(allowed);
                })()
                """), "true")
        }
        XCTAssertTrue(zoomMessages.isEmpty)
    }

    func testZoomRefreshPreservesVisualModesAndSelection() {
        let view = loadViewer("alpha beta\n\ngamma delta")
        for mode in ["v", "V"] {
            press(view, "g", "g", mode, "l")
            let selected = js(view, "getSelection().toString()")
            awaitMessage("zoom") { press(view, "+") }
            view.pageZoom = 2
            _ = js(view, "window.quickMarkview.refreshAfterZoom(); window.quickMarkview.refreshAfterZoom(); ''")
            settleRender(view)
            XCTAssertEqual(js(view, "getSelection().toString()"), selected)
            press(view, "j")
            XCTAssertNotEqual(js(view, "getSelection().toString()"), selected)
            press(view, "Escape")
        }
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
            let shift = key.hasPrefix("<S-")
            let name = control || shift ? String(key.dropFirst(3).dropLast()) : key
            _ = js(view, "document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(name)', ctrlKey: \(control), shiftKey: \(shift), cancelable: true})); ''")
        }
    }

    private func awaitMessage(_ type: String, during action: () -> Void) {
        let received = expectation(description: type)
        awaited = (type, received)
        action()
        wait(for: [received], timeout: 5)
        awaited = nil
    }

    private func settleRender(_ view: WKWebView) {
        let settled = expectation(description: "render settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
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
        lastMessage = body
        if type == "zoom" { zoomMessages.append(body) }
        if type == "selection" { lastSelection = body }
        if type == "openLink" { lastOpenLink = body }
        if type == "resolveImages" { lastImageSources = body["sources"] as? [String] }
        if type == awaited?.type { awaited?.expectation.fulfill() }
    }
}
#endif
