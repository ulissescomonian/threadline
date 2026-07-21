@testable import ProviderKit
import Foundation
import Testing

@Test func codexAppServerRequestsStableNewestFirstStateDatabasePages() async throws {
    let session = RecordingCodexRPCSession { method, params, _ in
        switch method {
        case "initialize":
            return .object([:])
        case "thread/list":
            return .object(["data": .array([])])
        default:
            Issue.record("Unexpected request: \(method)")
            return .object([:])
        }
    }
    let server = CodexStdioAppServer(makeSession: { session })

    _ = try await server.fetchThreads(since: nil)

    let listRequests = session.requests(method: "thread/list")
    #expect(listRequests.count == 2)
    #expect(listRequests.map { $0.params["archived"]?.boolValue } == [false, true])
    for request in listRequests {
        #expect(request.params["limit"]?.intValue == 100)
        #expect(request.params["sortKey"]?.stringValue == "updated_at")
        #expect(request.params["sortDirection"]?.stringValue == "desc")
        #expect(request.params["useStateDbOnly"]?.boolValue == true)
    }
    #expect(session.notifications(method: "initialized").count == 1)
    #expect(session.closeCount == 1)
}

@Test func codexAppServerStopsAfterCompleteKnownBoundaryPage() async throws {
    let boundary = Date(timeIntervalSince1970: 1_000)
    let session = RecordingCodexRPCSession { method, params, callCount in
        switch method {
        case "initialize":
            return .object([:])
        case "thread/list":
            if params["archived"]?.boolValue == true {
                return .object(["data": .array([])])
            }
            switch callCount {
            case 1:
                return listPage(
                    summaries: [summary("newer", updatedAt: 1_010)],
                    nextCursor: "page-2"
                )
            case 2:
                return listPage(summaries: [
                    summary("equal", updatedAt: 1_000),
                    summary("older", updatedAt: 999),
                ], nextCursor: "must-not-be-read")
            default:
                Issue.record("Pagination continued after the known boundary")
                return .object(["data": .array([])])
            }
        case "thread/read":
            return threadResult(params["threadId"]?.stringValue ?? "missing")
        default:
            return .object([:])
        }
    }
    let server = CodexStdioAppServer(makeSession: { session })

    let threads = try await server.fetchThreads(since: boundary)

    #expect(threads.compactMap { $0.value["id"]?.stringValue } == ["newer", "equal"])
    let activeLists = session.requests(method: "thread/list").filter {
        $0.params["archived"]?.boolValue == false
    }
    #expect(activeLists.count == 2)
    #expect(activeLists.last?.params["cursor"]?.stringValue == "page-2")
    #expect(session.requests(method: "thread/read").count == 2)
}

@Test func codexAppServerContinuesWhenBoundarySuffixContainsUnknownDate() async throws {
    let boundary = Date(timeIntervalSince1970: 1_000)
    let session = RecordingCodexRPCSession { method, params, callCount in
        switch method {
        case "initialize":
            return .object([:])
        case "thread/list":
            if params["archived"]?.boolValue == true {
                return .object(["data": .array([])])
            }
            if callCount == 1 {
                return listPage(summaries: [
                    summary("older", updatedAt: 999),
                    .object(["id": .string("unknown")]),
                ], nextCursor: "page-2")
            }
            return listPage(summaries: [summary("next-candidate", updatedAt: 1_001)])
        case "thread/read":
            return threadResult(params["threadId"]?.stringValue ?? "missing")
        default:
            return .object([:])
        }
    }
    let server = CodexStdioAppServer(makeSession: { session })

    let threads = try await server.fetchThreads(since: boundary)

    #expect(threads.compactMap { $0.value["id"]?.stringValue } == [
        "unknown", "next-candidate",
    ])
    let activeLists = session.requests(method: "thread/list").filter {
        $0.params["archived"]?.boolValue == false
    }
    #expect(activeLists.count == 2)
}

@Test func codexAppServerIsolatesThreadReadFailureAndPreservesSuccesses() async throws {
    let session = RecordingCodexRPCSession { method, params, _ in
        switch method {
        case "initialize":
            return .object([:])
        case "thread/list":
            if params["archived"]?.boolValue == true {
                return .object(["data": .array([])])
            }
            return listPage(summaries: [
                summary("first", updatedAt: 3),
                summary("oversized", updatedAt: 2),
                summary("third", updatedAt: 1),
            ])
        case "thread/read":
            let id = params["threadId"]?.stringValue
            if id == "oversized" {
                throw ProviderKitError.malformedResponse(
                    "codex app-server response exceeded the safe limit"
                )
            }
            return threadResult(id ?? "missing")
        default:
            return .object([:])
        }
    }
    let server = CodexStdioAppServer(makeSession: { session })

    let threads = try await server.fetchThreads(since: nil)

    #expect(threads.compactMap { $0.value["id"]?.stringValue } == ["first", "third"])
    #expect(session.requests(method: "thread/read").compactMap {
        $0.params["threadId"]?.stringValue
    } == ["first", "oversized", "third"])
}

private final class RecordingCodexRPCSession: CodexAppServerRPCSession, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    typealias Handler = @Sendable (_ method: String, _ params: JSONValue, _ callCount: Int) throws -> JSONValue

    private let lock = NSLock()
    private let handler: Handler
    private var recordedRequests: [Request] = []
    private var recordedNotifications: [Request] = []
    private var methodCallCounts: [String: Int] = [:]
    private var recordedCloseCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func request(method: String, params: JSONValue, timeout: TimeInterval) throws -> JSONValue {
        let count = lock.withLock {
            recordedRequests.append(Request(method: method, params: params))
            methodCallCounts[method, default: 0] += 1
            return methodCallCounts[method] ?? 0
        }
        return try handler(method, params, count)
    }

    func notify(method: String, params: JSONValue) throws {
        lock.withLock {
            recordedNotifications.append(Request(method: method, params: params))
        }
    }

    func close() {
        lock.withLock { recordedCloseCount += 1 }
    }

    func requests(method: String) -> [Request] {
        lock.withLock { recordedRequests.filter { $0.method == method } }
    }

    func notifications(method: String) -> [Request] {
        lock.withLock { recordedNotifications.filter { $0.method == method } }
    }

    var closeCount: Int { lock.withLock { recordedCloseCount } }
}

private func summary(_ id: String, updatedAt: Double) -> JSONValue {
    .object(["id": .string(id), "updatedAt": .number(updatedAt)])
}

private func listPage(summaries: [JSONValue], nextCursor: String? = nil) -> JSONValue {
    var result: [String: JSONValue] = ["data": .array(summaries)]
    if let nextCursor { result["nextCursor"] = .string(nextCursor) }
    return .object(result)
}

private func threadResult(_ id: String) -> JSONValue {
    .object(["thread": .object(["id": .string(id), "turns": .array([])])])
}
