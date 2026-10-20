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

    func testReadAheadOverlapsApplicationAndProgressCountsConversationsSeparately() async throws {
        let fixture = try makePipelineFixture(failApplication: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ProgressRecorder()
        try await fixture.services.syncNow { await recorder.append($0) }
        let overlapped = await fixture.probe.overlapped
        let values = await recorder.snapshots()
        XCTAssertTrue(overlapped)
        XCTAssertEqual(values.last?.receivedRecordCount, 3)
        XCTAssertEqual(values.last?.updatedConversationCount, 1)
        XCTAssertEqual(values.last?.supersededVersionCount, 1)
        XCTAssertGreaterThan(values.last?.readingSeconds ?? 0, 0)
        XCTAssertGreaterThan(values.last?.applyingSeconds ?? 0, 0)
        let applied = await fixture.store.appliedIDs()
        XCTAssertEqual(applied, ["first-a", "first-b", "second-c"])
    }

    func testFailedApplicationCancelsReadAheadWithoutSavingSpeculativeCursor() async throws {
        let fixture = try makePipelineFixture(failApplication: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            try await fixture.services.syncNow()
            XCTFail("Expected synthetic application failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("synthetic apply failure"))
        }
        let cursor = try await fixture.store.loadSyncCursor(transportIdentifier: fixture.transport.identifier)
        let cancelled = await fixture.probe.cancelled
        let pushes = await fixture.transport.pushes
        XCTAssertEqual(cursor, SyncCursor())
        XCTAssertTrue(cancelled)
        XCTAssertEqual(pushes, 0)
    }

    private func makePipelineFixture(failApplication: Bool) throws -> (
        root: URL, services: ApplicationServices, store: PipelineStore,
        transport: PipelineTransport, probe: PipelineReadProbe
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadlinePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = PipelineReadProbe()
        let store = PipelineStore(probe: probe, failApplication: failApplication)
        let transport = PipelineTransport(probe: probe, blockPrefetch: failApplication)
        let registry = ProgressReadyRegistry()
        let services = ApplicationServices(
            store: store,
            configuration: RuntimeConfiguration(
                applicationSupportURL: root,
                codexHomeURL: root.appendingPathComponent("codex"),
                claudeHomeURL: root.appendingPathComponent("claude")
            ),
            deviceID: registry.currentDeviceID, providers: ProviderRegistry(adapters: [:]),
            transport: transport, deviceRegistry: registry, remoteSyncConfigured: true,
            receivePrefetchAllowed: { true }
        )
        return (root, services, store, transport, probe)
    }
}

private actor PipelineReadProbe {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var overlapped = false
    private(set) var cancelled = false

    func didStartPrefetch() {
        started = true
        continuation?.resume()
        continuation = nil
    }

    func awaitPrefetch() async {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self.releaseWaiter()
        }
        defer { timeout.cancel() }
        if !started {
            await withCheckedContinuation { continuation = $0 }
        }
        overlapped = started
    }

    private func releaseWaiter() {
        continuation?.resume()
        continuation = nil
    }
    func didCancel() { cancelled = true }
}

private actor PipelineTransport: SyncTransport {
    nonisolated let identifier = "pipeline-transport"
    let probe: PipelineReadProbe
    let blockPrefetch: Bool
    private(set) var pushes = 0

    init(probe: PipelineReadProbe, blockPrefetch: Bool) {
        self.probe = probe
        self.blockPrefetch = blockPrefetch
    }
    func healthCheck() async -> Bool { true }
    func push(_ envelopes: [SyncEnvelope]) async throws { pushes += 1 }
    func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        switch cursor.token {
        case nil:
            return SyncPullResult(
                envelopes: [progressEnvelope(id: "first-a"), progressEnvelope(id: "first-b")],
                cursor: SyncCursor(token: Data([1])), remainingItemCount: 1, remainingByteCount: 32
            )
        case Data([1]):
            await probe.didStartPrefetch()
            if blockPrefetch {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { await probe.didCancel(); throw error }
            }
            return SyncPullResult(
                envelopes: [progressEnvelope(id: "second-c")],
                cursor: SyncCursor(token: Data([2])), remainingItemCount: 0, remainingByteCount: 0
            )
        default:
            return SyncPullResult(envelopes: [], cursor: cursor)
        }
    }
}

private actor PipelineStore: ConversationStore {
    let probe: PipelineReadProbe
    let failApplication: Bool
    private var applied: [String] = []
    private var cursor = SyncCursor()

    init(probe: PipelineReadProbe, failApplication: Bool) {
        self.probe = probe
        self.failApplication = failApplication
    }
    func migrate() async throws {}
    func upsert(_ conversation: ProviderConversation) async throws {}
    func listConversations(query: String?, provider: ProviderKind?, favoritesOnly: Bool) async throws -> [ConversationSummary] { [] }
    func conversation(id: String) async throws -> ConversationDetail? { nil }
    func setFavorite(_ favorite: Bool, conversationID: String) async throws {}
    func setNotes(_ notes: String, conversationID: String) async throws {}
    func pendingEnvelopes(limit: Int) async throws -> [SyncEnvelope] { [] }
    func markEnvelopesAcknowledged(ids: [String]) async throws {}
    func applyRemote(_ envelopes: [SyncEnvelope]) async throws { applied += envelopes.map(\.id) }
    func applyRemoteBatch(
        _ envelopes: [SyncEnvelope],
        onProgress: @escaping @Sendable (RemoteApplyResult) async -> Void
    ) async throws -> RemoteApplyResult {
        if applied.isEmpty { await probe.awaitPrefetch() }
        if failApplication { throw ThreadlineError.database("synthetic apply failure") }
        applied += envelopes.map(\.id)
        let result = RemoteApplyResult(
            processedEnvelopeCount: envelopes.count, updatedConversationIDs: ["one-conversation"],
            supersededVersionCount: max(0, envelopes.count - 1)
        )
        await onProgress(result)
        return result
    }
    func healthSnapshot() async throws -> HealthSnapshot { HealthSnapshot() }
    func loadSyncCursor(transportIdentifier: String) async throws -> SyncCursor { cursor }
    func saveSyncCursor(_ cursor: SyncCursor, transportIdentifier: String) async throws { self.cursor = cursor }
    func appliedIDs() -> [String] { applied }
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
