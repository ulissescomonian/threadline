import ConversationCore
import Foundation
import ProviderKit
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class SyncBatchingTests: XCTestCase {
    func testSQLitePendingSelectionHonorsSmallByteBudgetAndExactBoundary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteConversationStore(
            databaseURL: root.appending(path: "Threadline.sqlite"),
            deviceID: "batch-device",
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: true
        )
        try await store.migrate()
        for index in 0..<3 {
            try await store.upsert(conversation(index: index, textBytes: (index + 1) * 40))
        }

        let all = try await store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(all.count, 3)
        let exactTwoEnvelopeBudget = all[0].encryptedPayload.count
            + all[1].encryptedPayload.count

        let exactBoundary = try await store.pendingEnvelopes(
            limit: 10,
            maximumBytes: exactTwoEnvelopeBudget
        )
        let oneByteShort = try await store.pendingEnvelopes(
            limit: 10,
            maximumBytes: exactTwoEnvelopeBudget - 1
        )

        XCTAssertEqual(exactBoundary.map(\.id), Array(all.prefix(2)).map(\.id))
        XCTAssertEqual(oneByteShort.map(\.id), [all[0].id])
    }

    func testSyncDrainsByteBoundedBatchesInOrderAndAcknowledgesEachExactBatch() async throws {
        let fixture = try makeRuntimeFixture(
            envelopes: [
                envelope(id: "a", byteCount: 60),
                envelope(id: "b", byteCount: 40),
                envelope(id: "c", byteCount: 70),
                envelope(id: "d", byteCount: 30),
            ],
            storeByteBudget: 100
        )
        defer { fixture.cleanup() }

        try await fixture.services.syncNow()

        let pushed = await fixture.transport.pushedIDs()
        let acknowledged = await fixture.store.acknowledgedIDs()
        let remaining = await fixture.store.remainingIDs()
        XCTAssertEqual(pushed, [["a", "b"], ["c", "d"]])
        XCTAssertEqual(acknowledged, [["a", "b"], ["c", "d"]])
        XCTAssertEqual(remaining, [])
    }

    func testFailureOnSecondPushAcknowledgesOnlyFirstBatchAndRetryDrainsRemainder() async throws {
        let fixture = try makeRuntimeFixture(
            envelopes: [
                envelope(id: "a", byteCount: 60),
                envelope(id: "b", byteCount: 40),
                envelope(id: "c", byteCount: 70),
                envelope(id: "d", byteCount: 30),
            ],
            storeByteBudget: 100,
            failOnPush: 2
        )
        defer { fixture.cleanup() }

        await XCTAssertThrowsAsync(try await fixture.services.syncNow())

        let failedPushes = await fixture.transport.pushedIDs()
        let firstAcknowledgements = await fixture.store.acknowledgedIDs()
        let pendingAfterFailure = await fixture.store.remainingIDs()
        XCTAssertEqual(failedPushes, [["a", "b"], ["c", "d"]])
        XCTAssertEqual(firstAcknowledgements, [["a", "b"]])
        XCTAssertEqual(pendingAfterFailure, ["c", "d"])

        await fixture.transport.setFailOnPush(nil)
        try await fixture.services.syncNow()

        let successfulPushes = await fixture.transport.pushedIDs()
        let finalAcknowledgements = await fixture.store.acknowledgedIDs()
        let pendingAfterRetry = await fixture.store.remainingIDs()
        XCTAssertEqual(successfulPushes, [["a", "b"], ["c", "d"], ["c", "d"]])
        XCTAssertEqual(finalAcknowledgements, [["a", "b"], ["c", "d"]])
        XCTAssertEqual(pendingAfterRetry, [])
    }

    func testSyncAlsoDrainsCountBoundedPages() async throws {
        let envelopes = (0..<101).map {
            envelope(id: String(format: "item-%03d", $0), byteCount: 1)
        }
        let fixture = try makeRuntimeFixture(envelopes: envelopes, storeByteBudget: 1_000)
        defer { fixture.cleanup() }

        try await fixture.services.syncNow()

        let pushed = await fixture.transport.pushedIDs()
        let acknowledgements = await fixture.store.acknowledgedIDs()
        XCTAssertEqual(pushed.map(\.count), [100, 1])
        XCTAssertEqual(pushed.flatMap { $0 }, envelopes.map(\.id))
        XCTAssertEqual(acknowledgements.map(\.count), [100, 1])
    }

    private func makeRuntimeFixture(
        envelopes: [SyncEnvelope],
        storeByteBudget: Int,
        failOnPush: Int? = nil
    ) throws -> BatchingRuntimeFixture {
        let root = try makeTemporaryDirectory()
        let store = ByteBoundedOutboxStore(envelopes: envelopes, byteBudget: storeByteBudget)
        let transport = BatchRecordingTransport(failOnPush: failOnPush)
        let registry = ReadyBatchRegistry()
        let configuration = RuntimeConfiguration(
            applicationSupportURL: root,
            codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
        )
        let services = ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: registry.currentDeviceID,
            providers: ProviderRegistry(adapters: [:]),
            transport: transport,
            deviceRegistry: registry,
            cloudKitAuthorized: true
        )
        return BatchingRuntimeFixture(
            root: root,
            store: store,
            transport: transport,
            services: services
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSyncBatchingTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct BatchingRuntimeFixture {
    let root: URL
    let store: ByteBoundedOutboxStore
    let transport: BatchRecordingTransport
    let services: ApplicationServices

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ByteBoundedOutboxStore: ConversationStore {
    private let envelopes: [SyncEnvelope]
    private let byteBudget: Int
    private var acknowledged = Set<String>()
    private var acknowledgementBatches: [[String]] = []
    private var cursors: [String: SyncCursor] = [:]

    init(envelopes: [SyncEnvelope], byteBudget: Int) {
        self.envelopes = envelopes
        self.byteBudget = byteBudget
    }

    func migrate() async throws {}
    func upsert(_ conversation: ProviderConversation) async throws {}

    func listConversations(
        query: String?,
        provider: ProviderKind?,
        favoritesOnly: Bool
    ) async throws -> [ConversationSummary] { [] }

    func conversation(id: String) async throws -> ConversationDetail? { nil }
    func setFavorite(_ favorite: Bool, conversationID: String) async throws {}
    func setNotes(_ notes: String, conversationID: String) async throws {}

    func pendingEnvelopes(limit: Int) async throws -> [SyncEnvelope] {
        Array(envelopes.filter { !acknowledged.contains($0.id) }.prefix(limit))
    }

    func pendingEnvelopes(limit: Int, maximumBytes: Int) async throws -> [SyncEnvelope] {
        let effectiveBudget = min(maximumBytes, byteBudget)
        var result: [SyncEnvelope] = []
        var bytes = 0
        for envelope in envelopes where !acknowledged.contains(envelope.id) {
            guard result.count < limit else { break }
            let nextBytes = bytes + envelope.encryptedPayload.count
            if nextBytes > effectiveBudget { break }
            result.append(envelope)
            bytes = nextBytes
        }
        return result
    }

    func markEnvelopesAcknowledged(ids: [String]) async throws {
        acknowledgementBatches.append(ids)
        acknowledged.formUnion(ids)
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) async throws {}

    func healthSnapshot() async throws -> HealthSnapshot {
        let pending = envelopes.filter { !acknowledged.contains($0.id) }
        return HealthSnapshot(
            pendingObjectCount: pending.count,
            pendingByteCount: Int64(pending.reduce(0) { $0 + $1.encryptedPayload.count })
        )
    }

    func loadSyncCursor(transportIdentifier: String) async throws -> SyncCursor {
        cursors[transportIdentifier] ?? SyncCursor()
    }

    func saveSyncCursor(_ cursor: SyncCursor, transportIdentifier: String) async throws {
        cursors[transportIdentifier] = cursor
    }

    func acknowledgedIDs() -> [[String]] { acknowledgementBatches }

    func remainingIDs() -> [String] {
        envelopes.filter { !acknowledged.contains($0.id) }.map(\.id)
    }
}

private actor BatchRecordingTransport: SyncTransport {
    nonisolated let identifier = "batch-recording-transport"
    private var failOnPush: Int?
    private var pushCount = 0
    private var batches: [[String]] = []

    init(failOnPush: Int?) {
        self.failOnPush = failOnPush
    }

    func healthCheck() async -> Bool { true }

    func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        SyncPullResult(envelopes: [], cursor: cursor)
    }

    func push(_ envelopes: [SyncEnvelope]) async throws {
        pushCount += 1
        batches.append(envelopes.map(\.id))
        if pushCount == failOnPush {
            throw ThreadlineError.unavailable("Injected batch upload failure")
        }
    }

    func setFailOnPush(_ value: Int?) {
        failOnPush = value
    }

    func pushedIDs() -> [[String]] { batches }
}

private actor ReadyBatchRegistry: DeviceRegistry {
    nonisolated let currentDeviceID = "batch-device"

    private var snapshot: DeviceRegistrySnapshot {
        DeviceRegistrySnapshot(
            currentDeviceID: currentDeviceID,
            devices: [RegisteredDevice(
                id: currentDeviceID,
                displayName: "This Mac",
                systemVersion: "test",
                appVersion: "test",
                registeredAt: Date(timeIntervalSince1970: 1),
                lastSeenAt: Date(timeIntervalSince1970: 2)
            )],
            readiness: .ready,
            refreshedAt: Date(timeIntervalSince1970: 3)
        )
    }

    func cachedSnapshot() async -> DeviceRegistrySnapshot { snapshot }
    func refresh() async -> DeviceRegistrySnapshot { snapshot }
    func prepareForSync() async -> DeviceRegistrySnapshot { snapshot }
    func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot { snapshot }
    func retireDevice(id: String) async -> DeviceRegistrySnapshot { snapshot }
    func reactivateCurrentDevice() async -> DeviceRegistrySnapshot { snapshot }
}

private func envelope(id: String, byteCount: Int) -> SyncEnvelope {
    SyncEnvelope(
        id: id,
        objectType: "conversation",
        logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
        originDeviceID: "batch-device",
        createdAt: Date(timeIntervalSince1970: TimeInterval(id.hashValue)),
        encryptedPayload: Data(repeating: 0x5A, count: byteCount),
        payloadHash: String(repeating: "5a", count: 32)
    )
}

private func conversation(index: Int, textBytes: Int) -> ProviderConversation {
    let date = Date(timeIntervalSince1970: TimeInterval(index + 1))
    let summary = ConversationSummary(
        id: "conversation-\(index)",
        provider: .codex,
        providerSessionID: "session-\(index)",
        title: "Conversation \(index)",
        createdAt: date,
        updatedAt: date,
        originDeviceID: "batch-device",
        messageCount: 1
    )
    return ProviderConversation(
        summary: summary,
        events: [ConversationEvent(
            id: "event-\(index)",
            conversationID: summary.id,
            sequence: 1,
            timestamp: date,
            kind: .userMessage,
            role: .user,
            text: String(repeating: "x", count: textBytes),
            contentHash: "hash-\(index)",
            sourceDeviceID: "batch-device"
        )],
        sourceFingerprint: "source-\(index)",
        sourceSchemaVersion: "test-v1"
    )
}

@MainActor
private func XCTAssertThrowsAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
