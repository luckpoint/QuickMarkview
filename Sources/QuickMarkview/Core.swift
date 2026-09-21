import Foundation

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
        let first = max(1, min(range.startLine, lines.count)) - 1
        let last = max(first, min(range.endLine, lines.count) - 1)
        return lines[first...last].joined(separator: "\n")
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

public enum PromptBuilder {
    public static func build(context: MarkdownDocument, range: SourceRange, request: String, selectedText: String? = nil) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = selectedText?.isEmpty == false ? selectedText! : context.text(in: range)
        if let sideChat = sideChatRequest(trimmed) {
            let command = sideChat.isEmpty ? "/btw" : "/btw \(sideChat)"
            return [
                command,
                "",
                "Context:",
                "File: \(context.url.path)",
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
            "File: \(context.url.path)",
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
