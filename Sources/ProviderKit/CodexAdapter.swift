import ConversationCore
import Foundation

public struct CodexAdapter: ProviderAdapter, Sendable {
    public let kind: ProviderKind = .codex

    private let environment: ProviderEnvironment
    private let deviceID: String
    private let processRunner: any ProcessRunning
    private let executableURL: URL?
    private let appServer: (any CodexAppServerProviding)?

    public init(
        environment: ProviderEnvironment = ProviderEnvironment(),
        deviceID: String? = nil,
        processRunner: any ProcessRunning = LocalProcessRunner(),
        executableURL: URL? = nil
    ) {
        self.environment = environment
        self.deviceID = deviceID ?? StableHash.sha256(ProcessInfo.processInfo.hostName).prefix(16).description
        self.processRunner = processRunner
        let resolved = executableURL ?? environment.executable(named: "codex")
        self.executableURL = resolved
        appServer = resolved.map { CodexStdioAppServer(executableURL: $0) }
    }

    init(
        environment: ProviderEnvironment,
        deviceID: String,
        processRunner: any ProcessRunning,
        executableURL: URL?,
        appServer: (any CodexAppServerProviding)?
    ) {
        self.environment = environment
        self.deviceID = deviceID
        self.processRunner = processRunner
        self.executableURL = executableURL
        self.appServer = appServer
    }

    public func discoverSources() async -> [ProviderSource] {
        let root = environment.codexHome
        let exists = FileManager.default.fileExists(atPath: root.path)
        let version = await executableVersion()
        return [ProviderSource(
            id: "codex:\(StableHash.sha256(root.path).prefix(20))",
            provider: .codex,
            rootPath: root.path,
            displayName: "Codex",
            version: version,
            isAvailable: exists || executableURL != nil
        )]
    }

    public func fetchConversations(since: Date?) async throws -> [ProviderConversation] {
        let collector = ProviderConversationCollector()
        try await scanConversations(since: since) { conversation in
            await collector.append(conversation)
        }
        return await collector.conversations().sorted { $0.summary.updatedAt > $1.summary.updatedAt }
    }

    public func scanConversations(
        since: Date?,
        yield: @escaping @Sendable (ProviderConversation) async throws -> Void
    ) async throws {
        var emittedSessionIDs = Set<String>()
        if let appServer {
            let threads: [CodexAppServerThread]?
            do {
                threads = try await appServer.fetchThreads(since: since)
            } catch {
                if error is CancellationError { throw error }
                threads = nil
                // Version drift, a locked CLI, or an uninitialized state DB must not make history unavailable.
            }
            if let threads {
                for thread in threads {
                    try Task.checkCancellation()
                    guard let conversation = parseAppServerThread(thread.value),
                          emittedSessionIDs.insert(conversation.summary.providerSessionID).inserted
                    else { continue }
                    try await yield(conversation)
                }
            }
        }
        for file in rolloutFiles(since: since) {
            try Task.checkCancellation()
            let conversation = parseRolloutFile(file)
            // The synchronous JSONL parser checks cancellation between chunks.
            // It deliberately converts malformed-file failures into a skipped
            // conversation, so re-check here to keep cancellation distinct and
            // prevent the caller from promoting an incomplete provider cursor.
            try Task.checkCancellation()
            guard let conversation,
                  emittedSessionIDs.insert(conversation.summary.providerSessionID).inserted
            else { continue }
            try await yield(conversation)
        }
    }

    public func fetchConversation(id: String) async throws -> ProviderConversation? {
        let normalized = id.hasPrefix("codex:") ? String(id.dropFirst("codex:".count)) : id
        let all = try await fetchConversations(since: nil)
        return all.first { $0.summary.id == id || $0.summary.providerSessionID == normalized }
    }

    private func executableVersion() async -> String? {
        guard let executableURL else { return nil }
        guard let result = try? await processRunner.run(
            executable: executableURL,
            arguments: ["--version"],
            environment: nil,
            timeout: 3,
            maximumOutputBytes: 4_096
        ) else { return nil }
        return String(decoding: result.standardOutput, as: UTF8.self).providerTrimmed.nilIfEmpty
    }

    private func rolloutFiles(since: Date?) -> [URL] {
        let roots = [
            environment.codexHome.appendingPathComponent("sessions", isDirectory: true),
            environment.codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        return roots.flatMap { ProviderFiles.jsonlFiles(below: $0) }
            .filter { file in
                guard let since else { return true }
                return (ProviderFiles.modificationDate(file) ?? .distantPast) >= since
            }
            .sorted(by: ProviderFiles.importPriority)
    }

    private func parseRolloutFile(_ url: URL) -> ProviderConversation? {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var createdAt = ProviderFiles.modificationDate(url) ?? .distantPast
        var capturedSessionMetadata = false
        var events = BoundedImportAccumulator<CodexDraft>()

        let result: JSONLReadResult
        do {
            result = try StreamingJSONL.read(
                url,
                maximumFileBytes: ProviderImportLimits.maximumJSONLBytes,
                onOversizedLine: { offset, byteCount in
                appendCodexDraft(CodexDraft(
                    timestamp: ProviderFiles.modificationDate(url) ?? createdAt,
                    kind: .unknown,
                    role: .system,
                    text: "Oversized Codex event omitted",
                    metadata: ["payloadOmitted": "true", "sourceBytes": String(byteCount)],
                    raw: nil,
                    offset: offset,
                    source: "rollout-jsonl"
                ), to: &events)
            }, onTruncatedRegion: { offset, byteCount in
                appendCodexDraft(CodexDraft(
                    timestamp: ProviderFiles.modificationDate(url) ?? createdAt,
                    kind: .unknown,
                    role: .system,
                    text: "A middle section of this large Codex transcript was omitted",
                    metadata: [
                        "payloadOmitted": "file-sampling",
                        "omittedBytes": String(byteCount),
                    ],
                    raw: nil,
                    offset: offset,
                    source: "threadline-sampling"
                ), to: &events)
            }) { value, raw, offset in
                let timestamp = ProviderDates.parse(value["timestamp"]) ?? createdAt
                let outerType = value["type"]?.stringValue ?? "unknown"
                let payload = value["payload"] ?? value

                if outerType == "session_meta" {
                    let candidateID = (
                        payload["id"]?.stringValue ?? payload["session_id"]?.stringValue
                    )?.providerTrimmed
                    if !capturedSessionMetadata,
                       let candidateID,
                       !candidateID.isEmpty {
                        // Subagent rollouts can embed a later copy of the
                        // parent's session metadata. A file's identity belongs
                        // to its first valid metadata record and is immutable.
                        sessionID = candidateID
                        cwd = payload["cwd"]?.stringValue
                        createdAt = ProviderDates.parse(payload["timestamp"]) ?? timestamp
                        capturedSessionMetadata = true
                    }
                    return
                }

                for draft in codexDrafts(outerType: outerType, payload: payload, timestamp: timestamp, raw: raw, offset: offset) {
                    appendCodexDraft(draft, to: &events)
                }
            }
        } catch {
            return nil
        }

        var boundedEvents = events.headElements
        if events.hasOmissions {
            boundedEvents.append(CodexDraft(
                timestamp: boundedEvents.last?.timestamp ?? createdAt,
                kind: .unknown,
                role: .system,
                text: "A middle section of Codex events was omitted to keep this conversation responsive",
                metadata: [
                    "payloadOmitted": "conversation-budget",
                    "omittedEventCount": String(events.omittedItemCount),
                    "omittedTextBytes": String(events.omittedTextBytes),
                    "omittedRawBytes": String(events.omittedRawBytes),
                ],
                raw: nil,
                offset: boundedEvents.last?.offset ?? 0,
                source: "threadline-limit"
            ))
        }
        boundedEvents.append(contentsOf: events.tailElements)
        boundedEvents = removeDuplicatedEventMessages(boundedEvents)
        guard !boundedEvents.isEmpty else { return nil }
        return makeConversation(
            sessionID: sessionID,
            cwd: cwd,
            createdAt: createdAt,
            drafts: boundedEvents,
            fingerprint: result.fingerprint,
            schema: result.isTruncated ? "codex-rollout-jsonl-sampled-v3" : "codex-rollout-jsonl-v3"
        )
    }

    private func parseAppServerThread(_ thread: JSONValue) -> ProviderConversation? {
        guard let sessionID = thread["id"]?.stringValue else { return nil }
        let cwd = thread["cwd"]?.stringValue
        let createdAt = ProviderDates.parse(thread["createdAt"]) ?? .distantPast
        var drafts = BoundedImportAccumulator<CodexDraft>()
        var ordinal: Int64 = 0
        for turn in thread["turns"]?.arrayValue ?? [] {
            let turnTimestamp = ProviderDates.parse(turn["startedAt"])
                ?? ProviderDates.parse(turn["createdAt"])
                ?? createdAt
            for item in turn["items"]?.arrayValue ?? [] {
                let itemTimestamp = ProviderDates.parse(item["createdAt"])
                    ?? ProviderDates.parse(item["startedAt"])
                    ?? turnTimestamp
                for draft in appServerDrafts(
                    item: item,
                    timestamp: itemTimestamp,
                    ordinal: &ordinal
                ) {
                    appendCodexDraft(draft, to: &drafts)
                }
            }
        }
        var boundedDrafts = drafts.headElements
        if drafts.hasOmissions {
            boundedDrafts.append(CodexDraft(
                timestamp: boundedDrafts.last?.timestamp ?? createdAt,
                kind: .unknown,
                role: .system,
                text: "A middle section of Codex events was omitted to keep this conversation responsive",
                metadata: ["payloadOmitted": "conversation-budget", "omittedEventCount": String(drafts.omittedItemCount)],
                raw: nil,
                offset: boundedDrafts.last?.offset ?? 0,
                source: "threadline-limit"
            ))
        }
        boundedDrafts.append(contentsOf: drafts.tailElements)
        guard !boundedDrafts.isEmpty else { return nil }
        return makeConversation(
            sessionID: sessionID,
            cwd: cwd,
            createdAt: createdAt,
            drafts: boundedDrafts,
            fingerprint: semanticAppServerFingerprint(
                sessionID: sessionID,
                cwd: cwd,
                drafts: boundedDrafts
            ),
            schema: "codex-app-server-v3"
        )
    }

    private func semanticAppServerFingerprint(
        sessionID: String,
        cwd: String?,
        drafts: [CodexDraft]
    ) -> String {
        let events = drafts.map { draft in
            CodexSemanticEvent(
                offset: draft.offset,
                timestampBitPattern: draft.timestamp.timeIntervalSince1970.bitPattern,
                kind: draft.kind.rawValue,
                role: draft.role.rawValue,
                text: draft.text,
                metadata: draft.metadata.merging(
                    ["source": draft.source],
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        let snapshot = CodexSemanticSnapshot(
            format: "threadline-codex-app-server-semantic-v1",
            sessionID: sessionID,
            projectPath: canonicalProjectPath(cwd),
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(snapshot) else {
            // Every field above is a bounded Foundation scalar. Keep a
            // deterministic fallback without returning to the provider's
            // transient response object.
            let fallback = ([snapshot.format, sessionID, snapshot.projectPath ?? ""] + events.flatMap {
                [
                    String($0.offset), String($0.timestampBitPattern), $0.kind, $0.role, $0.text,
                ] + $0.metadata.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
            }).map { "\($0.utf8.count):\($0)" }.joined()
            return StableHash.sha256(fallback)
        }
        return StableHash.sha256(encoded)
    }

    private func makeConversation(
        sessionID: String,
        cwd: String?,
        createdAt: Date,
        drafts: [CodexDraft],
        fingerprint: String,
        schema: String
    ) -> ProviderConversation {
        let conversationID = "codex:\(sessionID)"
        let ordered = drafts.enumerated().map { index, draft in
            let metadata = draft.metadata.merging(["source": draft.source], uniquingKeysWith: { first, _ in first })
            let hashInput = "\(draft.kind.rawValue)|\(draft.role.rawValue)|\(draft.text)|\(metadata.sorted { $0.key < $1.key })"
            let contentHash = StableHash.sha256(hashInput)
            return ConversationEvent(
                id: "codex-event:\(StableHash.sha256("\(sessionID)|\(draft.offset)|\(contentHash)").prefix(32))",
                conversationID: conversationID,
                sequence: Int64(index),
                timestamp: draft.timestamp,
                kind: draft.kind,
                role: draft.role,
                text: draft.text,
                metadata: metadata,
                // Threadline renders and synchronizes the normalized text and
                // metadata. Keeping the complete provider line only duplicates
                // private data and dramatically inflates SQLite and outbox rows.
                rawPayload: nil,
                contentHash: contentHash,
                sourceDeviceID: deviceID
            )
        }
        let firstUser = ordered.first { $0.role == .user && !$0.text.providerTrimmed.isEmpty }?.text.providerTrimmed
        let preview = ordered.last { ($0.role == .user || $0.role == .assistant) && !$0.text.providerTrimmed.isEmpty }?.text.providerTrimmed ?? ""
        let timestamps = ordered.map(\.timestamp)
        let project = makeProject(cwd)
        let summary = ConversationSummary(
            id: conversationID,
            provider: .codex,
            providerSessionID: sessionID,
            title: (firstUser ?? "Codex conversation").replacingOccurrences(of: "\n", with: " ").providerTruncated(120),
            preview: preview.replacingOccurrences(of: "\n", with: " ").providerTruncated(240),
            project: project,
            createdAt: timestamps.min() ?? createdAt,
            updatedAt: timestamps.max() ?? createdAt,
            status: .idle,
            syncAvailability: .localOnly,
            originDeviceID: deviceID,
            messageCount: ordered.filter { $0.role == .user || $0.role == .assistant }.count
        )
        return ProviderConversation(summary: summary, events: ordered, sourceFingerprint: fingerprint, sourceSchemaVersion: schema)
    }

    private func makeProject(_ cwd: String?) -> ProjectIdentity? {
        guard let canonicalPath = canonicalProjectPath(cwd) else { return nil }
        let url = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        return ProjectIdentity(
            id: "project:\(StableHash.sha256(canonicalPath).prefix(24))",
            displayName: url.lastPathComponent,
            canonicalPath: canonicalPath
        )
    }

    private func canonicalProjectPath(_ cwd: String?) -> String? {
        guard let cwd = cwd?.providerTrimmed, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
    }
}

private struct CodexSemanticSnapshot: Encodable {
    let format: String
    let sessionID: String
    let projectPath: String?
    let events: [CodexSemanticEvent]
}

private struct CodexSemanticEvent: Encodable {
    let offset: Int64
    let timestampBitPattern: UInt64
    let kind: String
    let role: String
    let text: String
    let metadata: [String: String]
}

private func appendCodexDraft(
    _ draft: CodexDraft,
    to accumulator: inout BoundedImportAccumulator<CodexDraft>
) {
    var metadata = draft.metadata
    let sourceCharacterCount = draft.text.count
    let text = draft.text.providerTruncated(ProviderImportLimits.maximumTextCharactersPerEvent)
    if text.count < sourceCharacterCount {
        metadata["textOmitted"] = "event-budget"
        metadata["sourceCharacterCount"] = String(sourceCharacterCount)
    }
    let raw = boundedRawPayload(draft.raw, metadata: &metadata)
    let bounded = CodexDraft(
        timestamp: draft.timestamp,
        kind: draft.kind,
        role: draft.role,
        text: text,
        metadata: metadata,
        raw: raw,
        offset: draft.offset,
        source: draft.source
    )
    accumulator.append(bounded, textBytes: text.utf8.count, rawBytes: raw?.count ?? 0)
}

private struct CodexDraft {
    let timestamp: Date
    let kind: EventKind
    let role: MessageRole
    let text: String
    let metadata: [String: String]
    let raw: Data?
    let offset: Int64
    let source: String
}

private func codexDrafts(outerType: String, payload: JSONValue, timestamp: Date, raw: Data, offset: Int64) -> [CodexDraft] {
    _ = raw
    let payloadType = payload["type"]?.stringValue ?? outerType
    let base = { (kind: EventKind, role: MessageRole, text: String, metadata: [String: String]) in
        CodexDraft(timestamp: timestamp, kind: kind, role: role, text: text, metadata: metadata, raw: nil, offset: offset, source: outerType)
    }

    if outerType == "response_item" {
        switch payloadType {
        case "message":
            let role = messageRole(payload["role"]?.stringValue)
            let text = textContent(payload["content"])
            return text.providerTrimmed.isEmpty ? [] : [base(eventKind(role), role, text, ["itemType": payloadType])]
        case "function_call", "custom_tool_call":
            let name = payload["name"]?.stringValue ?? payload["tool_name"]?.stringValue ?? "Tool"
            let arguments = payload["arguments"]?.compactString ?? payload["input"]?.compactString ?? ""
            return [base(.toolCall, .tool, arguments, ["toolName": name, "callID": payload["call_id"]?.stringValue ?? ""])]
        case "function_call_output", "custom_tool_call_output":
            return [base(.toolResult, .tool, payload["output"]?.compactString ?? "", ["callID": payload["call_id"]?.stringValue ?? ""])]
        case "local_shell_call", "shell_call":
            let command = payload["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? payload["command"]?.compactString ?? ""
            return command.isEmpty ? [] : [base(.command, .tool, command, [:])]
        case "compaction":
            return [base(.compaction, .system, payload["summary"]?.compactString ?? "Conversation compacted", [:])]
        default:
            return []
        }
    }

    if outerType == "event_msg" {
        switch payloadType {
        case "user_message":
            let text = payload["message"]?.stringValue ?? textContent(payload["content"])
            return text.providerTrimmed.isEmpty ? [] : [base(.userMessage, .user, text, [:])]
        case "agent_message":
            let text = payload["message"]?.stringValue ?? textContent(payload["content"])
            return text.providerTrimmed.isEmpty ? [] : [base(.assistantMessage, .assistant, text, [:])]
        case "task_started", "task_complete", "turn_started", "turn_complete":
            return [base(.lifecycle, .system, payload["message"]?.stringValue ?? payloadType, ["eventType": payloadType])]
        case "error":
            return [base(.error, .system, payload["message"]?.stringValue ?? "Codex error", [:])]
        default:
            return []
        }
    }
    if outerType == "compacted" || outerType == "compaction" {
        return [base(.compaction, .system, payload["message"]?.compactString ?? "Conversation compacted", [:])]
    }
    return []
}

private func appServerDrafts(item: JSONValue, timestamp: Date, ordinal: inout Int64) -> [CodexDraft] {
    defer { ordinal += 1 }
    let type = item["type"]?.stringValue ?? "unknown"
    func draft(_ kind: EventKind, _ role: MessageRole, _ text: String, _ metadata: [String: String] = [:]) -> CodexDraft {
        CodexDraft(timestamp: timestamp, kind: kind, role: role, text: text, metadata: metadata, raw: nil, offset: ordinal, source: "app-server")
    }
    switch type {
    case "userMessage", "user_message":
        let text = item["text"]?.stringValue ?? textContent(item["content"])
        return text.isEmpty ? [] : [draft(.userMessage, .user, text)]
    case "agentMessage", "agent_message":
        let text = item["text"]?.stringValue ?? textContent(item["content"])
        return text.isEmpty ? [] : [draft(.assistantMessage, .assistant, text)]
    case "commandExecution", "command_execution":
        let command = item["command"]?.compactString ?? ""
        let output = item["aggregatedOutput"]?.stringValue ?? item["output"]?.stringValue
        var result = [draft(.command, .tool, command)]
        if let output, !output.isEmpty { result.append(draft(.toolResult, .tool, output)) }
        return result
    case "fileChange", "file_change":
        return [draft(.fileChange, .tool, item["changes"]?.compactString ?? item.compactString)]
    case "mcpToolCall", "dynamicToolCall", "toolCall", "tool_call":
        let name = item["tool"]?.stringValue ?? item["name"]?.stringValue ?? "Tool"
        return [draft(.toolCall, .tool, item["arguments"]?.compactString ?? item["input"]?.compactString ?? "", ["toolName": name])]
    case "reasoning":
        return []
    default:
        return [draft(.unknown, .system, item["text"]?.stringValue ?? type, ["itemType": type])]
    }
}

private func removeDuplicatedEventMessages(_ drafts: [CodexDraft]) -> [CodexDraft] {
    let canonical = Set(drafts.filter { $0.source == "response_item" }.map { "\($0.role.rawValue)|\($0.text.providerTrimmed)" })
    return drafts.filter { draft in
        !(draft.source == "event_msg" && canonical.contains("\(draft.role.rawValue)|\(draft.text.providerTrimmed)"))
    }
}

private func textContent(_ value: JSONValue?) -> String {
    switch value {
    case .string(let string): return string
    case .array(let items):
        return items.compactMap { item in
            item["text"]?.stringValue ?? item["content"]?.stringValue
        }.joined(separator: "\n")
    default: return ""
    }
}

private func messageRole(_ raw: String?) -> MessageRole {
    switch raw {
    case "user": .user
    case "assistant": .assistant
    case "system", "developer": .system
    default: .tool
    }
}

private func eventKind(_ role: MessageRole) -> EventKind {
    switch role {
    case .user: .userMessage
    case .assistant: .assistantMessage
    case .system: .systemMessage
    case .tool: .unknown
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
