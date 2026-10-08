import Foundation

public enum MarkdownFileNavigation {
    public enum Direction: Sendable { case previous, next }

    /// Matches file_navigation.lua: adjacent files first, then sibling
    /// directories, whose contents follow directory-first tree order.
    public static func adjacent(to current: URL, direction: Direction) -> URL? {
        let current = current.standardizedFileURL
        let directory = current.deletingLastPathComponent()
        let files = scan(directory).files
        let step = direction == .next ? 1 : -1
        if let index = files.firstIndex(of: current), files.indices.contains(index + step) {
            return files[index + step]
        }

        let siblings = scan(directory.deletingLastPathComponent()).directories
        guard let index = siblings.firstIndex(of: directory) else { return nil }
        var candidate = index + step
        while siblings.indices.contains(candidate) {
            var visited = Set<String>()
            if let file = edgeFile(in: siblings[candidate], direction: direction, visited: &visited) { return file }
            candidate += step
        }
        return nil
    }

    private static func scan(_ directory: URL) -> (files: [URL], directories: [URL]) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var files: [URL] = [], directories: [URL] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true { directories.append(entry.standardizedFileURL) }
            else if values.isRegularFile == true, DocumentKind.markdownExtensions.contains(entry.pathExtension.lowercased()) {
                files.append(entry.standardizedFileURL)
            }
        }
        let byName: (URL, URL) -> Bool = { $0.lastPathComponent < $1.lastPathComponent }
        return (files.sorted(by: byName), directories.sorted(by: byName))
    }

    private static func edgeFile(in directory: URL, direction: Direction, visited: inout Set<String>) -> URL? {
        guard visited.insert(directory.resolvingSymlinksInPath().path).inserted else { return nil }
        let entries = scan(directory)
        if direction == .previous, let file = entries.files.last { return file }
        let directories = direction == .next ? entries.directories : Array(entries.directories.reversed())
        for child in directories {
            if let file = edgeFile(in: child, direction: direction, visited: &visited) { return file }
        }
        return direction == .next ? entries.files.first : nil
    }
}
