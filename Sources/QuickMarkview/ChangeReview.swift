import Foundation

/// Ranges are zero-based, half-open. A deletion's empty new range is a boundary,
/// including new.count at EOF; it must not be clamped to a surviving line.
struct ReviewChange: Codable, Equatable {
    let oldStart: Int
    let oldEnd: Int
    let newStart: Int
    let newEnd: Int
    let oldText: String
    var kind: String { oldStart == oldEnd ? "added" : newStart == newEnd ? "deleted" : "modified" }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.last == "" { result.removeLast() }
        return result
    }

    static func compare(_ baseline: String, _ current: String) -> [ReviewChange] {
        guard baseline != current else { return [] }
        let old = lines(baseline), new = lines(current)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [ReviewChange] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            let a = i, b = j
            while i < old.count && removed.contains(i) { i += 1 }
            while j < new.count && inserted.contains(j) { j += 1 }
            if a != i || b != j {
                result.append(ReviewChange(oldStart: a, oldEnd: i, newStart: b, newEnd: j, oldText: old[a..<i].joined(separator: "\n")))
            } else { i += 1; j += 1 }
        }
        return result
    }
}

struct ReviewFile: Equatable {
    var baseline: String
    var current: String
    var changes: [ReviewChange]
}

/// One review session belongs to the resident viewer, including files that are
/// no longer on screen. Quitting the app discards the comparison baselines.
final class ChangeReviewSession {
    private(set) var files: [String: ReviewFile] = [:]
    private let read: (String) throws -> String?

    init(read: @escaping (String) throws -> String? = ChangeReviewSession.read) {
        self.read = read
    }

    func register(url: URL, text: String) {
        if files[url.path] == nil {
            files[url.path] = ReviewFile(baseline: text, current: text, changes: [])
        }
    }

    static func read(_ path: String) throws -> String? {
        do { return try String(contentsOfFile: path, encoding: .utf8) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    func snapshot() throws -> [String: ReviewFile] {
        var next = files
        for (path, var file) in files {
            let text = try read(path) ?? ""
            if text != file.current {
                file.current = text
                file.changes = ReviewChange.compare(file.baseline, text)
                next[path] = file
            }
        }
        files = next
        return files
    }

    func acknowledge() throws {
        // Complete all reads before replacing any baseline, so a read error
        // cannot silently mark only part of the review session acknowledged.
        let current = try snapshot()
        files = current.mapValues { ReviewFile(baseline: $0.current, current: $0.current, changes: []) }
    }

    func nextFile(after path: String, direction: Int) throws -> (path: String, index: Int)? {
        let changed = try snapshot().filter { !$0.value.changes.isEmpty }.keys.sorted()
        let candidate = direction > 0 ? changed.first { $0 > path } : changed.last { $0 < path }
        guard let candidate, let file = files[candidate] else { return nil }
        return (candidate, direction > 0 ? 0 : file.changes.count - 1)
    }
}
