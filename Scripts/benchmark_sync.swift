import Foundation

@main
struct SyncBenchmark {
    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    static func conversation(id: String, eventCount: Int, revision: Int) -> ProviderConversation {
        let date = Date(timeIntervalSince1970: 1_000 + Double(revision))
        let events = (0..<eventCount).map { index in
            ConversationEvent(
                id: "\(id)-event-\(index)", conversationID: id,
                sequence: Int64(index), timestamp: Date(timeIntervalSince1970: Double(index)),
                kind: .assistantMessage, role: .assistant,
                text: String(repeating: "Synthetic benchmark message text. ", count: 8),
                contentHash: "synthetic-\(index)", sourceDeviceID: "writer"
            )
        }
        return ProviderConversation(
            summary: ConversationSummary(
                id: id, provider: .codex, providerSessionID: id,
                title: "Synthetic benchmark", preview: "Synthetic benchmark message text.",
                createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: date,
                originDeviceID: "writer", messageCount: eventCount
            ), events: events, sourceFingerprint: "revision-\(revision)", sourceSchemaVersion: "test-v1"
        )
    }

    static func run(root: URL, label: String, count: Int, events: Int, revisions: Bool) async throws {
        let folder = root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sync = folder.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let key = Data(repeating: 0x5A, count: 32)
        let codec = try EncryptedEnvelopeCodec(keyData: key)
        let manifest = try FolderSyncManifest.create(at: sync, keyData: key, createdByDeviceID: "writer")
        let writer = FolderSyncTransport(rootURL: sync, manifest: manifest, currentDeviceID: "writer", keyData: key)
        let reader = FolderSyncTransport(rootURL: sync, manifest: manifest, currentDeviceID: "reader", keyData: key)
        let store = try SQLiteConversationStore(databaseURL: folder.appendingPathComponent("index.sqlite"), deviceID: "reader", envelopeCodec: codec)
        try await store.migrate()
        var bytes = 0
        for start in stride(from: 0, to: count, by: 64) {
            let envelopes = try (start..<min(start + 64, count)).map { index in
                let payload = conversation(id: revisions ? "one-thread" : "thread-\(index)", eventCount: events + (revisions ? index * 4 : 0), revision: index)
                return try codec.seal(payload, originDeviceID: "writer", createdAt: Date(timeIntervalSince1970: 2_000 + Double(index)))
            }
            bytes += envelopes.reduce(0) { $0 + $1.encryptedPayload.count }
            try await writer.push(envelopes)
        }
        var cursor = SyncCursor()
        var readSeconds = 0.0
        var applySeconds = 0.0
        var pulledCount = 0
        var pages = 0
        while true {
            let readStart = ContinuousClock.now
            let pulled = try await reader.pull(since: cursor)
            readSeconds += seconds(readStart)
            if pulled.envelopes.isEmpty { break }
            let applyStart = ContinuousClock.now
            try await store.applyRemote(pulled.envelopes)
            try await store.saveSyncCursor(pulled.cursor, transportIdentifier: reader.identifier)
            applySeconds += seconds(applyStart)
            cursor = pulled.cursor
            pulledCount += pulled.envelopes.count
            pages += 1
        }
        let health = try await store.healthSnapshot()
        print("\(label): records=\(pulledCount) unique_conversations=\(health.indexedConversationCount) pages=\(pages) payload_MiB=\(String(format: "%.1f", Double(bytes) / 1048576)) read_seconds=\(String(format: "%.3f", readSeconds)) apply_seconds=\(String(format: "%.3f", applySeconds)) records_per_second=\(String(format: "%.1f", Double(pulledCount) / (readSeconds + applySeconds)))")
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await run(root: root, label: "small", count: 1_024, events: 20, revisions: false)
        try await run(root: root, label: "medium", count: 128, events: 500, revisions: false)
        try await run(root: root, label: "historical-versions", count: 256, events: 10, revisions: true)
    }
}
