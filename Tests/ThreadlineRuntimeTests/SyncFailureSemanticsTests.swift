import ConversationCore
import Foundation
import ProviderKit
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class SyncFailureSemanticsTests: XCTestCase {
    func testUnhealthyTransportDoesNotPullPushOrAcknowledgeOutbox() async throws {
        let fixture = try await makeFixture(mode: .unhealthy)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync(try await fixture.services.syncNow())

        let calls = await fixture.transport.recordedCalls()
        let pending = try await fixture.store.pendingEnvelopes(limit: 10)
        let cursor = try await fixture.store.loadSyncCursor(
            transportIdentifier: fixture.transport.identifier
        )
        XCTAssertEqual(calls, [.health])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(cursor, SyncCursor())
    }

    func testPullFailurePreservesCursorAndOutbox() async throws {
        let initial = SyncCursor(
            token: Data("initial".utf8),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let fixture = try await makeFixture(mode: .pullFailure, initialCursor: initial)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync(try await fixture.services.syncNow())

        let recording = await fixture.transport.recording()
        let pending = try await fixture.store.pendingEnvelopes(limit: 10)
        let cursor = try await fixture.store.loadSyncCursor(
            transportIdentifier: fixture.transport.identifier
        )
        XCTAssertEqual(recording.calls, [.health, .pull])
        XCTAssertEqual(recording.pulledCursors, [initial])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(cursor, initial)
    }

    func testPushFailureKeepsEnvelopePendingAndRetryIsIdempotent() async throws {
        let pulled = SyncCursor(
            token: Data("remote-page".utf8),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let fixture = try await makeFixture(mode: .pushFailure, pulledCursor: pulled)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync(try await fixture.services.syncNow())

        let failedRecording = await fixture.transport.recording()
        let pendingAfterFailure = try await fixture.store.pendingEnvelopes(limit: 10)
        let cursorAfterFailure = try await fixture.store.loadSyncCursor(
            transportIdentifier: fixture.transport.identifier
        )
        XCTAssertEqual(failedRecording.calls, [.health, .pull, .push])
        XCTAssertEqual(pendingAfterFailure.count, 1)
        XCTAssertEqual(
            cursorAfterFailure,
            pulled,
            "A completed pull remains durable even when the independent upload fails"
        )

        await fixture.transport.setMode(.healthy)
        try await fixture.services.syncNow()

        let pendingAfterRetry = try await fixture.store.pendingEnvelopes(limit: 10)
        let successfulRecording = await fixture.transport.recording()
        XCTAssertTrue(pendingAfterRetry.isEmpty)
        XCTAssertEqual(successfulRecording.pushBatchSizes, [1, 1])
        XCTAssertEqual(successfulRecording.pulledCursors, [SyncCursor(), pulled])
    }

    func testSuccessfulSyncClearsPreviousUnavailableDiagnostic() async throws {
        let fixture = try await makeFixture(mode: .unhealthy)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync(try await fixture.services.syncNow())
        var health = await fixture.services.healthSnapshot()
        XCTAssertTrue(health.issues.contains { $0.id == "sync-unavailable" })

        await fixture.transport.setMode(.healthy)
        try await fixture.services.syncNow()
        health = await fixture.services.healthSnapshot()
        XCTAssertFalse(health.issues.contains { $0.id == "sync-unavailable" })
    }

    private func makeFixture(
        mode: FailureTransport.Mode,
        initialCursor: SyncCursor = SyncCursor(),
        pulledCursor: SyncCursor? = nil
    ) async throws -> FailureFixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSyncFailureTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = RuntimeConfiguration(
            applicationSupportURL: root,
            codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
        )
        let store = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: "failure-device",
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: true
        )
        try await store.migrate()
        try await store.upsert(failureConversation())

        let transport = FailureTransport(mode: mode, pulledCursor: pulledCursor)
        try await store.saveSyncCursor(initialCursor, transportIdentifier: transport.identifier)
        let registry = ReadyFailureRegistry()
        let services = ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: registry.currentDeviceID,
            providers: ProviderRegistry(adapters: [:]),
            transport: transport,
            deviceRegistry: registry,
            cloudKitAuthorized: true,
            syncCursor: initialCursor
        )
        return FailureFixture(
            root: root,
            store: store,
            transport: transport,
            services: services
        )
    }
}

private struct FailureFixture {
    let root: URL
    let store: SQLiteConversationStore
    let transport: FailureTransport
    let services: ApplicationServices

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FailureTransport: SyncTransport {
    enum Mode: Sendable {
        case healthy
        case unhealthy
        case pullFailure
        case pushFailure
    }

    enum Call: Equatable, Sendable {
        case health
        case pull
        case push
    }

    struct Recording: Sendable {
        let calls: [Call]
        let pulledCursors: [SyncCursor]
        let pushBatchSizes: [Int]
    }

    nonisolated let identifier = "failure-transport"
    private var mode: Mode
    private let pulledCursor: SyncCursor?
    private(set) var calls: [Call] = []
    private(set) var pulledCursors: [SyncCursor] = []
    private(set) var pushBatchSizes: [Int] = []

    init(mode: Mode, pulledCursor: SyncCursor?) {
        self.mode = mode
        self.pulledCursor = pulledCursor
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func recordedCalls() -> [Call] { calls }

    func recording() -> Recording {
        Recording(
            calls: calls,
            pulledCursors: pulledCursors,
            pushBatchSizes: pushBatchSizes
        )
    }

    func healthCheck() async -> Bool {
        calls.append(.health)
        return mode != .unhealthy
    }

    func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        calls.append(.pull)
        pulledCursors.append(cursor)
        if mode == .pullFailure {
            throw ThreadlineError.unavailable("Injected pull failure")
        }
        return SyncPullResult(envelopes: [], cursor: pulledCursor ?? cursor)
    }

    func push(_ envelopes: [SyncEnvelope]) async throws {
        calls.append(.push)
        pushBatchSizes.append(envelopes.count)
        if mode == .pushFailure {
            throw ThreadlineError.unavailable("Injected push failure")
        }
    }
}

private actor ReadyFailureRegistry: DeviceRegistry {
    nonisolated let currentDeviceID = "failure-device"

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

private func failureConversation() -> ProviderConversation {
    let date = Date(timeIntervalSince1970: 50)
    let summary = ConversationSummary(
        id: "failure-conversation",
        provider: .codex,
        providerSessionID: "failure-session",
        title: "Failure semantics",
        createdAt: date,
        updatedAt: date,
        originDeviceID: "failure-device",
        messageCount: 1
    )
    return ProviderConversation(
        summary: summary,
        events: [ConversationEvent(
            id: "failure-event",
            conversationID: summary.id,
            sequence: 1,
            timestamp: date,
            kind: .userMessage,
            role: .user,
            text: "Keep this pending until delivery succeeds",
            contentHash: "failure-event-hash",
            sourceDeviceID: "failure-device"
        )],
        sourceFingerprint: "failure-source",
        sourceSchemaVersion: "test-v1"
    )
}

@MainActor
private func XCTAssertThrowsErrorAsync<T: Sendable>(
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
