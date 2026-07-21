import Foundation
import XCTest
@testable import ConversationCore

@MainActor
final class SQLiteEnvelopeBatchingTests: XCTestCase {
    func testPendingQueryReturnsOldestContiguousPrefixBoundedByBytesAndCount() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSQLiteBatching-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteConversationStore(
            databaseURL: root.appending(path: "library.sqlite"),
            deviceID: "batch-device",
            envelopeCodec: SizedEnvelopeCodec(),
            queuesForSync: true
        )
        try await store.migrate()

        for (index, size) in [4, 6, 5].enumerated() {
            try await store.upsert(conversation(index: index, payloadSize: size))
        }

        let byteBounded = try await store.pendingEnvelopes(limit: 100, maximumBytes: 10)
        XCTAssertEqual(byteBounded.map(\.encryptedPayload.count), [4, 6])
        XCTAssertEqual(byteBounded.map(\.id), ["envelope-0", "envelope-1"])

        let countBounded = try await store.pendingEnvelopes(limit: 2, maximumBytes: 100)
        XCTAssertEqual(countBounded.map(\.id), ["envelope-0", "envelope-1"])

        try await store.markEnvelopesAcknowledged(ids: byteBounded.map(\.id))
        let remainder = try await store.pendingEnvelopes(limit: 100, maximumBytes: 10)
        XCTAssertEqual(remainder.map(\.id), ["envelope-2"])
    }

    func testPendingQuerySurfacesSingleEnvelopeThatCannotFitInsteadOfStarvingQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSQLiteOversizedBatch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteConversationStore(
            databaseURL: root.appending(path: "library.sqlite"),
            deviceID: "batch-device",
            envelopeCodec: SizedEnvelopeCodec(),
            queuesForSync: true
        )
        try await store.migrate()
        try await store.upsert(conversation(index: 0, payloadSize: 5))

        do {
            _ = try await store.pendingEnvelopes(limit: 100, maximumBytes: 4)
            XCTFail("An individually oversized envelope must fail explicitly")
        } catch let error as ThreadlineError {
            guard case .invalidPayload = error else {
                return XCTFail("Expected an invalid-payload error, got \(error)")
            }
        }
    }

    private func conversation(index: Int, payloadSize: Int) -> ProviderConversation {
        let date = Date(timeIntervalSince1970: TimeInterval(index + 1))
        return ProviderConversation(
            summary: ConversationSummary(
                id: "conversation-\(index)",
                provider: .codex,
                providerSessionID: "session-\(index)",
                title: "payload-\(payloadSize)",
                createdAt: date,
                updatedAt: date,
                originDeviceID: "batch-device"
            ),
            events: [],
            sourceFingerprint: "source-\(index)",
            sourceSchemaVersion: "test-v1"
        )
    }
}

private struct SizedEnvelopeCodec: SyncEnvelopeCodec {
    func seal(
        _ conversation: ProviderConversation,
        originDeviceID: String,
        createdAt: Date
    ) throws -> SyncEnvelope {
        guard let payloadSize = Int(conversation.summary.title.dropFirst("payload-".count)) else {
            throw ThreadlineError.invalidPayload("Missing synthetic payload size")
        }
        let index = conversation.summary.id.dropFirst("conversation-".count)
        return SyncEnvelope(
            id: "envelope-\(index)",
            objectType: "conversation",
            logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            encryptedPayload: Data(repeating: UInt8(payloadSize), count: payloadSize),
            payloadHash: String(repeating: "a", count: 64)
        )
    }

    func open(_ envelope: SyncEnvelope) throws -> ProviderConversation {
        throw ThreadlineError.unavailable("Synthetic batching codec does not decode")
    }
}
