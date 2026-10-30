import XCTest
@testable import QuickMarkview

private final class HitCounter: @unchecked Sendable {
    let lock = NSLock(); var value = 0
    func increment() -> Int { lock.lock(); value += 1; let result = value; lock.unlock(); return result }
}

private final class MockRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [([String], Data?)] = []
    var result = CommandResult(status: 0, stdout: Data(), stderr: Data())
    func run(arguments: [String], stdin: Data?, completion: @escaping @Sendable (Result<CommandResult, Error>) -> Void) {
        lock.lock(); calls.append((arguments, stdin)); lock.unlock()
        completion(.success(result))
    }
    func snapshot() -> [([String], Data?)] { lock.lock(); defer { lock.unlock() }; return calls }
}

private final class PaneBox: @unchecked Sendable {
    let lock = NSLock(); var value: [WezTermPane] = []
    func set(_ panes: [WezTermPane]) { lock.lock(); value = panes; lock.unlock() }
    func get() -> [WezTermPane] { lock.lock(); defer { lock.unlock() }; return value }
}

final class CoreTests: XCTestCase {
    private let document = MarkdownDocument(url: URL(fileURLWithPath: "/tmp/notes.md"), text: "# One\nalpha\nbeta\n\n## Two\nsecond")

    func testDocumentKindDetectsMarkdownAndSourceLanguages() {
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.md")), .markdown)
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.MD")), .markdown)
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.markdown")), .markdown)
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.mdown")), .markdown)
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.mkd")), .markdown)
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.swift")), .code(language: "swift"))
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/Makefile")), .code(language: "makefile"))
        XCTAssertEqual(DocumentKind.detect(url: URL(fileURLWithPath: "/tmp/a.unknownext")), .code(language: "unknownext"))
    }

    func testLinkResolverFindsLocalFilesAndRejectsInvalidTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quickmarkview-links-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("notes")
        let parent = root.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = nested.appendingPathComponent("a.md")
        let sibling = nested.appendingPathComponent("b.md")
        let encoded = nested.appendingPathComponent("b c.md")
        let parentFile = parent.appendingPathComponent("b.md")
        for file in [current, sibling, encoded, parentFile] { try Data().write(to: file) }

        XCTAssertEqual(LinkResolver.resolve(href: "./b.md", relativeTo: current), sibling.standardizedFileURL)
        XCTAssertEqual(LinkResolver.resolve(href: "../x/b.md#sec?mode=1", relativeTo: current), parentFile.standardizedFileURL)
        XCTAssertEqual(LinkResolver.resolve(href: "b%20c.md?view=full#part", relativeTo: current), encoded.standardizedFileURL)
        XCTAssertEqual(LinkResolver.resolve(href: sibling.path, relativeTo: current), sibling.standardizedFileURL)
        XCTAssertNil(LinkResolver.resolve(href: "missing.md", relativeTo: current))
        XCTAssertNil(LinkResolver.resolve(href: ".", relativeTo: current))
        XCTAssertNil(LinkResolver.resolve(href: "https://example.com/a.md", relativeTo: current))
    }

    func testOpenRequestParsesQuickMarkviewURLs() {
        let url = URL(string: "quickmarkview://open?path=%2Ftmp%2F%E6%97%A5%E6%9C%AC%20note.md&line=42&pane=0")!
        XCTAssertEqual(OpenRequest.parse(url: url), OpenRequest(fileURL: URL(fileURLWithPath: "/tmp/日本 note.md"), line: 42, paneID: 0))
        XCTAssertEqual(OpenRequest.parse(url: URL(string: "quickmarkview://open?path=%2Ftmp%2Fa.md")!), OpenRequest(fileURL: URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertEqual(OpenRequest.parse(url: URL(string: "quickmarkview://open?path=%2Ftmp%2Fa.md&line=0&pane=no")!), OpenRequest(fileURL: URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertNil(OpenRequest.parse(url: URL(string: "quickmarkview://open?line=2")!))
        XCTAssertNil(OpenRequest.parse(url: URL(string: "quickmarkview://other?path=%2Ftmp%2Fa.md")!))
        XCTAssertNil(OpenRequest.parse(url: URL(string: "https://open?path=%2Ftmp%2Fa.md")!))
    }

    func testPromptMatchesNeovimNormalRequest() {
        let result = PromptBuilder.build(context: document, range: SourceRange(startLine: 2, endLine: 3), request: "Fix this")
        XCTAssertEqual(result, """
        Please handle the following request using the selected context.

        File: /tmp/notes.md
        Lines: 2-3

        Request:
        Fix this

        Selected content:
        <selection>
        alpha
        beta
        </selection>
        """)
    }

    func testPromptSupportsBtwOnlyAtCommandBoundary() {
        XCTAssertEqual(PromptBuilder.sideChatRequest("/btw explain this"), "explain this")
        XCTAssertEqual(PromptBuilder.sideChatRequest("/btw"), "")
        XCTAssertNil(PromptBuilder.sideChatRequest("/btwister"))
        let prompt = PromptBuilder.build(context: document, range: SourceRange(startLine: 5, endLine: 6), request: "/btw explain")
        XCTAssertTrue(prompt.hasPrefix("/btw explain\n\nContext:"))
    }

    func testSingleItemPromptMatchesSelectionPrompt() {
        let item = ContextItem(document: document, range: SourceRange(startLine: 2, endLine: 3), text: "")
        XCTAssertEqual(PromptBuilder.build(items: [item], request: "Fix this"),
                       PromptBuilder.build(context: document, range: SourceRange(startLine: 2, endLine: 3), request: "Fix this"))
    }

    func testMultiItemPromptTagsEachSelection() {
        let other = MarkdownDocument(url: URL(fileURLWithPath: "/tmp/api.md"), text: "x\ny")
        let items = [ContextItem(document: document, range: SourceRange(startLine: 2, endLine: 2), text: "alp"),
                     ContextItem(document: other, range: SourceRange(startLine: 1, endLine: 2), text: "")]
        XCTAssertEqual(PromptBuilder.build(items: items, request: "Compare"), """
        Please handle the following request using the selected context.

        Request:
        Compare

        Selected content:
        <selection file="/tmp/notes.md" lines="2-2">
        alp
        </selection>

        <selection file="/tmp/api.md" lines="1-2">
        x
        y
        </selection>
        """)
        XCTAssertTrue(PromptBuilder.build(items: items, request: "/btw why").hasPrefix("/btw why\n\nContext:\n<selection file=\"/tmp/notes.md\""))
    }

    func testRequestRoundTripsThroughPrompts() {
        let one = [ContextItem(document: document, range: SourceRange(startLine: 2, endLine: 3), text: "")]
        let two = one + [ContextItem(document: document, range: SourceRange(startLine: 5, endLine: 5), text: "")]
        for items in [one, two] {
            for request in ["", "Fix\nthis", "/btw explain"] {
                XCTAssertEqual(PromptBuilder.request(in: PromptBuilder.build(items: items, request: request)), request)
            }
        }
        XCTAssertNil(PromptBuilder.request(in: "free text"))
    }

    func testBasketIgnoresDuplicatesAndRemovesOverlaps() {
        var basket = ContextBasket()
        let other = MarkdownDocument(url: URL(fileURLWithPath: "/tmp/api.md"), text: "x\ny")
        XCTAssertTrue(basket.add(ContextItem(document: document, range: SourceRange(startLine: 2, endLine: 3), text: ""), fileLines: document.lines))
        XCTAssertFalse(basket.add(ContextItem(document: document, range: SourceRange(startLine: 2, endLine: 3), text: "alpha"), fileLines: document.lines))
        basket.add(ContextItem(document: document, range: SourceRange(startLine: 5, endLine: 6), text: ""), fileLines: document.lines)
        basket.add(ContextItem(document: other, range: SourceRange(startLine: 1, endLine: 2), text: ""), fileLines: other.lines)
        XCTAssertEqual(basket.remove(url: document.url, overlapping: SourceRange(startLine: 3, endLine: 3)), 1)
        XCTAssertEqual(basket.ranges(in: document.url), [SourceRange(startLine: 5, endLine: 6)])
        XCTAssertEqual(basket.ranges(in: other.url), [SourceRange(startLine: 1, endLine: 2)])
        basket.clear()
        XCTAssertTrue(basket.items.isEmpty)
    }

    private func basket(_ lines: [String], _ ranges: [(Int, Int)]) -> ContextBasket {
        let file = MarkdownDocument(url: document.url, text: lines.joined(separator: "\n"))
        var basket = ContextBasket()
        for (start, end) in ranges { basket.add(ContextItem(document: file, range: SourceRange(startLine: start, endLine: end), text: ""), fileLines: file.lines) }
        return basket
    }

    func testReanchorFollowsInsertionsAndDuplicates() {
        var shifted = basket(["a", "b", "c"], [(2, 3)])
        XCTAssertEqual(shifted.reanchor(url: document.url, lines: ["x", "y", "z", "a", "b", "c"]), 0)
        XCTAssertEqual(shifted.ranges(in: document.url), [SourceRange(startLine: 5, endLine: 6)])

        var duplicate = basket(["TODO", "a", "TODO"], [(3, 3)])
        duplicate.reanchor(url: document.url, lines: ["new", "TODO", "a", "TODO"])
        XCTAssertEqual(duplicate.ranges(in: document.url), [SourceRange(startLine: 4, endLine: 4)])
    }

    func testReanchorFindsMovedBlockOnlyWhenUnique() {
        var moved = basket(["a", "b", "c", "d"], [(1, 2)])
        moved.reanchor(url: document.url, lines: ["c", "d", "a", "b"])
        XCTAssertEqual(moved.ranges(in: document.url), [SourceRange(startLine: 3, endLine: 4)])

        let item = ContextItem(url: document.url, range: SourceRange(startLine: 1, endLine: 2), text: "", sourceLines: ["a", "b"])
        XCTAssertEqual(item.reanchored(map: [nil, nil], lines: ["x", "a", "b"])?.range, SourceRange(startLine: 2, endLine: 3))
        XCTAssertNil(item.reanchored(map: [nil, nil], lines: ["a", "b", "x", "a", "b"]))
        XCTAssertNil(item.reanchored(map: [nil, nil], lines: ["a"]))
    }

    func testReanchorDropsEditedOrSplitRangesOnly() {
        var edited = basket(["a", "b", "c", "d"], [(2, 3), (4, 4)])
        XCTAssertEqual(edited.reanchor(url: document.url, lines: ["a", "B", "c", "d"]), 1)
        XCTAssertEqual(edited.ranges(in: document.url), [SourceRange(startLine: 4, endLine: 4)])

        var split = basket(["a", "b", "c"], [(1, 2)])
        XCTAssertEqual(split.reanchor(url: document.url, lines: ["a", "new", "b", "c"]), 1)

        var other = basket(["a"], [(1, 1)])
        let api = MarkdownDocument(url: URL(fileURLWithPath: "/tmp/api.md"), text: "x")
        other.add(ContextItem(document: api, range: SourceRange(startLine: 1, endLine: 1), text: ""), fileLines: api.lines)
        XCTAssertEqual(other.reanchor(url: api.url, lines: ["changed"]), 1)
        XCTAssertEqual(other.ranges(in: document.url), [SourceRange(startLine: 1, endLine: 1)])
    }

    func testPaneResolverIsSameTabAndLeftToRight() throws {
        let panes = [
            WezTermPane(paneID: 20, tabID: 1, leftCol: 80, topRow: 0, title: "agent-right"),
            WezTermPane(paneID: 0, tabID: 1, leftCol: 0, topRow: 0, title: "nvim"),
            WezTermPane(paneID: 21, tabID: 1, leftCol: 40, topRow: 0, title: "agent-left"),
            WezTermPane(paneID: 30, tabID: 2, leftCol: 0, topRow: 0, title: "other-tab")
        ]
        let result = try PaneTargetResolver.resolve(panes: panes, currentPaneID: 0)
        XCTAssertEqual(result.map(\.paneID), [21, 20])
        XCTAssertEqual(result.map(\.role), ["Pane2", "Pane1"])
        XCTAssertEqual(try PaneTargetResolver.resolve(panes: panes, currentPaneID: 0, explicitTargetID: 20).map(\.paneID), [20])
    }

    func testPaneResolverRejectsNonLeftmostAndTooMany() {
        let panes = [WezTermPane(paneID: 1, tabID: 1, leftCol: 10, topRow: 0), WezTermPane(paneID: 2, tabID: 1, leftCol: 0, topRow: 0)]
        XCTAssertThrowsError(try PaneTargetResolver.resolve(panes: panes, currentPaneID: 1)) { XCTAssertEqual($0 as? PaneResolutionError, .sourceMustBeLeftmost) }
        let many = [WezTermPane(paneID: 0, tabID: 1, leftCol: 0, topRow: 0)] + (1...3).map { WezTermPane(paneID: $0, tabID: 1, leftCol: $0 * 10, topRow: 0) }
        XCTAssertThrowsError(try PaneTargetResolver.resolve(panes: many, currentPaneID: 0)) { XCTAssertEqual($0 as? PaneResolutionError, .tooManyTargets(3)) }
    }

    func testLineTextAndClampedRange() {
        XCTAssertEqual(document.text(in: SourceRange(startLine: 2, endLine: 99)), "alpha\nbeta\n\n## Two\nsecond")
        XCTAssertEqual(document.text(in: SourceRange(startLine: 0, endLine: 1)), "# One")
    }

    func testPaneJSONDecode() throws {
        let json = "[{\"pane_id\":0,\"tab_id\":2,\"left_col\":0,\"top_row\":0,\"title\":\"nvim\"}]".data(using: .utf8)!
        XCTAssertEqual(try PaneJSON.decode(json).first?.paneID, 0)
    }

    func testLaunchOptionsAcceptWezTermPaneZero() throws {
        let options = try LaunchOptions(arguments: ["--line", "3", "--pane", "0", "--target-pane=2", "/tmp/note.md"])
        XCTAssertEqual(options.line, 3); XCTAssertEqual(options.originPaneID, 0); XCTAssertEqual(options.targetPaneID, 2)
    }

    func testLaunchOptionsAcceptLegacyResidentFlag() throws {
        XCTAssertEqual(try LaunchOptions(arguments: ["--resident"]), try LaunchOptions(arguments: []))
    }

    func testLaunchRequestPreservesPathsAndPaneContext() throws {
        let options = try LaunchOptions(arguments: ["--line", "42", "--pane", "0", "--target-pane", "12", "/tmp/日本 & #?% note.md"])
        let request = try XCTUnwrap(options.openRequest)
        XCTAssertEqual(request.fileURL.path, "/tmp/日本 & #?% note.md")
        XCTAssertEqual(request.line, 42)
        XCTAssertEqual(request.paneID, 0)
        XCTAssertEqual(request.targetPaneID, 12)
        XCTAssertEqual(OpenRequest.parse(url: request.url), request)
        XCTAssertNil(try LaunchOptions(arguments: []).openRequest)
    }

    func testWatcherObservesInPlaceAndAtomicSaves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quickmarkview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: file)
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let counter = HitCounter()
        let watcher = FileWatcher(fileURL: file, debounceInterval: 0.04) {
            let count = counter.increment()
            if count == 1 { first.signal() } else { second.signal() }
        }
        watcher.start(); defer { watcher.stop() }
        usleep(120_000)
        try Data("two".utf8).write(to: file)
        XCTAssertEqual(first.wait(timeout: .now() + 2), .success)
        let replacement = directory.appendingPathComponent("note.tmp")
        try Data("three".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        XCTAssertEqual(second.wait(timeout: .now() + 2), .success)
    }

    func testWezTermServiceUsesTwoStageSendWithInjectedRunner() {
        let runner = MockRunner()
        let service = WezTermService(runner: runner)
        let done = DispatchSemaphore(value: 0)
        service.send(text: "hello", to: 42, submitDelay: 0) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        let calls = runner.snapshot()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].0.contains("send-text")); XCTAssertFalse(calls[0].0.contains("--no-paste"))
        XCTAssertTrue(calls[1].0.contains("--no-paste")); XCTAssertEqual(String(data: calls[1].1 ?? Data(), encoding: .utf8), "\r")
    }

    func testBtwCommandIsTypedAndBodyIsPasted() {
        let runner = MockRunner()
        let done = DispatchSemaphore(value: 0)
        WezTermService(runner: runner).send(text: "/btw explain\n\nContext:", to: 7, submitDelay: 0) { _ in done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        let calls = runner.snapshot()
        XCTAssertEqual(calls.map { $0.0.contains("--no-paste") }, [true, false, true])
        XCTAssertEqual(calls.map { String(data: $0.1 ?? Data(), encoding: .utf8) }, ["/btw ", "explain\n\nContext:", "\r"])
        XCTAssertEqual(WezTermService.inputs(for: "/btw"), [PaneInput(text: "/btw ", paste: false), PaneInput(text: "\r", paste: false)])
        XCTAssertEqual(WezTermService.inputs(for: "/btwister").map(\.paste), [true, false])
    }

    func testWezTermServiceParsesListWithInjectedRunner() {
        let runner = MockRunner()
        runner.result = CommandResult(status: 0, stdout: Data("[{\"pane_id\":0,\"tab_id\":3,\"left_col\":0,\"top_row\":0,\"title\":\"nvim\"}]".utf8), stderr: Data())
        let service = WezTermService(runner: runner)
        let done = DispatchSemaphore(value: 0); let box = PaneBox()
        service.listPanes { result in box.set((try? result.get()) ?? []); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(box.get().first?.paneID, 0)
    }
}
