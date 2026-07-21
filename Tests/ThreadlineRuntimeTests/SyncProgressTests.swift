import ConversationCore
import Foundation
import ProviderKit
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class SyncProgressTests: XCTestCase {
    func testSyncRunLeaseExcludesOtherProcessesAndReleasesCleanly() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSyncLeaseTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appending(path: ".sync-run.lock")

        var first: SyncRunLease? = try SyncRunLease(at: lockURL)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try SyncRunLease(at: lockURL))
        first = nil
        XCTAssertNoThrow(try SyncRunLease(at: lockURL))
    }

    func testProgressReportsDirectionAndOnlyCountsAcknowledgedUploads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSyncProgressTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = [progressEnvelope(id: "local-1"), progressEnvelope(id: "local-2")]
        let remote = progressEnvelope(id: "remote-1", origin: "remote-device")
        let store = ProgressRecordingStore(pending: local)
        let transport = ProgressRecordingTransport(remote: remote)
        let registry = ProgressReadyRegistry()
        let services = ApplicationServices(
            store: store,
            configuration: RuntimeConfiguration(
                applicationSupportURL: root,
                codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
                claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
            ),
            deviceID: registry.currentDeviceID,
            providers: ProviderRegistry(adapters: [:]),
            transport: transport,
            deviceRegistry: registry,
            cloudKitAuthorized: true,
            transportDisplayName: "OneDrive"
        )
        let recorder = ProgressRecorder()

        try await services.syncNow { progress in
            await recorder.append(progress)
        }

        let snapshots = await recorder.snapshots()
        XCTAssertEqual(snapshots.first?.phase, .preparing)
        XCTAssertEqual(snapshots.last?.phase, .completed)
        XCTAssertTrue(snapshots.contains { $0.phase == .receiving })
        XCTAssertTrue(snapshots.contains { $0.phase == .applying })
        XCTAssertTrue(snapshots.contains { progress in
            progress.phase == .sending
                && progress.source == "This Mac"
                && progress.destination == "OneDrive"
                && progress.completedItemCount == 2
                && progress.totalItemCount == 2
        })
        XCTAssertFalse(snapshots.contains { progress in
            progress.phase == .sending && progress.completedItemCount > 2
        })
        XCTAssertTrue(snapshots.compactMap(\.fractionCompleted).allSatisfy {
            (0...1).contains($0)
        })
        let appliedIDs = await store.appliedIDs()
        let acknowledgedIDs = await store.acknowledgedIDs()
        XCTAssertEqual(appliedIDs, ["remote-1"])
        XCTAssertEqual(acknowledgedIDs, ["local-1", "local-2"])
    }

    func testUnreadRemoteItemsNeverPermitUploadAcknowledgementOrCursorAdvance() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineStalledPullTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProgressRecordingStore(pending: [progressEnvelope(id: "local-pending")])
        let transport = StalledProgressTransport()
        let registry = ProgressReadyRegistry()
        let services = ApplicationServices(
            store: store,
            configuration: RuntimeConfiguration(
                applicationSupportURL: root,
                codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
                claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
            ),
            deviceID: registry.currentDeviceID,
            providers: ProviderRegistry(adapters: [:]),
            transport: transport,
            deviceRegistry: registry,
            cloudKitAuthorized: true,
            transportDisplayName: "OneDrive"
        )

        do {
            try await services.syncNow()
            XCTFail("A stalled remote pull must fail before upload")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not read the next item"))
        }

        let pullCount = await transport.pullCount()
        let pushCount = await transport.pushCount()
        XCTAssertEqual(pullCount, 3)
        XCTAssertEqual(pushCount, 0)
        let acknowledgedIDs = await store.acknowledgedIDs()
        XCTAssertTrue(acknowledgedIDs.isEmpty)
        let cursor = try await store.loadSyncCursor(transportIdentifier: transport.identifier)
        XCTAssertEqual(cursor, SyncCursor())
    }
}

private actor ProgressRecorder {
    private var values: [SyncProgress] = []
    func append(_ value: SyncProgress) { values.append(value) }
    func snapshots() -> [SyncProgress] { values }
}

private actor ProgressRecordingStore: ConversationStore {
    private let pending: [SyncEnvelope]
    private var acknowledged = Set<String>()
    private var applied: [String] = []
    private var cursors: [String: SyncCursor] = [:]

    init(pending: [SyncEnvelope]) { self.pending = pending }

    func migrate() async throws {}
    func upsert(_ conversation: ProviderConversation) async throws {}
    func listConversations(query: String?, provider: ProviderKind?, favoritesOnly: Bool) async throws -> [ConversationSummary] { [] }
    func conversation(id: String) async throws -> ConversationDetail? { nil }
    func setFavorite(_ favorite: Bool, conversationID: String) async throws {}
    func setNotes(_ notes: String, conversationID: String) async throws {}
    func pendingEnvelopes(limit: Int) async throws -> [SyncEnvelope] {
        Array(pending.filter { !acknowledged.contains($0.id) }.prefix(limit))
    }
    func markEnvelopesAcknowledged(ids: [String]) async throws {
        acknowledged.formUnion(ids)
    }
    func applyRemote(_ envelopes: [SyncEnvelope]) async throws {
        applied.append(contentsOf: envelopes.map(\.id))
    }
    func healthSnapshot() async throws -> HealthSnapshot {
        let waiting = pending.filter { !acknowledged.contains($0.id) }
        return HealthSnapshot(
            pendingObjectCount: waiting.count,
            pendingByteCount: Int64(waiting.reduce(0) { $0 + $1.encryptedPayload.count })
        )
    }
    func loadSyncCursor(transportIdentifier: String) async throws -> SyncCursor {
        cursors[transportIdentifier] ?? SyncCursor()
    }
    func saveSyncCursor(_ cursor: SyncCursor, transportIdentifier: String) async throws {
        cursors[transportIdentifier] = cursor
    }
    func appliedIDs() -> [String] { applied }
    func acknowledgedIDs() -> [String] { pending.filter { acknowledged.contains($0.id) }.map(\.id) }
}

private actor ProgressRecordingTransport: SyncTransport {
    nonisolated let identifier = "progress-transport"
    private let remote: SyncEnvelope
    private var returnedRemote = false

    init(remote: SyncEnvelope) { self.remote = remote }
    func healthCheck() async -> Bool { true }
    func push(_ envelopes: [SyncEnvelope]) async throws {}
    func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        guard !returnedRemote else { return SyncPullResult(envelopes: [], cursor: cursor) }
        returnedRemote = true
        return SyncPullResult(
            envelopes: [remote],
            cursor: SyncCursor(token: Data("remote-1".utf8), updatedAt: Date()),
            remainingItemCount: 0,
            remainingByteCount: 0
        )
    }
}

private actor StalledProgressTransport: SyncTransport {
    nonisolated let identifier = "stalled-progress-transport"
    private var pulls = 0
    private var pushes = 0

    func healthCheck() async -> Bool { true }
    func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        pulls += 1
        return SyncPullResult(
            envelopes: [],
            cursor: SyncCursor(token: Data("must-not-persist".utf8), updatedAt: Date()),
            remainingItemCount: 1,
            remainingByteCount: 128
        )
    }
    func push(_ envelopes: [SyncEnvelope]) async throws { pushes += 1 }
    func pullCount() -> Int { pulls }
    func pushCount() -> Int { pushes }
}

private actor ProgressReadyRegistry: DeviceRegistry {
    nonisolated let currentDeviceID = "progress-device"
    private var value: DeviceRegistrySnapshot {
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
    func cachedSnapshot() async -> DeviceRegistrySnapshot { value }
    func refresh() async -> DeviceRegistrySnapshot { value }
    func prepareForSync() async -> DeviceRegistrySnapshot { value }
    func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot { value }
    func retireDevice(id: String) async -> DeviceRegistrySnapshot { value }
    func reactivateCurrentDevice() async -> DeviceRegistrySnapshot { value }
}

private func progressEnvelope(
    id: String,
    origin: String = "progress-device"
) -> SyncEnvelope {
    SyncEnvelope(
        id: id,
        objectType: "conversation",
        logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
        originDeviceID: origin,
        createdAt: Date(timeIntervalSince1970: 10),
        encryptedPayload: Data(repeating: 0x5A, count: 32),
        payloadHash: String(repeating: "5a", count: 32)
    )
}
