import ConversationCore
import Foundation

public struct ClaudeAdapter: ProviderAdapter, Sendable {
    public let kind: ProviderKind = .claude

    private let environment: ProviderEnvironment
    private let deviceID: String
    private let processRunner: any ProcessRunning
    private let executableURL: URL?

    public init(
        environment: ProviderEnvironment = ProviderEnvironment(),
        deviceID: String? = nil,
        processRunner: any ProcessRunning = LocalProcessRunner(),
        executableURL: URL? = nil
    ) {
        self.environment = environment
        self.deviceID = deviceID ?? StableHash.sha256(ProcessInfo.processInfo.hostName).prefix(16).description
        self.processRunner = processRunner
        self.executableURL = executableURL ?? environment.executable(named: "claude")
    }

    init(
        environment: ProviderEnvironment,
        deviceID: String,
        processRunner: any ProcessRunning,
        executableURL: URL?
    ) {
        self.environment = environment
        self.deviceID = deviceID
        self.processRunner = processRunner
        self.executableURL = executableURL
    }

    public func discoverSources() async -> [ProviderSource] {
        let root = environment.claudeHome
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent("projects", isDirectory: true).path)
        let version = await executableVersion()
        return [ProviderSource(
            id: "claude:\(StableHash.sha256(root.path).prefix(20))",
            provider: .claude,
            rootPath: root.path,
            displayName: "Claude Code",
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
        let root = environment.claudeHome.appendingPathComponent("projects", isDirectory: true)
        let files = ProviderFiles.jsonlFiles(below: root, modifiedSince: since)
        var emittedSessionIDs = Set<String>()
        for batchStart in stride(from: 0, to: files.count, by: Self.maximumConcurrentParses) {
            try Task.checkCancellation()
            let batchEnd = min(files.count, batchStart + Self.maximumConcurrentParses)
            let parsed = try await withThrowingTaskGroup(
                of: (Int, ProviderConversation?).self,
                returning: [(Int, ProviderConversation?)].self
            ) { group in
                for index in batchStart..<batchEnd {
                    let file = files[index]
                    group.addTask(priority: .utility) {
                        let conversation = self.parseTranscript(file)
                        // The parser treats malformed files as a skip. Preserve
                        // cancellation as a control-flow error instead.
                        try Task.checkCancellation()
                        return (index, conversation)
                    }
                }
                var results: [(Int, ProviderConversation?)] = []
                results.reserveCapacity(batchEnd - batchStart)
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }

            for (_, conversation) in parsed {
                try Task.checkCancellation()
                guard let conversation,
                      emittedSessionIDs.insert(conversation.summary.providerSessionID).inserted
                else { continue }
                try await yield(conversation)
            }
        }
    }

    public func fetchConversation(id: String) async throws -> ProviderConversation? {
        let normalized = id.hasPrefix("claude:") ? String(id.dropFirst("claude:".count)) : id
        let root = environment.claudeHome.appendingPathComponent("projects", isDirectory: true)
        let files = ProviderFiles.jsonlFiles(below: root)
        var preferred: [URL] = []
        var fallback: [URL] = []
        if let composite = Self.splitSubagentIdentity(normalized) {
            for file in files {
                if Self.isSubagentTranscript(file),
                   Self.parentSessionDirectoryID(file) == composite.parentSessionID {
                    preferred.append(file)
                } else {
                    fallback.append(file)
                }
            }
        } else {
            preferred = files.filter {
                let filenameID = $0.deletingPathExtension().lastPathComponent
                return !Self.isSubagentTranscript($0)
                    && (filenameID == normalized || id.hasSuffix(filenameID))
            }
        }
        for file in preferred + fallback {
            if let parsed = parseTranscript(file), parsed.summary.id == id || parsed.summary.providerSessionID == normalized {
                return parsed
            }
        }
        return nil
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
        let version = String(decoding: result.standardOutput, as: UTF8.self).providerTrimmed
        return version.isEmpty ? nil : version
    }

    private func parseTranscript(_ url: URL) -> ProviderConversation? {
        let subagentPath = Self.isSubagentTranscript(url)
        var sessionID = subagentPath
            ? Self.parentSessionDirectoryID(url)
            : url.deletingPathExtension().lastPathComponent
        var capturedSessionID = false
        var agentID: String?
        var observedSidechain = false
        var cwd: String?
        var summaryTitle: String?
        var drafts = BoundedImportAccumulator<ClaudeDraft>()
        let fallbackDate = ProviderFiles.modificationDate(url) ?? .distantPast

        let result: JSONLReadResult
        do {
            result = try StreamingJSONL.read(
                url,
                maximumFileBytes: ProviderImportLimits.maximumJSONLBytes,
                onOversizedLine: { offset, byteCount in
                appendClaudeDraft(ClaudeDraft(
                    timestamp: fallbackDate,
                    kind: .unknown,
                    role: .system,
                    text: "Oversized Claude event omitted",
                    metadata: ["payloadOmitted": "true", "sourceBytes": String(byteCount)],
                    raw: nil,
                    offset: offset
                ), to: &drafts)
            }, onTruncatedRegion: { offset, byteCount in
                appendClaudeDraft(ClaudeDraft(
                    timestamp: fallbackDate,
                    kind: .unknown,
                    role: .system,
                    text: "A middle section of this large Claude transcript was omitted",
                    metadata: [
                        "payloadOmitted": "file-sampling",
                        "omittedBytes": String(byteCount),
                    ],
                    raw: nil,
                    offset: offset
                ), to: &drafts)
            }) { value, raw, offset in
                let type = value["type"]?.stringValue ?? "unknown"
                let candidateSessionID = (
                    value["sessionId"]?.stringValue ?? value["session_id"]?.stringValue
                )?.providerTrimmed
                if !capturedSessionID,
                   let candidateSessionID,
                   !candidateSessionID.isEmpty {
                    sessionID = candidateSessionID
                    capturedSessionID = true
                }
                let candidateAgentID = (
                    value["agentId"]?.stringValue ?? value["agent_id"]?.stringValue
                )?.providerTrimmed
                if agentID == nil,
                   let candidateAgentID,
                   !candidateAgentID.isEmpty {
                    agentID = candidateAgentID
                }
                if value["isSidechain"]?.boolValue == true { observedSidechain = true }
                if cwd == nil,
                   let candidateCWD = value["cwd"]?.stringValue?.providerTrimmed,
                   !candidateCWD.isEmpty {
                    cwd = candidateCWD
                }
                let timestamp = ProviderDates.parse(value["timestamp"]) ?? fallbackDate

                if type == "summary" {
                    summaryTitle = value["summary"]?.stringValue ?? summaryTitle
                    return
                }
                for draft in claudeDrafts(value: value, type: type, timestamp: timestamp, raw: raw, offset: offset) {
                    appendClaudeDraft(draft, to: &drafts)
                }
            }
        } catch {
            return nil
        }
        var boundedDrafts = drafts.headElements
        if drafts.hasOmissions {
            boundedDrafts.append(ClaudeDraft(
                timestamp: boundedDrafts.last?.timestamp ?? fallbackDate,
                kind: .unknown,
                role: .system,
                text: "A middle section of Claude events was omitted to keep this conversation responsive",
                metadata: [
                    "payloadOmitted": "conversation-budget",
                    "omittedEventCount": String(drafts.omittedItemCount),
                    "omittedTextBytes": String(drafts.omittedTextBytes),
                    "omittedRawBytes": String(drafts.omittedRawBytes),
                ],
                raw: nil,
                offset: boundedDrafts.last?.offset ?? 0
            ))
        }
        boundedDrafts.append(contentsOf: drafts.tailElements)
        guard !boundedDrafts.isEmpty else { return nil }

        let isSubagent = subagentPath || agentID != nil || observedSidechain
        let providerSessionID: String
        if isSubagent {
            let effectiveAgentID = agentID ?? Self.fallbackAgentID(url)
            providerSessionID = Self.subagentIdentity(
                parentSessionID: sessionID,
                agentID: effectiveAgentID
            )
        } else {
            providerSessionID = sessionID
        }
        let conversationID = "claude:\(providerSessionID)"
        let events = boundedDrafts.enumerated().map { index, draft in
            let metadata = draft.metadata
            let hashInput = "\(draft.kind.rawValue)|\(draft.role.rawValue)|\(draft.text)|\(metadata.sorted { $0.key < $1.key })"
            let contentHash = StableHash.sha256(hashInput)
            return ConversationEvent(
                id: "claude-event:\(StableHash.sha256("\(providerSessionID)|\(draft.offset)|\(contentHash)").prefix(32))",
                conversationID: conversationID,
                sequence: Int64(index),
                timestamp: draft.timestamp,
                kind: draft.kind,
                role: draft.role,
                text: draft.text,
                metadata: metadata,
                rawPayload: draft.raw,
                contentHash: contentHash,
                sourceDeviceID: deviceID
            )
        }
        let firstUser = events.first { $0.role == .user && !$0.text.providerTrimmed.isEmpty }?.text.providerTrimmed
        let lastMessage = events.last { ($0.role == .user || $0.role == .assistant) && !$0.text.providerTrimmed.isEmpty }?.text.providerTrimmed ?? ""
        let timestamps = events.map(\.timestamp)
        let project = makeProject(cwd, fallbackDirectory: Self.projectFallbackDirectory(url))
        let title = summaryTitle?.providerTrimmed.nilIfEmpty ?? firstUser ?? "Claude conversation"
        let summary = ConversationSummary(
            id: conversationID,
            provider: .claude,
            providerSessionID: providerSessionID,
            title: title.replacingOccurrences(of: "\n", with: " ").providerTruncated(120),
            preview: lastMessage.replacingOccurrences(of: "\n", with: " ").providerTruncated(240),
            project: project,
            createdAt: timestamps.min() ?? fallbackDate,
            updatedAt: timestamps.max() ?? fallbackDate,
            status: .idle,
            syncAvailability: .localOnly,
            originDeviceID: deviceID,
            messageCount: events.filter { $0.role == .user || $0.role == .assistant }.count
        )
        let schema = result.isTruncated ? "claude-project-jsonl-sampled-v3" : "claude-project-jsonl-v3"
        return ProviderConversation(summary: summary, events: events, sourceFingerprint: result.fingerprint, sourceSchemaVersion: schema)
    }

    private static let subagentIdentityMarker = ":subagent:"
    /// Two files keep memory bounded while using a second performance core on
    /// the large first reconciliation. Results are yielded in source priority
    /// order, never task-completion order.
    private static let maximumConcurrentParses = 2

    private static func subagentIdentity(parentSessionID: String, agentID: String) -> String {
        "\(parentSessionID)\(subagentIdentityMarker)\(agentID)"
    }

    private static func splitSubagentIdentity(
        _ identity: String
    ) -> (parentSessionID: String, agentID: String)? {
        guard let marker = identity.range(of: subagentIdentityMarker) else { return nil }
        let parent = String(identity[..<marker.lowerBound])
        let agent = String(identity[marker.upperBound...])
        guard !parent.isEmpty, !agent.isEmpty else { return nil }
        return (parent, agent)
    }

    private static func isSubagentTranscript(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare("subagents") == .orderedSame
    }

    private static func parentSessionDirectoryID(_ url: URL) -> String {
        url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    }

    private static func fallbackAgentID(_ url: URL) -> String {
        var candidate = url.deletingPathExtension().lastPathComponent.providerTrimmed
        if candidate.lowercased().hasPrefix("agent-") {
            candidate.removeFirst("agent-".count)
        }
        if !candidate.isEmpty { return candidate }
        return "file-\(StableHash.sha256(url.lastPathComponent).prefix(24))"
    }

    private static func projectFallbackDirectory(_ url: URL) -> String {
        if isSubagentTranscript(url) {
            return url.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    private func makeProject(_ cwd: String?, fallbackDirectory: String) -> ProjectIdentity? {
        if let cwd = cwd?.providerTrimmed, !cwd.isEmpty {
            let url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
            return ProjectIdentity(id: "project:\(StableHash.sha256(url.path).prefix(24))", displayName: url.lastPathComponent, canonicalPath: url.path)
        }
        guard !fallbackDirectory.isEmpty else { return nil }
        return ProjectIdentity(
            id: "claude-project:\(StableHash.sha256(fallbackDirectory).prefix(24))",
            displayName: readableClaudeProjectName(fallbackDirectory)
        )
    }
}

private func appendClaudeDraft(
    _ draft: ClaudeDraft,
    to accumulator: inout BoundedImportAccumulator<ClaudeDraft>
) {
    var metadata = draft.metadata
    let sourceCharacterCount = draft.text.count
    let text = draft.text.providerTruncated(ProviderImportLimits.maximumTextCharactersPerEvent)
    if text.count < sourceCharacterCount {
        metadata["textOmitted"] = "event-budget"
        metadata["sourceCharacterCount"] = String(sourceCharacterCount)
    }
    let raw = boundedRawPayload(draft.raw, metadata: &metadata)
    let bounded = ClaudeDraft(
        timestamp: draft.timestamp,
        kind: draft.kind,
        role: draft.role,
        text: text,
        metadata: metadata,
        raw: raw,
        offset: draft.offset
    )
    accumulator.append(bounded, textBytes: text.utf8.count, rawBytes: raw?.count ?? 0)
}

private struct ClaudeDraft {
    let timestamp: Date
    let kind: EventKind
    let role: MessageRole
    let text: String
    let metadata: [String: String]
    let raw: Data?
    let offset: Int64
}

private func claudeDrafts(value: JSONValue, type: String, timestamp: Date, raw: Data, offset: Int64) -> [ClaudeDraft] {
    // A Claude JSONL line can co-locate visible content with hidden thinking
    // blocks and their signatures. Retaining the original line on any visible
    // draft would persist and synchronize those secrets, so Claude events never
    // carry source-line raw payload. The file fingerprint still detects edits.
    _ = raw
    func draft(_ kind: EventKind, _ role: MessageRole, _ text: String, _ metadata: [String: String] = [:]) -> ClaudeDraft {
        var metadata = metadata
        if let uuid = value["uuid"]?.stringValue { metadata["providerEventID"] = uuid }
        if let parent = value["parentUuid"]?.stringValue { metadata["parentProviderEventID"] = parent }
        return ClaudeDraft(timestamp: timestamp, kind: kind, role: role, text: text, metadata: metadata, raw: nil, offset: offset)
    }

    switch type {
    case "user":
        let content = value["message"]?["content"] ?? value["content"]
        if let text = content?.stringValue, !text.providerTrimmed.isEmpty {
            return [draft(.userMessage, .user, text)]
        }
        return (content?.arrayValue ?? []).compactMap { block in
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.providerTrimmed.isEmpty else { return nil }
                return draft(.userMessage, .user, text)
            case "tool_result":
                let text = claudeBlockText(block["content"])
                return draft(.toolResult, .tool, text, ["toolUseID": block["tool_use_id"]?.stringValue ?? ""])
            case "image", "document":
                return draft(.attachment, .user, "Attachment", ["attachmentType": block["type"]?.stringValue ?? "attachment"])
            default:
                return nil
            }
        }
    case "assistant":
        let content = value["message"]?["content"] ?? value["content"]
        if let text = content?.stringValue, !text.providerTrimmed.isEmpty {
            return [draft(.assistantMessage, .assistant, text)]
        }
        return (content?.arrayValue ?? []).compactMap { block in
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.providerTrimmed.isEmpty else { return nil }
                return draft(.assistantMessage, .assistant, text)
            case "tool_use", "server_tool_use":
                return draft(
                    .toolCall,
                    .tool,
                    block["input"]?.compactString ?? "",
                    ["toolName": block["name"]?.stringValue ?? "Tool", "toolUseID": block["id"]?.stringValue ?? ""]
                )
            default:
                return nil // Deliberately exclude hidden thinking blocks.
            }
        }
    case "system":
        let subtype = value["subtype"]?.stringValue ?? "system"
        let text = value["content"]?.stringValue ?? value["message"]?.stringValue ?? subtype
        return [draft(subtype.contains("compact") ? .compaction : .systemMessage, .system, text, ["subtype": subtype])]
    case "result":
        let text = value["result"]?.stringValue ?? value["subtype"]?.stringValue ?? "Claude turn completed"
        return [draft(.lifecycle, .system, text)]
    default:
        return []
    }
}

private func claudeBlockText(_ value: JSONValue?) -> String {
    if let text = value?.stringValue { return text }
    return (value?.arrayValue ?? []).compactMap { $0["text"]?.stringValue ?? $0["content"]?.stringValue }.joined(separator: "\n")
}

private func readableClaudeProjectName(_ encoded: String) -> String {
    encoded.split(separator: "-").last.map(String.init) ?? encoded
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
