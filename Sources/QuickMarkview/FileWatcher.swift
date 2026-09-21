import Foundation
import Darwin

/// Watches both the file and its containing directory. Editors commonly save
/// by writing a temporary file and renaming it over the original, which makes
/// a file-only vnode source stale; the directory source lets us re-arm it.
public final class FileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(label: "quickmarkview.filewatch", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var fileDescriptor: Int32 = -1
    private var directoryDescriptor: Int32 = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private let debounce: Debouncer

    public init(fileURL: URL, debounceInterval: TimeInterval = 0.18, callback: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.callback = callback
        self.debounce = Debouncer(interval: debounceInterval, queue: queue)
        queue.setSpecific(key: queueKey, value: ())
    }

    public func start() { queue.async { [weak self] in self?.startOnQueue() } }

    private func startOnQueue() {
        guard directorySource == nil else { return }
        let parent = fileURL.deletingLastPathComponent().path
        directoryDescriptor = open(parent, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }
        let directory = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryDescriptor, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        directory.setEventHandler { [weak self] in
            guard let self else { return }
            self.rearmFileSource()
            self.scheduleCallback()
        }
        directory.setCancelHandler { [descriptor = directoryDescriptor] in close(descriptor) }
        directorySource = directory
        directory.resume()
        rearmFileSource()
    }

    private func rearmFileSource() {
        fileSource?.cancel(); fileSource = nil; fileDescriptor = -1
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        let file = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        file.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleCallback()
            // A rename/delete invalidates this descriptor. Reopen the path so
            // later writes to the replacement file are still observed.
            self.rearmFileSource()
        }
        file.setCancelHandler { [descriptor = fileDescriptor] in close(descriptor) }
        fileSource = file
        file.resume()
    }

    private func scheduleCallback() {
        debounce.schedule { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            self.callback()
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        debounce.cancel()
        fileSource?.cancel(); fileSource = nil; fileDescriptor = -1
        directorySource?.cancel(); directorySource = nil; directoryDescriptor = -1
    }

    deinit { stop() }
}
