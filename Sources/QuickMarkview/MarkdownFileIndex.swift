import Foundation

public enum MarkdownFileIndex {
    public static let maximumFileCount = 20_000

    /// Lists Markdown paths relative to `root`. Git supplies tracked and
    /// non-ignored untracked files when available; otherwise the filesystem is
    /// enumerated directly.
    public static func list(root: URL, runner: CommandRunning = CommandRunner(timeout: 5), completion: @escaping @Sendable ([String]) -> Void) {
        let root = root.standardizedFileURL
        let hasGitDirectory = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        guard hasGitDirectory else {
            completion(filesystemPaths(root: root))
            return
        }

        runner.run(arguments: ["git", "-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"], stdin: nil) { result in
            if case .success(let command) = result, command.status == 0 {
                completion(gitPaths(command.stdout))
            } else {
                completion(filesystemPaths(root: root))
            }
        }
    }

    private static func isMarkdown(_ path: String) -> Bool {
        DocumentKind.markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func gitPaths(_ data: Data) -> [String] {
        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .filter(isMarkdown)
        return Array(paths.sorted().prefix(maximumFileCount))
    }

    private static func filesystemPaths(root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1))
            guard isMarkdown(relativePath) else { continue }
            paths.append(relativePath)
            if paths.count >= maximumFileCount { break }
        }
        return paths.sorted()
    }
}
