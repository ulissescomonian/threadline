@testable import ProviderKit
import ConversationCore
import Foundation
import Testing

@Test func codexChangedScopeParsesOnlyTheReportedTranscriptAndSkipsAppServer() async throws {
    try await withIncrementalTemporaryDirectory { root in
        let directory = root.appendingPathComponent(".codex/sessions/2026/07/24", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let changed = directory.appendingPathComponent("changed.jsonl")
        let untouched = directory.appendingPathComponent("untouched.jsonl")
        try writeIncrementalCodexRollout(to: changed, sessionID: "changed", text: "changed text")
        try writeIncrementalCodexRollout(to: untouched, sessionID: "untouched", text: "untouched text")
        let appServer = CountingAppServer()
        let adapter = CodexAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: LocalProcessRunner(),
            executableURL: nil,
            appServer: appServer
        )

        let conversations = try await collect(adapter, scope: .changed(paths: [changed]))
        #expect(conversations.map(\.summary.providerSessionID) == ["changed"])
        #expect(await appServer.callCount == 0)
    }
}

@Test func changedScopeWithNoProviderFilesIsANoOp() async throws {
    try await withIncrementalTemporaryDirectory { root in
        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: LocalProcessRunner(),
            executableURL: nil
        )
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("nothing".utf8).write(to: unrelated)
        #expect(try await collect(adapter, scope: .changed(paths: [unrelated])).isEmpty)
    }
}

@Test func fallbackFullScanDoesNotReparseUnchangedClaudeFiles() async throws {
    try await withIncrementalTemporaryDirectory { root in
        let directory = root.appendingPathComponent(".claude/projects/-tmp-incremental", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("stable.jsonl")
        try writeIncrementalClaudeTranscript(to: transcript, sessionID: "stable", text: "stable text")
        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: LocalProcessRunner(),
            executableURL: nil
        )

        let cursor = Date.distantPast
        #expect(try await collect(adapter, since: cursor, scope: .full()).count == 1)
        #expect(try await collect(adapter, since: cursor, scope: .full()).isEmpty)
    }
}

@Test func selectiveClaudeScanStaysBoundedWithManyUnchangedFiles() async throws {
    try await withIncrementalTemporaryDirectory { root in
        let directory = root.appendingPathComponent(".claude/projects/-tmp-scale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var changed: URL?
        for index in 0..<200 {
            let file = directory.appendingPathComponent("session-\(index).jsonl")
            try writeIncrementalClaudeTranscript(to: file, sessionID: "session-\(index)", text: "text \(index)")
            if index == 137 { changed = file }
        }
        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: LocalProcessRunner(),
            executableURL: nil
        )
        let target = try #require(changed)
        let conversations = try await collect(adapter, scope: .changed(paths: [target]))
        #expect(conversations.map(\.summary.providerSessionID) == ["session-137"])
    }
}

@Test func claudeParsingConcurrencyDropsUnderThermalPressure() {
    #expect(ClaudeAdapter.maximumConcurrentParses(for: .nominal) == 2)
    #expect(ClaudeAdapter.maximumConcurrentParses(for: .fair) == 2)
    #expect(ClaudeAdapter.maximumConcurrentParses(for: .serious) == 1)
    #expect(ClaudeAdapter.maximumConcurrentParses(for: .critical) == 1)
}

private func collect(
    _ adapter: any ProviderAdapter,
    since: Date? = nil,
    scope: ProviderIngestionScope
) async throws -> [ProviderConversation] {
    let collector = IncrementalCollector()
    try await adapter.scanConversations(since: since, scope: scope) { conversation in
        await collector.append(conversation)
    }
    return await collector.values
}

private actor IncrementalCollector {
    private var stored: [ProviderConversation] = []
    func append(_ conversation: ProviderConversation) { stored.append(conversation) }
    var values: [ProviderConversation] { stored }
}

private actor CountingAppServer: CodexAppServerProviding {
    private(set) var callCount = 0
    func fetchThreads(since: Date?) async throws -> [CodexAppServerThread] {
        callCount += 1
        return []
    }
}

private func writeIncrementalCodexRollout(to url: URL, sessionID: String, text: String) throws {
    let line = #"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"# + "\n" +
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"# + "\n"
    try Data(line.utf8).write(to: url)
}

private func writeIncrementalClaudeTranscript(to url: URL, sessionID: String, text: String) throws {
    let line = #"{"type":"user","sessionId":"\#(sessionID)","message":{"content":"\#(text)"}}"# + "\n"
    try Data(line.utf8).write(to: url)
}

private func withIncrementalTemporaryDirectory<T: Sendable>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threadline-provider-incremental-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}
