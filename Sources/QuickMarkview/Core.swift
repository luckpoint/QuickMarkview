import Foundation

public enum DocumentKind: Equatable, Sendable {
    case markdown
    case code(language: String)

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func detect(url: URL) -> DocumentKind {
        let fileName = url.lastPathComponent
        let extensionOrName = url.pathExtension.isEmpty ? fileName : url.pathExtension
        let language = extensionOrName.lowercased()
        return markdownExtensions.contains(language) ? .markdown : .code(language: language)
    }
}

public enum ProjectRoot {
    private static let markers = [".git", ".hg", ".jj"]

    /// Finds the nearest repository directory, starting with `directory`.
    public static func find(from directory: URL) -> URL? {
        let fileManager = FileManager.default
        var current = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current.deleteLastPathComponent()
        }
        while true {
            if markers.contains(where: { fileManager.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }
}

public enum FuzzyMatcher {
    private static let boundaries: Set<Character> = ["/", "_", "-", "."]
    public static func score(query: String, candidate: String) -> Int? {
        match(query: query, candidate: candidate)?.score
    }

    /// Scores a case-insensitive subsequence match and returns candidate
    /// character offsets suitable for highlighting.
    public static func match(query: String, candidate: String) -> (score: Int, positions: [Int])? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return (0, []) }

        let characters = Array(candidate)
        let fileNameStart = (candidate.lastIndex(of: "/").map { candidate.distance(from: candidate.startIndex, to: $0) + 1 }) ?? 0
        var totalScore = 0
        var allPositions = Set<Int>()

        for token in tokens {
            let needle = Array(token)
            guard !needle.isEmpty else { continue }
            var cursor = 0
            var priorPosition: Int?
            var tokenScore = 0
            var tokenPositions: [Int] = []

            for wanted in needle {
                guard let position = characters.indices.dropFirst(cursor).first(where: { characters[$0].lowercased() == wanted.lowercased() }) else {
                    return nil
                }
                tokenPositions.append(position)
                tokenScore += 1
                if let priorPosition, position == priorPosition + 1 { tokenScore += 5 }
                if position == 0 || boundaries.contains(characters[position - 1]) { tokenScore += 8 }
                if position >= fileNameStart { tokenScore += 3 }
                if priorPosition == nil { tokenScore -= min(position, 10) }
                priorPosition = position
                cursor = position + 1
            }
            totalScore += tokenScore
            allPositions.formUnion(tokenPositions)
        }
        return (totalScore, allPositions.sorted())
    }
}

public enum LinkResolver {
    public static func resolve(href: String, relativeTo fileURL: URL) -> URL? {
        let pathAndQuery = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let path = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !path.isEmpty else { return nil }
        guard let decoded = String(path).removingPercentEncoding else { return nil }

        let target: URL
        if let url = URL(string: decoded), let scheme = url.scheme?.lowercased() {
            guard scheme == "file", let fileURL = URL(string: decoded), fileURL.isFileURL else { return nil }
            target = fileURL
        } else if decoded.hasPrefix("/") {
            target = URL(fileURLWithPath: decoded)
        } else {
            target = URL(fileURLWithPath: decoded, relativeTo: fileURL.deletingLastPathComponent())
        }

        let standardized = target.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return standardized
    }
}

public struct OpenRequest: Equatable, Sendable {
    public let fileURL: URL
    public let line: Int?
    public let paneID: Int?

    public init(fileURL: URL, line: Int? = nil, paneID: Int? = nil) {
        self.fileURL = fileURL.standardizedFileURL
        self.line = line.map { max(1, $0) }
        self.paneID = paneID
    }

    public static func parse(url: URL) -> OpenRequest? {
        guard url.scheme?.lowercased() == "quickmarkview", url.host?.lowercased() == "open" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else { return nil }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let line = components.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let paneID = components.queryItems?.first(where: { $0.name == "pane" })?.value.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        return OpenRequest(fileURL: fileURL, line: line, paneID: paneID)
    }
}

/// A range in the original Markdown file. Lines are one-based and inclusive.
public struct SourceRange: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = max(1, min(startLine, endLine))
        self.endLine = max(self.startLine, endLine)
    }
}

public struct MarkdownDocument: Equatable, Sendable {
    public let url: URL
    public let text: String
    public let lines: [String]
    public let revision: UInt64

    public init(url: URL, text: String, revision: UInt64 = 0) {
        self.url = url
        self.text = text
        // split omitting an artificial last line makes line ranges intuitive for
        // files with a trailing newline, while an empty file still has one line.
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .ifEmpty([""])
        self.revision = revision
    }

    public func text(in range: SourceRange) -> String {
        lines(in: range).joined(separator: "\n")
    }

    public func lines(in range: SourceRange) -> [String] {
        let first = max(1, min(range.startLine, lines.count)) - 1
        let last = max(first, min(range.endLine, lines.count) - 1)
        return Array(lines[first...last])
    }
}

private extension Array {
    func ifEmpty(_ value: [Element]) -> [Element] { isEmpty ? value : self }
}

public struct RenderedSelection: Equatable, Sendable {
    public let text: String
    public let sourceRange: SourceRange
    public let revision: UInt64

    public init(text: String, sourceRange: SourceRange, revision: UInt64) {
        self.text = text
        self.sourceRange = sourceRange
        self.revision = revision
    }
}

/// A stashed selection. `sourceLines` is the Markdown source of `range` when
/// it was stashed; a later file version keeps the item only if those lines survive.
public struct ContextItem: Equatable, Sendable {
    public let url: URL
    public var range: SourceRange
    public let text: String
    public let sourceLines: [String]

    public init(url: URL, range: SourceRange, text: String, sourceLines: [String]) {
        self.url = url
        self.range = range
        self.text = text
        self.sourceLines = sourceLines
    }

    public init(document: MarkdownDocument, range: SourceRange, text: String) {
        self.init(url: document.url, range: range, text: text, sourceLines: document.lines(in: range))
    }

    public var content: String { text.isEmpty ? sourceLines.joined(separator: "\n") : text }

    /// Follows the range through a line diff; falls back to the only exact
    /// occurrence of `sourceLines`, so a moved block is still found.
    func reanchored(map: [Int?], lines: [String]) -> ContextItem? {
        let first = range.startLine - 1, last = range.endLine - 1
        var moved = self
        if last < map.count, (first...last).allSatisfy({ map[$0] != nil }), let start = map[first], let end = map[last], end - start == last - first {
            moved.range = SourceRange(startLine: start + 1, endLine: end + 1)
            return moved
        }
        let count = sourceLines.count
        guard lines.count >= count else { return nil }
        let hits = (0...(lines.count - count)).filter { Array(lines[$0..<($0 + count)]) == sourceLines }
        guard hits.count == 1 else { return nil }
        moved.range = SourceRange(startLine: hits[0] + 1, endLine: hits[0] + count)
        return moved
    }
}

public struct ContextBasket: Equatable, Sendable {
    public private(set) var items: [ContextItem] = []
    private var snapshots: [URL: [String]] = [:]

    public init() {}

    /// `fileLines` must be the file version `item` was taken from.
    @discardableResult
    public mutating func add(_ item: ContextItem, fileLines: [String]) -> Bool {
        guard !items.contains(where: { $0.url == item.url && $0.range == item.range }) else { return false }
        items.append(item)
        snapshots[item.url] = fileLines
        return true
    }

    @discardableResult
    public mutating func remove(url: URL, overlapping range: SourceRange) -> Int {
        let before = items.count
        items.removeAll { $0.url == url && $0.range.startLine <= range.endLine && $0.range.endLine >= range.startLine }
        return before - items.count
    }

    public mutating func clear() {
        items = []
        snapshots = [:]
    }

    /// Moves `url`'s items to the new file version and returns how many were dropped.
    @discardableResult
    public mutating func reanchor(url: URL, lines: [String]) -> Int {
        guard let old = snapshots[url], old != lines else { return 0 }
        let map = Self.lineMap(from: old, to: lines)
        let before = items.count
        items = items.compactMap { $0.url == url ? $0.reanchored(map: map, lines: lines) : $0 }
        snapshots[url] = lines
        return before - items.count
    }

    public func ranges(in url: URL) -> [SourceRange] {
        items.filter { $0.url == url }.map(\.range)
    }

    static func lineMap(from old: [String], to new: [String]) -> [Int?] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map = [Int?](repeating: nil, count: old.count), next = 0
        for index in old.indices where !removed.contains(index) {
            while inserted.contains(next) { next += 1 }
            map[index] = next
            next += 1
        }
        return map
    }
}

public enum PromptBuilder {
    public static func build(context: MarkdownDocument, range: SourceRange, request: String, selectedText: String? = nil) -> String {
        let content = selectedText?.isEmpty == false ? selectedText! : context.text(in: range)
        return build(url: context.url, range: range, request: request, content: content)
    }

    public static func build(items: [ContextItem], request: String) -> String {
        if items.count == 1, let item = items.first {
            return build(url: item.url, range: item.range, request: request, content: item.content)
        }
        let blocks = items.map {
            "<selection file=\"\($0.url.path)\" lines=\"\($0.range.startLine)-\($0.range.endLine)\">\n\($0.content)\n</selection>"
        }.joined(separator: "\n\n")
        if let sideChat = sideChatRequest(request.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return [sideChat.isEmpty ? "/btw" : "/btw \(sideChat)", "", "Context:", blocks].joined(separator: "\n")
        }
        return [
            "Please handle the following request using the selected context.",
            "",
            "Request:",
            request,
            "",
            "Selected content:",
            blocks
        ].joined(separator: "\n")
    }

    /// The request typed into a prompt made by `build`, or nil once its layout was edited away.
    public static func request(in prompt: String) -> String? {
        if prompt.hasPrefix("/btw"), let end = prompt.range(of: "\n\nContext:\n") { return String(prompt[..<end.lowerBound]) }
        guard let start = prompt.range(of: "Request:\n"),
              let end = prompt.range(of: "\n\nSelected content:\n", range: start.upperBound..<prompt.endIndex) else { return nil }
        return String(prompt[start.upperBound..<end.lowerBound])
    }

    private static func build(url: URL, range: SourceRange, request: String, content: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sideChat = sideChatRequest(trimmed) {
            let command = sideChat.isEmpty ? "/btw" : "/btw \(sideChat)"
            return [
                command,
                "",
                "Context:",
                "File: \(url.path)",
                "Lines: \(range.startLine)-\(range.endLine)",
                "",
                "Selected content:",
                "<selection>",
                content,
                "</selection>"
            ].joined(separator: "\n")
        }

        return [
            "Please handle the following request using the selected context.",
            "",
            "File: \(url.path)",
            "Lines: \(range.startLine)-\(range.endLine)",
            "",
            "Request:",
            request,
            "",
            "Selected content:",
            "<selection>",
            content,
            "</selection>"
        ].joined(separator: "\n")
    }

    /// `/btw` is recognized only as the complete command or when followed by
    /// whitespace, matching the Neovim integration. The rest is preserved.
    public static func sideChatRequest(_ request: String) -> String? {
        guard request == "/btw" || request.hasPrefix("/btw ") || request.hasPrefix("/btw\t") || request.hasPrefix("/btw\n") else {
            return nil
        }
        return String(request.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct WezTermPane: Codable, Equatable, Sendable {
    public let paneID: Int
    public let tabID: Int
    public let leftCol: Int
    public let topRow: Int
    public let title: String
    public var role: String?

    public init(paneID: Int, tabID: Int, leftCol: Int, topRow: Int, title: String = "", role: String? = nil) {
        self.paneID = paneID
        self.tabID = tabID
        self.leftCol = leftCol
        self.topRow = topRow
        self.title = title
        self.role = role
    }

    enum CodingKeys: String, CodingKey { case paneID = "pane_id", tabID = "tab_id", leftCol = "left_col", topRow = "top_row", title, role }
}

public enum PaneResolutionError: Error, LocalizedError, Equatable {
    case currentPaneMissing
    case sourceMustBeLeftmost
    case noTarget
    case tooManyTargets(Int)
    case explicitTargetNotInSameTab
    case explicitTargetMissing

    public var errorDescription: String? {
        switch self {
        case .currentPaneMissing: return "Could not identify the originating WezTerm pane."
        case .sourceMustBeLeftmost: return "The Neovim pane must be the leftmost pane in the current WezTerm tab."
        case .noTarget: return "No coding-agent pane exists in the current WezTerm tab."
        case .tooManyTargets(let count): return "Expected at most two coding-agent panes, found \(count)."
        case .explicitTargetNotInSameTab: return "The selected target pane is not in the originating WezTerm tab."
        case .explicitTargetMissing: return "The selected target pane no longer exists."
        }
    }
}

public enum PaneTargetResolver {
    public static func resolve(
        panes: [WezTermPane],
        currentPaneID: Int,
        explicitTargetID: Int? = nil,
        maxTargets: Int = 2
    ) throws -> [WezTermPane] {
        guard let current = panes.first(where: { $0.paneID == currentPaneID }) else {
            throw PaneResolutionError.currentPaneMissing
        }
        let tabPanes = panes.filter { $0.tabID == current.tabID }.sorted {
            $0.leftCol == $1.leftCol ? $0.topRow < $1.topRow : $0.leftCol < $1.leftCol
        }
        guard tabPanes.first?.paneID == currentPaneID else { throw PaneResolutionError.sourceMustBeLeftmost }

        let candidates = Array(tabPanes.dropFirst())
        guard !candidates.isEmpty else { throw PaneResolutionError.noTarget }
        guard candidates.count <= maxTargets else { throw PaneResolutionError.tooManyTargets(candidates.count) }

        if let explicitTargetID {
            guard let target = candidates.first(where: { $0.paneID == explicitTargetID }) else {
                guard panes.contains(where: { $0.paneID == explicitTargetID }) else { throw PaneResolutionError.explicitTargetMissing }
                throw PaneResolutionError.explicitTargetNotInSameTab
            }
            return [target]
        }
        return candidates.enumerated().map { index, pane in
            var pane = pane
            // Match the existing Neovim integration: the nearer (left) pane
            // is Pane2 and the farther (right) pane is Pane1.
            pane.role = candidates.count == 1 ? "Pane1" : (index == 0 ? "Pane2" : "Pane1")
            return pane
        }
    }
}

public enum PaneJSON {
    public static func decode(_ data: Data) throws -> [WezTermPane] {
        try JSONDecoder().decode([WezTermPane].self, from: data)
    }
}

public actor RevisionStore {
    private var value: UInt64 = 0
    public init() {}
    public func next() -> UInt64 { value += 1; return value }
}

public final class Debouncer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private var workItem: DispatchWorkItem?
    private let lock = NSLock()

    public init(interval: TimeInterval, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    public func schedule(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        workItem?.cancel()
        workItem = nil
    }
}
