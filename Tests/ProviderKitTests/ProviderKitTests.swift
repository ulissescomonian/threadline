@testable import ProviderKit
import ConversationCore
import Foundation
import Testing

@Test func providerTruncationNeverExceedsItsCharacterBudget() {
    let source = "abcdef"

    #expect(source.providerTruncated(0).isEmpty)
    #expect(source.providerTruncated(1) == "…")
    #expect(source.providerTruncated(3) == "ab…")
    #expect(source.providerTruncated(3).count == 3)
    #expect(source.providerTruncated(6) == source)
}

@Test func environmentHonorsProviderRootsAndFindsExecutablesWithoutShell() throws {
    try withTemporaryDirectory { root in
        let binaries = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("codex")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let environment = ProviderEnvironment(
            homeDirectory: root,
            environment: [
                "CODEX_HOME": root.appendingPathComponent("custom-codex").path,
                "CLAUDE_CONFIG_DIR": "~/custom-claude",
                "PATH": binaries.path,
            ]
        )
        #expect(environment.codexHome.path == root.appendingPathComponent("custom-codex").path)
        #expect(environment.claudeHome.path == root.appendingPathComponent("custom-claude").path)
        #expect(environment.executable(named: "codex")?.path == executable.path)
        #expect(environment.executable(named: "../codex") == nil)
        #expect(environment.executableCandidates(named: "codex").contains {
            $0.path == "/Applications/ChatGPT.app/Contents/Resources/codex"
        })
        #expect(environment.executableCandidates(named: "claude").contains {
            $0.path == root.appendingPathComponent(".local/share/claude/ClaudeCode.app/Contents/MacOS/claude").path
        })
    }
}

@Test func stableHashIsDeterministic() {
    #expect(StableHash.sha256("threadline") == StableHash.sha256(Data("threadline".utf8)))
    #expect(StableHash.sha256("threadline").count == 64)
    #expect(StableHash.sha256("threadline") != StableHash.sha256("Threadline"))
}

@Test func processRunnerPassesArgumentsWithoutShellInterpretation() async throws {
    try await withTemporaryDirectory { root in
        let marker = root.appendingPathComponent("must-not-exist")
        let literal = "$(touch \(marker.path))"
        let result = try await LocalProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literal],
            environment: [:],
            timeout: 2,
            maximumOutputBytes: 4_096
        )
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == literal)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

@Test func processRunnerDrainsVerboseProcessAndTimesOutWithoutDeadlock() async {
    let started = Date()
    do {
        _ = try await LocalProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["threadline"],
            environment: [:],
            timeout: 0.15,
            maximumOutputBytes: 1_024
        )
        Issue.record("Expected the verbose process to time out")
    } catch let error as ProviderKitError {
        guard case .processTimedOut = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func oversizedRawPayloadIsOmittedWithMetadata() {
    var metadata: [String: String] = [:]
    let raw = Data(repeating: 0x61, count: 2_048)
    let retained = boundedRawPayload(raw, metadata: &metadata, maximumBytes: 1_024)
    #expect(retained == nil)
    #expect(metadata["rawPayloadOmitted"] == "true")
    #expect(metadata["rawPayloadBytes"] == "2048")
}

@Test func streamingReaderPreservesFoundationJSONScalarKinds() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("scalars.jsonl")
        try Data(#"{"flag":true,"count":42,"ratio":1.5,"name":"Threadline","empty":null,"items":[false,2]}"#.utf8)
            .write(to: file)

        var captured: JSONValue?
        _ = try StreamingJSONL.read(file) { value, _, _ in captured = value }

        #expect(captured?["flag"] == .bool(true))
        #expect(captured?["count"] == .number(42))
        #expect(captured?["ratio"] == .number(1.5))
        #expect(captured?["name"] == .string("Threadline"))
        #expect(captured?["empty"] == .null)
        #expect(captured?["items"] == .array([.bool(false), .number(2)]))
    }
}

@Test func streamingReaderDiscardsEntireOversizedLineAcrossChunks() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("oversized.jsonl")
        let oversized = #"{"value":""# + String(repeating: "x", count: 200) + #""}"#
        let valid = #"{"value":"after oversized line"}"#
        try Data((oversized + "\n" + valid + "\n").utf8).write(to: file)

        var omitted: [(Int64, Int)] = []
        var values: [String] = []
        let result = try StreamingJSONL.read(
            file,
            chunkSize: 17,
            maximumLineBytes: 32,
            onOversizedLine: { omitted.append(($0, $1)) }
        ) { value, _, _ in
            if let text = value["value"]?.stringValue { values.append(text) }
        }

        #expect(result.skippedLineCount == 1)
        #expect(omitted.count == 1)
        #expect(omitted[0].1 == oversized.utf8.count + 1)
        #expect(values == ["after oversized line"])
    }
}

@Test func streamingReaderSamplesHeadAndTailWithinStrictBudget() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("sampled.jsonl")
        let lines = (0..<100).map { index in
            #"{"value":"line-\#(String(format: "%03d", index))-\#(String(repeating: "x", count: 48))"}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: file.path
        )

        var values: [String] = []
        var gaps: [(Int64, Int64)] = []
        let first = try StreamingJSONL.read(
            file,
            chunkSize: 31,
            maximumFileBytes: 512,
            onTruncatedRegion: { gaps.append(($0, $1)) }
        ) { value, _, _ in
            if let text = value["value"]?.stringValue { values.append(text) }
        }

        #expect(first.isTruncated)
        #expect(first.bytesRead <= 512)
        #expect(first.omittedByteCount > 0)
        #expect(gaps.count == 1)
        #expect(gaps[0].1 == first.omittedByteCount)
        #expect(values.first?.hasPrefix("line-000-") == true)
        #expect(values.last?.hasPrefix("line-099-") == true)
        #expect(!values.contains { $0.hasPrefix("line-050-") })

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)],
            ofItemAtPath: file.path
        )
        let second = try StreamingJSONL.read(file, maximumFileBytes: 512) { _, _, _ in }
        #expect(second.fingerprint != first.fingerprint)
    }
}

@Test func streamingReaderPropagatesCancellationFromLineHandler() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("cancel.jsonl")
        try Data("{\"value\":1}\n{\"value\":2}\n".utf8).write(to: file)
        do {
            _ = try StreamingJSONL.read(file) { _, _, _ in
                throw CancellationError()
            }
            Issue.record("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: cancellation must never be downgraded to a malformed line.
        }
    }
}

@Test func boundedAccumulatorPreservesHeadAndTail() {
    var accumulator = BoundedImportAccumulator<Int>(budget: ImportBudget(
        maximumItems: 4,
        maximumTextBytes: 4,
        maximumRawBytes: 4
    ))
    for value in 0..<10 {
        accumulator.append(value, textBytes: 1, rawBytes: 1)
    }

    #expect(accumulator.headElements == [0, 1])
    #expect(accumulator.tailElements == [8, 9])
    #expect(accumulator.omittedItemCount == 6)
    #expect(accumulator.hasOmissions)
}

@Test func codexPrefersAppServerThreadHistory() async throws {
    try await withTemporaryDirectory { root in
        let environment = ProviderEnvironment(homeDirectory: root, environment: [:])
        let appServer = FixtureCodexAppServer(threads: [CodexAppServerThread(value: .object([
            "id": .string("app-session"),
            "cwd": .string("/tmp/sample-project"),
            "createdAt": .number(1_700_000_000),
            "turns": .array([.object([
                "items": .array([
                    .object(["type": .string("userMessage"), "text": .string("Inspect the fixture")]),
                    .object(["type": .string("agentMessage"), "text": .string("Fixture inspected")]),
                ]),
            ])]),
        ]))])
        let adapter = CodexAdapter(
            environment: environment,
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: URL(fileURLWithPath: "/fixture/codex"),
            appServer: appServer
        )

        let conversations = try await adapter.fetchConversations(since: nil)
        #expect(conversations.count == 1)
        #expect(conversations[0].summary.providerSessionID == "app-session")
        #expect(conversations[0].events.map(\.text) == ["Inspect the fixture", "Fixture inspected"])
        #expect(conversations[0].events.allSatisfy { $0.rawPayload == nil })
        #expect(conversations[0].sourceSchemaVersion == "codex-app-server-v3")
    }
}

@Test func codexReconcilesAppServerThreadsWithRolloutOnlySessions() async throws {
    try await withTemporaryDirectory { root in
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try writeCodexRollout(
            to: sessionDirectory.appendingPathComponent("shared.jsonl"),
            sessionID: "shared-session",
            userText: "rollout shared user",
            assistantText: "rollout shared answer"
        )
        try writeCodexRollout(
            to: sessionDirectory.appendingPathComponent("rollout-only.jsonl"),
            sessionID: "rollout-only-session",
            userText: "rollout only user",
            assistantText: "rollout only answer"
        )
        let adapter = CodexAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: URL(fileURLWithPath: "/fixture/codex"),
            appServer: FixtureCodexAppServer(threads: [codexAppServerThread(
                id: "shared-session",
                userText: "app-server shared user",
                assistantText: "app-server shared answer"
            )])
        )

        let conversations = try await adapter.fetchConversations(since: nil)
        let bySession = Dictionary(uniqueKeysWithValues: conversations.map {
            ($0.summary.providerSessionID, $0)
        })
        #expect(conversations.count == 2)
        #expect(bySession["shared-session"]?.sourceSchemaVersion == "codex-app-server-v3")
        #expect(bySession["shared-session"]?.events.map(\.text) == [
            "app-server shared user",
            "app-server shared answer",
        ])
        #expect(bySession["rollout-only-session"]?.sourceSchemaVersion == "codex-rollout-jsonl-v3")
        #expect(bySession["rollout-only-session"]?.events.contains { $0.text == "rollout only user" } == true)
    }
}

@Test func codexUsesRolloutsWhenAppServerReturnsAnEmptySuccess() async throws {
    try await withTemporaryDirectory { root in
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try writeCodexRollout(
            to: sessionDirectory.appendingPathComponent("local.jsonl"),
            sessionID: "local-session",
            userText: "local user",
            assistantText: "local answer"
        )
        let adapter = CodexAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: URL(fileURLWithPath: "/fixture/codex"),
            appServer: FixtureCodexAppServer(threads: [])
        )

        let conversations = try await adapter.fetchConversations(since: nil)
        #expect(conversations.count == 1)
        #expect(conversations[0].summary.providerSessionID == "local-session")
        #expect(conversations[0].sourceSchemaVersion == "codex-rollout-jsonl-v3")
    }
}

@Test func codexRolloutKeepsChildIdentityWhenParentMetadataAppearsLater() async throws {
    try await withTemporaryDirectory { root in
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("child-rollout.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"id":"child-session","cwd":"/tmp/child-project","timestamp":"2026-01-01T10:00:00.000Z"}}"#,
            #"{"type":"session_meta","payload":{"id":"parent-session","cwd":"/tmp/parent-project","timestamp":"2026-01-02T10:00:00.000Z"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"child request"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"child answer"}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
        let adapter = CodexAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil,
            appServer: FixtureCodexAppServer(threads: [])
        )

        let conversation = try #require(try await adapter.fetchConversations(since: nil).first)
        #expect(conversation.summary.providerSessionID == "child-session")
        #expect(conversation.summary.id == "codex:child-session")
        #expect(conversation.summary.project?.canonicalPath == "/tmp/child-project")
        #expect(conversation.events.map(\.text) == ["child request", "child answer"])
    }
}

@Test func codexDeduplicatesSourcesAndKeepsTheFirstAppServerRepresentation() async throws {
    try await withTemporaryDirectory { root in
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/01/01", isDirectory: true)
        let archivedDirectory = root.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)
        try writeCodexRollout(
            to: sessionDirectory.appendingPathComponent("duplicate-active.jsonl"),
            sessionID: "duplicate-session",
            userText: "active rollout",
            assistantText: "active rollout answer"
        )
        try writeCodexRollout(
            to: archivedDirectory.appendingPathComponent("duplicate-archived.jsonl"),
            sessionID: "duplicate-session",
            userText: "archived rollout",
            assistantText: "archived rollout answer"
        )
        let adapter = CodexAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: URL(fileURLWithPath: "/fixture/codex"),
            appServer: FixtureCodexAppServer(threads: [
                codexAppServerThread(
                    id: "duplicate-session",
                    userText: "preferred app-server user",
                    assistantText: "preferred app-server answer"
                ),
                codexAppServerThread(
                    id: "duplicate-session",
                    userText: "duplicate app-server user",
                    assistantText: "duplicate app-server answer"
                ),
            ])
        )

        let conversations = try await adapter.fetchConversations(since: nil)
        #expect(conversations.count == 1)
        #expect(conversations[0].sourceSchemaVersion == "codex-app-server-v3")
        #expect(conversations[0].events.map(\.text) == [
            "preferred app-server user",
            "preferred app-server answer",
        ])
    }
}

@Test func codexFallsBackToStreamingRolloutAndSkipsPartialLines() async throws {
    try await withTemporaryDirectory { root in
        let sessionDirectory = root.appendingPathComponent(".codex/sessions/2026/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("rollout-fixture.jsonl")
        let lines = [
            #"{"timestamp":"2026-01-01T10:00:00.000Z","type":"session_meta","payload":{"id":"codex-fixture","cwd":"/tmp/project"}}"#,
            #"{"timestamp":"2026-01-01T10:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Explain fixture"}}"#,
            #"{"timestamp":"2026-01-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Explain fixture"}]}}"#,
            #"{"timestamp":"2026-01-01T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixture answer"}]}}"#,
            #"{"timestamp":"2026-01-01T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"fixture_tool","arguments":"{}","call_id":"call-1"}}"#,
            #"{"incomplete":"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: transcript)

        let environment = ProviderEnvironment(homeDirectory: root, environment: [:])
        let adapter = CodexAdapter(
            environment: environment,
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil,
            appServer: ThrowingCodexAppServer()
        )
        let conversations = try await adapter.fetchConversations(since: nil)

        #expect(conversations.count == 1)
        #expect(conversations[0].summary.providerSessionID == "codex-fixture")
        #expect(conversations[0].events.filter { $0.role == .user }.count == 1)
        #expect(conversations[0].events.contains { $0.kind == .toolCall && $0.metadata["toolName"] == "fixture_tool" })
        #expect(conversations[0].summary.title == "Explain fixture")
    }
}

@Test func claudeReadsProjectTranscriptsButNeverAuthOrThinking() async throws {
    try await withTemporaryDirectory { root in
        let projectDirectory = root.appendingPathComponent(".claude/projects/-tmp-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory.appendingPathComponent("claude-fixture.jsonl")
        let lines = [
            #"{"type":"user","sessionId":"claude-fixture","uuid":"u1","cwd":"/tmp/fixture","timestamp":"2026-01-01T10:00:00.000Z","message":{"role":"user","content":"Create fixture"}}"#,
            #"{"type":"assistant","sessionId":"claude-fixture","uuid":"a1","parentUuid":"u1","timestamp":"2026-01-01T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden fixture reasoning"},{"type":"text","text":"Creating fixture"},{"type":"tool_use","id":"tool-1","name":"Write","input":{"file_path":"fixture.txt"}}]}}"#,
            #"{"type":"user","sessionId":"claude-fixture","uuid":"u2","timestamp":"2026-01-01T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}"#,
            #"{"type":"summary","sessionId":"claude-fixture","summary":"Fixture session"}"#,
            #"{"partial":"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: transcript)
        try Data(#"{"type":"user","message":{"content":"must not load"}}"#.utf8)
            .write(to: projectDirectory.appendingPathComponent("auth.jsonl"))

        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )
        let conversations = try await adapter.fetchConversations(since: nil)

        #expect(conversations.count == 1)
        #expect(conversations[0].summary.title == "Fixture session")
        #expect(conversations[0].events.contains { $0.kind == .toolCall && $0.metadata["toolName"] == "Write" })
        #expect(conversations[0].events.contains { $0.kind == .toolResult && $0.text == "ok" })
        #expect(!conversations[0].events.contains { $0.text.contains("hidden fixture reasoning") })
        #expect(!conversations[0].events.contains { $0.text.contains("must not load") })
    }
}

@Test func claudeNeverPersistsRawLinesContainingThinkingOrSignatures() async throws {
    try await withTemporaryDirectory { root in
        let projectDirectory = root.appendingPathComponent(".claude/projects/-tmp-private", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory.appendingPathComponent("private-session.jsonl")
        let thinkingSentinel = "PRIVATE-THINKING-SENTINEL"
        let signatureSentinel = "PRIVATE-SIGNATURE-SENTINEL"
        try writeJSONLines([
            #"{"type":"assistant","sessionId":"private-session","uuid":"private-event","message":{"content":[{"type":"thinking","thinking":"\#(thinkingSentinel)","signature":"\#(signatureSentinel)"},{"type":"text","text":"Visible answer"}]}}"#,
        ], to: transcript)
        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )

        let conversation = try #require(try await adapter.fetchConversations(since: nil).first)
        #expect(conversation.events.map(\.text) == ["Visible answer"])
        #expect(conversation.events.allSatisfy { event in
            guard let raw = event.rawPayload else { return true }
            let persisted = String(decoding: raw, as: UTF8.self)
            return !persisted.contains(thinkingSentinel) && !persisted.contains(signatureSentinel)
        })
        #expect(conversation.events.allSatisfy { $0.rawPayload == nil })
        #expect(!conversation.sourceFingerprint.isEmpty)
    }
}

@Test func claudePreservesMainAndCreatesStableDistinctSubagentConversations() async throws {
    try await withTemporaryDirectory { root in
        let projectDirectory = root.appendingPathComponent(".claude/projects/-tmp-fidelity", isDirectory: true)
        let parentSessionID = "parent-session"
        let subagentDirectory = projectDirectory
            .appendingPathComponent(parentSessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDirectory, withIntermediateDirectories: true)

        let main = projectDirectory.appendingPathComponent("\(parentSessionID).jsonl")
        try writeJSONLines([
            #"{"type":"user","sessionId":"parent-session","cwd":"/tmp/fidelity-project","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":"main request"}}"#,
            #"{"type":"assistant","sessionId":"parent-session","cwd":"/tmp/fidelity-project","timestamp":"2026-01-01T10:00:01.000Z","message":{"content":"main answer"}}"#,
        ], to: main)

        let alpha = subagentDirectory.appendingPathComponent("agent-alpha.jsonl")
        try writeJSONLines([
            #"{"type":"user","sessionId":"parent-session","agentId":"alpha","isSidechain":true,"cwd":"/tmp/fidelity-project","timestamp":"2026-01-01T10:01:00.000Z","message":{"content":"alpha request"}}"#,
            #"{"type":"assistant","sessionId":"replacement-parent","agentId":"replacement-agent","isSidechain":true,"cwd":"/tmp/replacement-project","timestamp":"2026-01-01T10:01:01.000Z","message":{"content":"alpha answer"}}"#,
        ], to: alpha)

        let beta = subagentDirectory.appendingPathComponent("agent-beta.jsonl")
        try writeJSONLines([
            #"{"type":"user","sessionId":"parent-session","agentId":"beta","isSidechain":true,"cwd":"/tmp/fidelity-project","timestamp":"2026-01-01T10:02:00.000Z","message":{"content":"beta request"}}"#,
            #"{"type":"assistant","sessionId":"parent-session","agentId":"beta","isSidechain":true,"timestamp":"2026-01-01T10:02:01.000Z","message":{"content":"beta answer"}}"#,
        ], to: beta)

        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )
        let first = try await adapter.fetchConversations(since: nil)
        let second = try await adapter.fetchConversations(since: nil)
        let expectedSessionIDs: Set<String> = [
            "parent-session",
            "parent-session:subagent:alpha",
            "parent-session:subagent:beta",
        ]

        #expect(first.count == 3)
        #expect(Set(first.map(\.summary.providerSessionID)) == expectedSessionIDs)
        #expect(first.map(\.summary.id).sorted() == second.map(\.summary.id).sorted())
        #expect(first.flatMap(\.events).map(\.id).sorted() == second.flatMap(\.events).map(\.id).sorted())

        let mainConversation = try #require(first.first {
            $0.summary.providerSessionID == "parent-session"
        })
        let alphaConversation = try #require(first.first {
            $0.summary.providerSessionID == "parent-session:subagent:alpha"
        })
        let betaConversation = try #require(first.first {
            $0.summary.providerSessionID == "parent-session:subagent:beta"
        })
        #expect(mainConversation.summary.id == "claude:parent-session")
        #expect(mainConversation.events.map(\.text) == ["main request", "main answer"])
        #expect(alphaConversation.summary.id == "claude:parent-session:subagent:alpha")
        #expect(alphaConversation.summary.project?.canonicalPath == "/tmp/fidelity-project")
        #expect(alphaConversation.events.map(\.text) == ["alpha request", "alpha answer"])
        #expect(betaConversation.summary.id == "claude:parent-session:subagent:beta")
        #expect(betaConversation.events.map(\.text) == ["beta request", "beta answer"])
        #expect(first.allSatisfy { conversation in
            conversation.events.allSatisfy { $0.conversationID == conversation.summary.id }
        })

        let fetchedWithConversationID = try await adapter.fetchConversation(
            id: "claude:parent-session:subagent:alpha"
        )
        let fetchedWithProviderID = try await adapter.fetchConversation(
            id: "parent-session:subagent:beta"
        )
        #expect(fetchedWithConversationID?.summary.id == alphaConversation.summary.id)
        #expect(fetchedWithProviderID?.summary.id == betaConversation.summary.id)
    }
}

@Test func claudeSubagentFallsBackToStableAgentFilenameWhenAgentIDIsMissing() async throws {
    try await withTemporaryDirectory { root in
        let subagentDirectory = root
            .appendingPathComponent(".claude/projects/-tmp-fallback/parent-fallback/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDirectory, withIntermediateDirectories: true)
        let transcript = subagentDirectory.appendingPathComponent("agent-file-fallback.jsonl")
        try writeJSONLines([
            #"{"type":"user","sessionId":"parent-fallback","isSidechain":true,"cwd":"/tmp/fallback-project","message":{"content":"fallback request"}}"#,
            #"{"type":"assistant","sessionId":"different-parent","isSidechain":true,"message":{"content":"fallback answer"}}"#,
        ], to: transcript)
        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )

        let first = try #require(try await adapter.fetchConversations(since: nil).first)
        let second = try #require(try await adapter.fetchConversations(since: nil).first)
        #expect(first.summary.providerSessionID == "parent-fallback:subagent:file-fallback")
        #expect(first.summary.id == "claude:parent-fallback:subagent:file-fallback")
        #expect(first.summary.id == second.summary.id)
        #expect(first.events.map(\.id) == second.events.map(\.id))
        #expect(first.summary.project?.canonicalPath == "/tmp/fallback-project")
    }
}

@Test func claudeScanYieldsNewestConversationBeforeContinuing() async throws {
    try await withTemporaryDirectory { root in
        let projectDirectory = root.appendingPathComponent(".claude/projects/-tmp-incremental", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let older = projectDirectory.appendingPathComponent("older.jsonl")
        let newer = projectDirectory.appendingPathComponent("newer.jsonl")
        let olderLines = (0..<4_005).map { index in
            #"{"type":"user","sessionId":"older","timestamp":"2026-07-20T12:34:56.789Z","message":{"content":"older-\#(index)"}}"#
        }
        let newerLines = (0..<4_005).map { index in
            #"{"type":"user","sessionId":"newer","timestamp":"2026-07-20T12:34:56.789Z","message":{"content":"newer-\#(index)"}}"#
        }
        try writeJSONLines(olderLines, to: older)
        try writeJSONLines(newerLines, to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )

        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )
        let recorder = YieldRecorder()
        try await adapter.scanConversations(since: nil) { conversation in
            await recorder.append(conversation.summary.providerSessionID)
        }
        #expect(await recorder.values == ["newer", "older"])
    }
}

@Test func claudeLargeTranscriptPreservesHeadTailAndExplicitGapMarker() async throws {
    try await withTemporaryDirectory { root in
        let projectDirectory = root.appendingPathComponent(".claude/projects/-tmp-large", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory.appendingPathComponent("large.jsonl")
        var payload = Data(#"{"type":"user","sessionId":"large","message":{"content":"head-message"}}"#.utf8)
        payload.append(0x0A)
        payload.append(Data(#"{"ignored":""#.utf8))
        payload.append(Data(repeating: 0x78, count: 9 * 1_024 * 1_024))
        payload.append(Data(#""}"#.utf8))
        payload.append(0x0A)
        payload.append(Data(#"{"type":"assistant","sessionId":"large","message":{"content":"tail-message"}}"#.utf8))
        payload.append(0x0A)
        try payload.write(to: transcript)

        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )
        let conversations = try await adapter.fetchConversations(since: nil)
        let conversation = try #require(conversations.first)

        #expect(conversation.sourceSchemaVersion == "claude-project-jsonl-sampled-v3")
        #expect(conversation.events.contains { $0.text == "head-message" })
        #expect(conversation.events.contains { $0.text == "tail-message" })
        #expect(conversation.events.contains { $0.metadata["payloadOmitted"] == "file-sampling" })
    }
}

@Test func claudeEventBudgetKeepsHeadAndTailWithMarker() async throws {
    try await withTemporaryDirectory { root in
        let projectDirectory = root.appendingPathComponent(".claude/projects/-tmp-bounded", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory.appendingPathComponent("bounded.jsonl")
        let lines = (0..<4_005).map { index in
            #"{"type":"user","sessionId":"bounded","timestamp":"2026-07-20T12:34:56.789Z","message":{"content":"event-\#(index)"}}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let adapter = ClaudeAdapter(
            environment: ProviderEnvironment(homeDirectory: root, environment: [:]),
            deviceID: "test-device",
            processRunner: FixtureProcessRunner(),
            executableURL: nil
        )
        let conversation = try #require(try await adapter.fetchConversations(since: nil).first)

        #expect(conversation.events.count == ProviderImportLimits.maximumEventsPerConversation + 1)
        #expect(conversation.events.contains { $0.text == "event-0" })
        #expect(conversation.events.contains { $0.text == "event-4004" })
        #expect(conversation.events.contains { $0.metadata["payloadOmitted"] == "conversation-budget" })
    }
}

@Test func registryExposesBothDefaultProviders() {
    let registry = ProviderFactory.makeDefault(
        environment: ProviderEnvironment(homeDirectory: URL(fileURLWithPath: "/tmp/fixture-home"), environment: [:]),
        deviceID: "test-device",
        processRunner: FixtureProcessRunner()
    )
    #expect(registry.availableKinds == [.codex, .claude])
    #expect(registry.adapter(for: .codex) != nil)
    #expect(registry.adapter(for: .claude) != nil)
}

private struct FixtureProcessRunner: ProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> ProcessResult {
        ProcessResult(status: 0, standardOutput: Data("fixture 1.0\n".utf8), standardError: Data())
    }
}

private struct FixtureCodexAppServer: CodexAppServerProviding {
    let threads: [CodexAppServerThread]
    func fetchThreads(since: Date?) async throws -> [CodexAppServerThread] { threads }
}

private struct ThrowingCodexAppServer: CodexAppServerProviding {
    func fetchThreads(since: Date?) async throws -> [CodexAppServerThread] {
        throw ProviderKitError.malformedResponse("fixture forces fallback")
    }
}

private func codexAppServerThread(
    id: String,
    userText: String,
    assistantText: String
) -> CodexAppServerThread {
    CodexAppServerThread(value: .object([
        "id": .string(id),
        "cwd": .string("/tmp/sample-project"),
        "createdAt": .number(1_700_000_000),
        "turns": .array([.object([
            "items": .array([
                .object(["type": .string("userMessage"), "text": .string(userText)]),
                .object(["type": .string("agentMessage"), "text": .string(assistantText)]),
            ]),
        ])]),
    ]))
}

private func writeCodexRollout(
    to url: URL,
    sessionID: String,
    userText: String,
    assistantText: String
) throws {
    let lines = [
        #"{"timestamp":"2026-01-01T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/tmp/sample-project"}}"#,
        #"{"timestamp":"2026-01-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(userText)"}]}}"#,
        #"{"timestamp":"2026-01-01T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(assistantText)"}]}}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

private actor YieldRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private func writeJSONLines(_ lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

private func withTemporaryDirectory<T: Sendable>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}
