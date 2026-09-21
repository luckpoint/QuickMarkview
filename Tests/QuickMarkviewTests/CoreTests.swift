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
