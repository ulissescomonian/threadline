@testable import ProviderKit
import ConversationCore
import Foundation
import Testing

@Test func codexSemanticFingerprintIgnoresTransientAppServerFields() async throws {
    try await withSemanticTemporaryDirectory { root in
        let first = try #require(try await semanticConversation(
            root: root,
            thread: semanticThread(transientRevision: 1)
        ))
        let second = try #require(try await semanticConversation(
            root: root,
            thread: semanticThread(transientRevision: 2)
        ))

        #expect(first.sourceFingerprint == second.sourceFingerprint)
        #expect(first.summary == second.summary)
        #expect(first.events == second.events)
    }
}

@Test func codexSemanticFingerprintChangesWithPersistedConversationContent() async throws {
    try await withSemanticTemporaryDirectory { root in
        let base = try #require(try await semanticConversation(
            root: root,
            thread: semanticThread()
        ))
        let mutations = [
            semanticThread(assistantText: "A materially different answer"),
            semanticThread(command: ["swift", "test", "--parallel"]),
            semanticThread(commandOutput: "A changed test result"),
            semanticThread(cwd: "/tmp/a-different-project"),
            semanticThread(assistantCreatedAt: "2026-07-20T15:05:30.000Z"),
        ]

        for mutation in mutations {
            let changed = try #require(try await semanticConversation(root: root, thread: mutation))
            #expect(changed.sourceFingerprint != base.sourceFingerprint)
        }
    }
}

@Test func codexAppServerTimestampFallbackUsesMostSpecificNormalizedTimestamp() async throws {
    try await withSemanticTemporaryDirectory { root in
        let thread = CodexAppServerThread(value: .object([
            "id": .string("timestamp-session"),
            "cwd": .string("/tmp/timestamp-project"),
            "createdAt": .string("2026-07-20T15:00:00.000Z"),
            "turns": .array([
                .object([
                    "startedAt": .string("2026-07-20T15:01:00.000Z"),
                    "createdAt": .string("2026-07-20T15:02:00.000Z"),
                    "items": .array([
                        .object([
                            "type": .string("userMessage"),
                            "text": .string("item createdAt wins"),
                            "startedAt": .string("2026-07-20T15:03:00.000Z"),
                            "createdAt": .string("2026-07-20T15:04:00.000Z"),
                        ]),
                        .object([
                            "type": .string("agentMessage"),
                            "text": .string("item startedAt is the next fallback"),
                            "startedAt": .string("2026-07-20T15:05:00.000Z"),
                        ]),
                        .object([
                            "type": .string("commandExecution"),
                            "command": .array([.string("pwd")]),
                        ]),
                    ]),
                ]),
                .object([
                    "createdAt": .string("2026-07-20T15:06:00.000Z"),
                    "items": .array([.object([
                        "type": .string("userMessage"),
                        "text": .string("turn createdAt fallback"),
                    ])]),
                ]),
                .object([
                    "items": .array([.object([
                        "type": .string("agentMessage"),
                        "text": .string("thread createdAt fallback"),
                    ])]),
                ]),
            ]),
        ]))
        let conversation = try #require(try await semanticConversation(root: root, thread: thread))
        let expected = [
            "2026-07-20T15:04:00.000Z",
            "2026-07-20T15:05:00.000Z",
            "2026-07-20T15:01:00.000Z",
            "2026-07-20T15:06:00.000Z",
            "2026-07-20T15:00:00.000Z",
        ].compactMap { ProviderDates.parse(.string($0)) }

        #expect(conversation.events.map(\.timestamp) == expected)
    }
}

@Test func transientAppServerRefreshDoesNotRequeueButContentChangeDoes() async throws {
    try await withSemanticTemporaryDirectory { root in
        let store = try SQLiteConversationStore(
            databaseURL: root.appendingPathComponent("Threadline.sqlite"),
            deviceID: "semantic-device",
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: true
        )
        try await store.migrate()

        let initial = try #require(try await semanticConversation(
            root: root,
            thread: semanticThread(transientRevision: 1)
        ))
        try await store.upsert(initial)
        let initialPending = try await store.pendingEnvelopes(limit: 10)
        #expect(initialPending.count == 1)
        try await store.markEnvelopesAcknowledged(ids: initialPending.map(\.id))

        let transientRefresh = try #require(try await semanticConversation(
            root: root,
            thread: semanticThread(transientRevision: 2),
            since: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await store.upsert(transientRefresh)
        #expect(try await store.pendingEnvelopes(limit: 10).isEmpty)

        let contentChange = try #require(try await semanticConversation(
            root: root,
            thread: semanticThread(
                transientRevision: 3,
                assistantText: "New durable answer"
            ),
            since: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        try await store.upsert(contentChange)
        let changedPending = try await store.pendingEnvelopes(limit: 10)
        let changedEnvelope = try #require(changedPending.first)
        let changedConversation = try PlaintextEnvelopeCodec().open(changedEnvelope)

        #expect(changedPending.count == 1)
        #expect(changedConversation.events.contains { $0.text == "New durable answer" })
    }
}

private struct SemanticFixtureAppServer: CodexAppServerProviding {
    let thread: CodexAppServerThread

    func fetchThreads(since: Date?) async throws -> [CodexAppServerThread] {
        [thread]
    }
}

private func semanticConversation(
    root: URL,
    thread: CodexAppServerThread,
    since: Date? = nil
) async throws -> ProviderConversation? {
    let adapter = CodexAdapter(
        environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
        deviceID: "semantic-device",
        processRunner: LocalProcessRunner(),
        executableURL: nil,
        appServer: SemanticFixtureAppServer(thread: thread)
    )
    return try await adapter.fetchConversations(since: since).first
}

private func semanticThread(
    transientRevision: Int = 1,
    assistantText: String = "Stable answer",
    command: [String] = ["swift", "test"],
    commandOutput: String = "All tests passed",
    cwd: String = "/tmp/semantic-project",
    assistantCreatedAt: String = "2026-07-20T15:05:00.000Z"
) -> CodexAppServerThread {
    CodexAppServerThread(value: .object([
        "id": .string("semantic-session"),
        "cwd": .string(cwd),
        "createdAt": .string("2026-07-20T15:00:00.000Z"),
        "updatedAt": .string("2026-07-20T16:0\(transientRevision):00.000Z"),
        "recencyAt": .number(Double(10_000 + transientRevision)),
        "status": .string(transientRevision.isMultiple(of: 2) ? "idle" : "active"),
        "archived": .bool(transientRevision.isMultiple(of: 2)),
        "preview": .string("Transient preview \(transientRevision)"),
        "tokenUsage": .object([
            "inputTokens": .number(Double(transientRevision * 1_000)),
            "outputTokens": .number(Double(transientRevision * 2_000)),
        ]),
        "gitInfo": .object([
            "dirty": .bool(transientRevision.isMultiple(of: 2)),
            "observedAt": .number(Double(transientRevision)),
        ]),
        "unknownFutureTelemetry": .string("revision-\(transientRevision)"),
        "turns": .array([.object([
            "createdAt": .string("2026-07-20T15:01:00.000Z"),
            "status": .string("transient-turn-\(transientRevision)"),
            "items": .array([
                .object([
                    "type": .string("userMessage"),
                    "text": .string("Stable request"),
                    "createdAt": .string("2026-07-20T15:02:00.000Z"),
                    "status": .string("transient-item-\(transientRevision)"),
                ]),
                .object([
                    "type": .string("agentMessage"),
                    "text": .string(assistantText),
                    "createdAt": .string(assistantCreatedAt),
                    "tokenUsage": .number(Double(transientRevision * 500)),
                ]),
                .object([
                    "type": .string("commandExecution"),
                    "command": .array(command.map(JSONValue.string)),
                    "aggregatedOutput": .string(commandOutput),
                    "createdAt": .string("2026-07-20T15:06:00.000Z"),
                    "status": .string("completed-\(transientRevision)"),
                ]),
            ]),
        ])]),
    ]))
}

private func withSemanticTemporaryDirectory<T: Sendable>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ThreadlineSemanticFingerprintTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}
