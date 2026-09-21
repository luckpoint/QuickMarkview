import Foundation

public struct LaunchOptions: Equatable, Sendable {
    public var fileURL: URL?
    public var line: Int?
    public var originPaneID: Int?
    public var targetPaneID: Int?
    public var showHelp = false

    public init(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": showHelp = true
            case "--line":
                index += 1; line = try Self.integer(arguments, index, option: "--line")
            case "--pane":
                index += 1; originPaneID = try Self.nonnegativeInteger(arguments, index, option: "--pane")
            case "--target-pane":
                index += 1; targetPaneID = try Self.nonnegativeInteger(arguments, index, option: "--target-pane")
            case let value where value.hasPrefix("--line="):
                line = try Self.integer(String(value.dropFirst("--line=".count)), option: "--line")
            case let value where value.hasPrefix("--pane="):
                originPaneID = try Self.nonnegativeInteger(String(value.dropFirst("--pane=".count)), option: "--pane")
            case let value where value.hasPrefix("--target-pane="):
                targetPaneID = try Self.nonnegativeInteger(String(value.dropFirst("--target-pane=".count)), option: "--target-pane")
            case let value where value.hasPrefix("-"):
                throw LaunchError.unknownOption(value)
            default:
                if fileURL != nil { throw LaunchError.multipleFiles }
                fileURL = URL(fileURLWithPath: argument).standardizedFileURL
            }
            index += 1
        }
        if let line { self.line = max(1, line) }
    }

    private static func integer(_ arguments: [String], _ index: Int, option: String) throws -> Int {
        guard index < arguments.count else { throw LaunchError.missingValue(option) }
        return try integer(arguments[index], option: option)
    }

    private static func integer(_ value: String, option: String) throws -> Int {
        guard let result = Int(value), result > 0 else { throw LaunchError.invalidValue(option, value) }
        return result
    }

    private static func nonnegativeInteger(_ arguments: [String], _ index: Int, option: String) throws -> Int {
        guard index < arguments.count else { throw LaunchError.missingValue(option) }
        return try nonnegativeInteger(arguments[index], option: option)
    }

    private static func nonnegativeInteger(_ value: String, option: String) throws -> Int {
        guard let result = Int(value), result >= 0 else { throw LaunchError.invalidValue(option, value) }
        return result
    }
}

public enum LaunchError: Error, LocalizedError, Equatable {
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(String, String)
    case multipleFiles

    public var errorDescription: String? {
        switch self {
        case .unknownOption(let value): return "Unknown option: \(value)"
        case .missingValue(let option): return "Missing value for \(option)"
        case .invalidValue(let option, let value): return "Invalid value for \(option): \(value)"
        case .multipleFiles: return "Only one Markdown file can be opened."
        }
    }
}

public let quickMarkviewUsage = """
QuickMarkview — offline Markdown and Mermaid viewer

Usage:
  QuickMarkview [--line N] [--pane ORIGIN_PANE_ID] [--target-pane PANE_ID] [path]

--line N          Scroll to a one-based source line after rendering.
--pane ID         Originating Neovim/WezTerm pane. Defaults to WEZTERM_PANE.
--target-pane ID  Explicit coding-agent pane when the tab has two targets.
"""
