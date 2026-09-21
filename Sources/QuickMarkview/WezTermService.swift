import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(arguments: [String], stdin: Data?, completion: @escaping @Sendable (Result<CommandResult, Error>) -> Void)
}

public enum CommandError: Error, LocalizedError, Sendable {
    case launch(String)
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .launch(let message): return message
        case .timedOut: return "The WezTerm command timed out."
        case .failed(let message): return message
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (Result<CommandResult, Error>) -> Void
    init(_ completion: @escaping @Sendable (Result<CommandResult, Error>) -> Void) { self.completion = completion }
    func call(_ result: Result<CommandResult, Error>) {
        lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock(); completion(result)
    }
}

/// Process execution without a shell. stdout and stderr are drained on
/// separate queues so a verbose CLI cannot deadlock on a full pipe.
public final class CommandRunner: CommandRunning, @unchecked Sendable {
    public let timeout: TimeInterval
    private let queue = DispatchQueue(label: "quickmarkview.process", qos: .userInitiated)

    public init(timeout: TimeInterval = 3) { self.timeout = timeout }

    public func run(arguments: [String], stdin: Data? = nil, completion: @escaping @Sendable (Result<CommandResult, Error>) -> Void) {
        queue.async {
            let process = Process()
            let output = Pipe(), error = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input
            do { try process.run() } catch { completion(.failure(CommandError.launch(error.localizedDescription))); return }
            let stdout = DataBox(), stderr = DataBox()
            let group = DispatchGroup()
            group.enter(); DispatchQueue.global(qos: .utility).async { stdout.set(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            group.enter(); DispatchQueue.global(qos: .utility).async { stderr.set(error.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            let gate = CompletionGate(completion)
            // Drain both output pipes before writing input. Writing on its own
            // queue means a large prompt cannot block the process runner.
            if let stdin {
                DispatchQueue.global(qos: .utility).async {
                    do { try input.fileHandleForWriting.write(contentsOf: stdin); try input.fileHandleForWriting.close() }
                    catch { if process.isRunning { process.terminate() }; gate.call(.failure(CommandError.launch("Could not write to the WezTerm command: \(error.localizedDescription)"))) }
                }
            } else { try? input.fileHandleForWriting.close() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.timeout) {
                if process.isRunning {
                    process.terminate(); gate.call(.failure(CommandError.timedOut))
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            process.waitUntilExit()
            group.wait()
            gate.call(.success(CommandResult(status: process.terminationStatus, stdout: stdout.get(), stderr: stderr.get())))
        }
    }
}

public struct PaneInput: Equatable, Sendable {
    public let text: String
    public let paste: Bool
}

public final class WezTermService: @unchecked Sendable {
    private let runner: CommandRunning
    public init(runner: CommandRunning = CommandRunner()) { self.runner = runner }

    public func listPanes(completion: @escaping @Sendable (Result<[WezTermPane], Error>) -> Void) {
        runner.run(arguments: [Self.wezTermExecutable(), "cli", "list", "--format", "json"], stdin: nil) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let value):
                guard value.status == 0 else { completion(.failure(CommandError.failed(Self.message(value.stderr, fallback: "Could not read the WezTerm pane list.")))); return }
                do { completion(.success(try PaneJSON.decode(value.stdout))) }
                catch { completion(.failure(CommandError.failed("Could not parse the WezTerm pane list: \(error.localizedDescription)"))) }
            }
        }
    }

    public func send(text: String, to paneID: Int, submitDelay: TimeInterval = 0.05, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        send(Self.inputs(for: text)[...], to: paneID, delay: submitDelay, completion: completion)
    }

    /// A `/btw` prompt types the command and pastes only the rest.
    public static func inputs(for text: String) -> [PaneInput] {
        guard let rest = PromptBuilder.sideChatRequest(text) else {
            return [PaneInput(text: text, paste: true), PaneInput(text: "\r", paste: false)]
        }
        return [PaneInput(text: "/btw ", paste: false), PaneInput(text: rest, paste: true), PaneInput(text: "\r", paste: false)].filter { !$0.text.isEmpty }
    }

    private func send(_ inputs: ArraySlice<PaneInput>, to paneID: Int, delay: TimeInterval, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let input = inputs.first else { completion(.success(())); return }
        let mode = input.paste ? [] : ["--no-paste"]
        runner.run(arguments: [Self.wezTermExecutable(), "cli", "send-text"] + mode + ["--pane-id", String(paneID)], stdin: Data(input.text.utf8)) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let value) where value.status != 0: completion(.failure(CommandError.failed(Self.message(value.stderr, fallback: "Could not send the request."))))
            case .success where inputs.count == 1: completion(.success(()))
            case .success:
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                    self.send(inputs.dropFirst(), to: paneID, delay: delay, completion: completion)
                }
            }
        }
    }

    private static func message(_ data: Data, fallback: String) -> String {
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? fallback : message
    }

    private static func wezTermExecutable() -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["QUICKMARKVIEW_WEZTERM"] ?? "",
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
            (environment["HOME"].map { "\($0)/Applications/WezTerm.app/Contents/MacOS/wezterm" } ?? ""),
            "wezterm"
        ]
        return candidates.first(where: { !$0.isEmpty && ($0 == "wezterm" || FileManager.default.isExecutableFile(atPath: $0)) }) ?? "wezterm"
    }
}
