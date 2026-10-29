import Foundation

public struct RecentFiles {
    public static let limit = 50
    private static let key = "recentFiles"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Most recent first; files that no longer exist are skipped.
    public var urls: [URL] {
        (defaults.stringArray(forKey: Self.key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = [path] + (defaults.stringArray(forKey: Self.key) ?? []).filter { $0 != path }
        defaults.set(Array(paths.prefix(Self.limit)), forKey: Self.key)
    }
}
