import ConversationCore
import CryptoKit
import Darwin
import Foundation

public enum ProviderKitError: LocalizedError, Sendable, Equatable {
    case executableUnavailable(String)
    case processFailed(executable: String, status: Int32, stderr: String)
    case processTimedOut(String)
    case malformedResponse(String)
    case unreadableSource(String)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let name):
            "Executable not available: \(name)"
        case .processFailed(let executable, let status, let stderr):
            "\(executable) exited with status \(status): \(stderr)"
        case .processTimedOut(let executable):
            "\(executable) timed out"
        case .malformedResponse(let detail):
            "Malformed provider response: \(detail)"
        case .unreadableSource(let path):
            "Provider source is not readable: \(path)"
        }
    }
}

public enum StableHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }
}

public struct ProviderEnvironment: Sendable {
    public let homeDirectory: URL
    public let environment: [String: String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.environment = environment
    }

    public var codexHome: URL {
        configuredDirectory(named: "CODEX_HOME") ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public var claudeHome: URL {
        configuredDirectory(named: "CLAUDE_CONFIG_DIR") ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    public var executableSearchPaths: [URL] {
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        paths.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
        ])
        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func executable(named name: String, fileManager: FileManager = .default) -> URL? {
        guard !name.contains("/"), !name.isEmpty else { return nil }
        return executableCandidates(named: name)
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func executableCandidates(named name: String) -> [URL] {
        guard !name.contains("/"), !name.isEmpty else { return [] }
        var candidates = executableSearchPaths.map { $0.appendingPathComponent(name, isDirectory: false) }
        switch name {
        case "codex":
            candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex", isDirectory: false))
        case "claude":
            candidates.append(
                homeDirectory.appendingPathComponent(".local/share/claude/ClaudeCode.app/Contents/MacOS/claude", isDirectory: false)
            )
        default:
            break
        }
        var seen = Set<String>()
        return candidates.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    private func configuredDirectory(named key: String) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let expanded: String
        if raw == "~" {
            expanded = homeDirectory.path
        } else if raw.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            expanded = raw
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(status: Int32, standardOutput: Data, standardError: Data) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> ProcessResult
}

public struct LocalProcessRunner: ProcessRunning, Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 1_048_576
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            try Self.runBlocking(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes
            )
        }.value
    }

    private static func runBlocking(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if let environment {
            process.environment = environment
        }

        let outputCollector = LimitedPipeCollector(limit: maximumOutputBytes)
        let errorCollector = LimitedPipeCollector(limit: maximumOutputBytes)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        try process.run()
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            while process.isRunning { Thread.sleep(forTimeInterval: 0.005) }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ProviderKitError.processTimedOut(executable.path)
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let result = ProcessResult(
            status: process.terminationStatus,
            standardOutput: outputCollector.data,
            standardError: errorCollector.data
        )
        guard result.status == 0 else {
            throw ProviderKitError.processFailed(
                executable: executable.path,
                status: result.status,
                stderr: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        return result
    }
}

private final class LimitedPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            let remaining = limit - storage.count
            if remaining > 0 { storage.append(chunk.prefix(remaining)) }
        }
    }

    var data: Data { lock.withLock { storage } }
}

enum ProviderImportLimits {
    static let maximumJSONLBytes = 8 * 1_024 * 1_024
    static let maximumEventsPerConversation = 4_000
    static let maximumTextCharactersPerEvent = 512_000
    static let maximumTextCharactersPerConversation = 8_000_000
    static let maximumRawBytesPerConversation = 8 * 1_024 * 1_024
}

struct ImportBudget: Sendable {
    let maximumItems: Int
    let maximumTextBytes: Int
    let maximumRawBytes: Int

    static let conversation = ImportBudget(
        maximumItems: ProviderImportLimits.maximumEventsPerConversation,
        maximumTextBytes: ProviderImportLimits.maximumTextCharactersPerConversation,
        maximumRawBytes: ProviderImportLimits.maximumRawBytesPerConversation
    )
}

struct BoundedImportAccumulator<Element> {
    private struct Entry {
        let value: Element
        let textBytes: Int
        let rawBytes: Int
    }

    private let budget: ImportBudget
    private var head: [Entry] = []
    private var tail: [Entry] = []
    private var tailStart = 0
    private var headTextBytes = 0
    private var headRawBytes = 0
    private var tailTextBytes = 0
    private var tailRawBytes = 0
    private var isSplit = false

    private(set) var omittedItemCount = 0
    private(set) var omittedTextBytes = 0
    private(set) var omittedRawBytes = 0

    init(budget: ImportBudget = .conversation) {
        self.budget = budget
    }

    mutating func append(_ value: Element, textBytes: Int, rawBytes: Int) {
        let entry = Entry(value: value, textBytes: max(0, textBytes), rawBytes: max(0, rawBytes))
        if !isSplit {
            head.append(entry)
            headTextBytes += entry.textBytes
            headRawBytes += entry.rawBytes
            if exceedsTotalBudget {
                splitForTail()
                trimTailToBudget()
            }
            return
        }

        tail.append(entry)
        tailTextBytes += entry.textBytes
        tailRawBytes += entry.rawBytes
        trimTailToBudget()
    }

    var headElements: [Element] { head.map(\.value) }
    var tailElements: [Element] { tail[tailStart...].map(\.value) }
    var hasOmissions: Bool { omittedItemCount > 0 }

    private var activeTailCount: Int { tail.count - tailStart }
    private var totalItemCount: Int { head.count + activeTailCount }
    private var totalTextBytes: Int { headTextBytes + tailTextBytes }
    private var totalRawBytes: Int { headRawBytes + tailRawBytes }
    private var exceedsTotalBudget: Bool {
        totalItemCount > max(1, budget.maximumItems)
            || totalTextBytes > max(0, budget.maximumTextBytes)
            || totalRawBytes > max(0, budget.maximumRawBytes)
    }

    private mutating func splitForTail() {
        isSplit = true
        let headItemTarget = max(1, budget.maximumItems / 2)
        let headTextTarget = max(0, budget.maximumTextBytes / 2)
        let headRawTarget = max(0, budget.maximumRawBytes / 2)
        var moved: [Entry] = []
        while head.count > 1,
              (head.count > headItemTarget
               || headTextBytes > headTextTarget
               || headRawBytes > headRawTarget) {
            let entry = head.removeLast()
            headTextBytes -= entry.textBytes
            headRawBytes -= entry.rawBytes
            moved.append(entry)
        }
        tail = moved.reversed()
        tailStart = 0
        tailTextBytes = tail.reduce(0) { $0 + $1.textBytes }
        tailRawBytes = tail.reduce(0) { $0 + $1.rawBytes }
    }

    private mutating func trimTailToBudget() {
        while exceedsTotalBudget, tailStart < tail.count {
            let removed = tail[tailStart]
            tailStart += 1
            tailTextBytes -= removed.textBytes
            tailRawBytes -= removed.rawBytes
            omittedItemCount += 1
            omittedTextBytes += removed.textBytes
            omittedRawBytes += removed.rawBytes
        }
        if tailStart > 1_024, tailStart * 2 > tail.count {
            tail.removeFirst(tailStart)
            tailStart = 0
        }
    }
}

actor ProviderConversationCollector {
    private var storage: [ProviderConversation] = []

    func append(_ conversation: ProviderConversation) {
        storage.append(conversation)
    }

    func conversations() -> [ProviderConversation] { storage }
}

enum ProviderDates {
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSecondISO8601 = Date.ISO8601FormatStyle()

    static func parse(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let seconds):
            return Date(timeIntervalSince1970: seconds)
        case .string(let raw):
            if let numeric = Double(raw), numeric > 0 {
                return Date(timeIntervalSince1970: numeric)
            }
            return (try? fractionalISO8601.parse(raw))
                ?? (try? wholeSecondISO8601.parse(raw))
        default:
            return nil
        }
    }
}

extension String {
    var providerTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func providerTruncated(_ length: Int) -> String {
        guard length > 0 else { return "" }
        guard count > length else { return self }
        guard length > 1 else { return "…" }
        return String(prefix(length - 1)) + "…"
    }
}

func boundedRawPayload(_ data: Data?, metadata: inout [String: String], maximumBytes: Int = 256 * 1_024) -> Data? {
    guard let data else { return nil }
    guard data.count > maximumBytes else { return data }
    metadata["rawPayloadOmitted"] = "true"
    metadata["rawPayloadBytes"] = String(data.count)
    return nil
}
