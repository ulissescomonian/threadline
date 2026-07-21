import Foundation

struct CodexAppServerThread: Sendable {
    let value: JSONValue
}

protocol CodexAppServerProviding: Sendable {
    func fetchThreads(since: Date?) async throws -> [CodexAppServerThread]
}

protocol CodexAppServerRPCSession: Sendable {
    func request(method: String, params: JSONValue, timeout: TimeInterval) throws -> JSONValue
    func notify(method: String, params: JSONValue) throws
    func close()
}

actor CodexStdioAppServer: CodexAppServerProviding {
    private let requestTimeout: TimeInterval
    private let makeSession: @Sendable () throws -> any CodexAppServerRPCSession

    init(executableURL: URL, requestTimeout: TimeInterval = 10) {
        self.requestTimeout = requestTimeout
        makeSession = { try JSONRPCStdioSession(executableURL: executableURL) }
    }

    init(
        requestTimeout: TimeInterval = 10,
        makeSession: @escaping @Sendable () throws -> any CodexAppServerRPCSession
    ) {
        self.requestTimeout = requestTimeout
        self.makeSession = makeSession
    }

    func fetchThreads(since: Date?) async throws -> [CodexAppServerThread] {
        let session = try makeSession()
        defer { session.close() }

        _ = try session.request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("threadline"),
                    "title": .string("Threadline"),
                    "version": .string("0.1.0"),
                ]),
                "capabilities": .object([
                    "optOutNotificationMethods": .array([]),
                ]),
            ]),
            timeout: requestTimeout
        )
        try session.notify(method: "initialized", params: .object([:]))

        var summaries: [JSONValue] = []
        for archived in [false, true] {
            var cursor: String?
            repeat {
                var params: [String: JSONValue] = [
                    "limit": .number(100),
                    "archived": .bool(archived),
                    "sortKey": .string("updated_at"),
                    "sortDirection": .string("desc"),
                    "useStateDbOnly": .bool(true),
                ]
                if let cursor { params["cursor"] = .string(cursor) }
                let result = try session.request(method: "thread/list", params: .object(params), timeout: requestTimeout)
                let page = result["data"]?.arrayValue ?? []
                summaries.append(contentsOf: page)
                if Self.crossedKnownBoundary(in: page, since: since) {
                    cursor = nil
                } else {
                    cursor = result["nextCursor"]?.stringValue
                }
            } while cursor != nil
        }

        var seen = Set<String>()
        var output: [CodexAppServerThread] = []
        for summary in summaries {
            guard let id = summary["id"]?.stringValue, seen.insert(id).inserted else { continue }
            if let since, let updated = ProviderDates.parse(summary["updatedAt"]), updated < since { continue }
            do {
                try Task.checkCancellation()
                let result = try session.request(
                    method: "thread/read",
                    params: .object(["threadId": .string(id), "includeTurns": .bool(true)]),
                    timeout: requestTimeout
                )
                if let thread = result["thread"] {
                    output.append(CodexAppServerThread(value: thread))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A single unavailable, oversized, or version-skewed thread
                // must not discard the successful app-server reads around it.
                // The adapter will fill this session from its rollout JSONL.
                continue
            }
        }
        return output
    }

    /// `thread/list` is explicitly ordered newest-first. Consume the complete
    /// boundary page, then stop only when every entry after the first known-old
    /// item is also known-old. Unknown dates remain candidates and force the
    /// next page to be inspected rather than risking an omission.
    private static func crossedKnownBoundary(in page: [JSONValue], since: Date?) -> Bool {
        guard let since else { return false }
        var crossed = false
        for summary in page {
            guard let updated = ProviderDates.parse(summary["updatedAt"]) else {
                if crossed { return false }
                continue
            }
            if updated < since {
                crossed = true
            } else if crossed {
                // Be conservative if a provider version does not honor the
                // requested ordering exactly.
                return false
            }
        }
        return crossed
    }
}

private struct JSONRPCResponse: Decodable {
    struct Failure: Decodable {
        let code: Int
        let message: String
    }

    let id: Int?
    let result: JSONValue?
    let error: Failure?
}

private final class JSONRPCStdioSession: CodexAppServerRPCSession, @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let condition = NSCondition()
    private var messages: [Data] = []
    private var readBuffer = Data()
    private var nextID = 1
    private var isClosed = false
    private var discardingOversizedMessage = false
    private var oversizedResponseDetected = false
    private let maximumMessageBytes = 8 * 1_024 * 1_024

    init(executableURL: URL) throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errorOutput = stderrPipe.fileHandleForReading

        output.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errorOutput.readabilityHandler = { handle in
            _ = handle.availableData // Drain stderr so the child can never block on a full pipe.
        }

        do {
            try process.run()
        } catch {
            close()
            throw ProviderKitError.executableUnavailable(executableURL.path)
        }
    }

    func request(method: String, params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        let id: Int = condition.withLock {
            defer { nextID += 1 }
            return nextID
        }
        try send(.object([
            "method": .string(method),
            "id": .number(Double(id)),
            "params": params,
        ]))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let responseWasOversized = condition.withLock {
                defer { oversizedResponseDetected = false }
                return oversizedResponseDetected
            }
            if responseWasOversized {
                throw ProviderKitError.malformedResponse("codex app-server response exceeded the safe 8 MB limit")
            }
            let candidates: [Data] = condition.withLock {
                let matching = messages.filter { data in
                    (try? JSONDecoder().decode(JSONRPCResponse.self, from: data).id) == id
                }
                if !matching.isEmpty {
                    messages.removeAll { matching.contains($0) }
                }
                return matching
            }
            if let data = candidates.first {
                let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
                if let failure = response.error {
                    throw ProviderKitError.malformedResponse("JSON-RPC \(failure.code): \(failure.message)")
                }
                return response.result ?? .object([:])
            }
            guard process.isRunning else {
                throw ProviderKitError.processFailed(executable: process.executableURL?.path ?? "codex", status: process.terminationStatus, stderr: "app-server closed its output")
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ProviderKitError.processTimedOut("codex app-server") }
            condition.lock()
            condition.wait(until: Date().addingTimeInterval(min(remaining, 0.2)))
            condition.unlock()
        }
    }

    func notify(method: String, params: JSONValue) throws {
        try send(.object(["method": .string(method), "params": params]))
    }

    func close() {
        condition.withLock {
            guard !isClosed else { return }
            isClosed = true
            output.readabilityHandler = nil
            errorOutput.readabilityHandler = nil
            try? input.close()
            if process.isRunning { process.terminate() }
        }
    }

    private func send(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            condition.broadcast()
            return
        }
        condition.withLock {
            readBuffer.append(data)
            if discardingOversizedMessage {
                if let newline = readBuffer.firstIndex(of: 0x0A) {
                    readBuffer.removeFirst(readBuffer.distance(from: readBuffer.startIndex, to: newline) + 1)
                    discardingOversizedMessage = false
                } else {
                    readBuffer.removeAll(keepingCapacity: true)
                    return
                }
            }
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                let count = readBuffer.distance(from: readBuffer.startIndex, to: newline)
                if count > maximumMessageBytes {
                    readBuffer.removeFirst(count + 1)
                    oversizedResponseDetected = true
                    continue
                }
                let line = Data(readBuffer.prefix(count))
                readBuffer.removeFirst(count + 1)
                if !line.isEmpty { messages.append(line) }
            }
            if readBuffer.count > maximumMessageBytes {
                readBuffer.removeAll(keepingCapacity: true)
                discardingOversizedMessage = true
                oversizedResponseDetected = true
            }
            if messages.count > 1_024 {
                messages.removeFirst(messages.count - 1_024)
            }
            condition.broadcast()
        }
    }
}

private extension NSCondition {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
