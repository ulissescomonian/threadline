import ConversationCore
import Foundation
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class TransportSwitchingTests: XCTestCase {
    func testTransportCursorsRemainIsolatedWhenSwitchingAwayAndBack() async throws {
        let fixture = try SwitchingFixture()
        defer { fixture.cleanup() }
        let store = try SQLiteConversationStore(
            databaseURL: fixture.databaseURL,
            deviceID: "switch-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await store.migrate()
        let firstCursor = SyncCursor(
            token: Data("first-cursor".utf8),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let secondCursor = SyncCursor(
            token: Data("second-cursor".utf8),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try await store.saveSyncCursor(firstCursor, transportIdentifier: "folder-space-first")
        let untouchedSecond = try await store.loadSyncCursor(
            transportIdentifier: "folder-space-second"
        )
        XCTAssertEqual(untouchedSecond, SyncCursor())
        try await store.saveSyncCursor(secondCursor, transportIdentifier: "folder-space-second")

        let resumedFirst = try await store.loadSyncCursor(transportIdentifier: "folder-space-first")
        let resumedSecond = try await store.loadSyncCursor(transportIdentifier: "folder-space-second")
        XCTAssertEqual(resumedFirst, firstCursor)
        XCTAssertEqual(resumedSecond, secondCursor)
    }

    func testLocalLibraryIsPromotedOnlyAfterRemoteQueueIsEnabled() async throws {
        let fixture = try SwitchingFixture()
        defer { fixture.cleanup() }
        var localStore: SQLiteConversationStore? = try SQLiteConversationStore(
            databaseURL: fixture.databaseURL,
            deviceID: "switch-device",
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: false
        )
        try await localStore?.migrate()
        try await localStore?.upsert(switchingConversation())
        let localPending = try await localStore?.pendingEnvelopes(limit: 10) ?? []
        let localSummaries = try await localStore?.listConversations(
            query: nil,
            provider: nil,
            favoritesOnly: false
        ) ?? []
        let localSummary = try XCTUnwrap(localSummaries.first)
        XCTAssertTrue(localPending.isEmpty)
        XCTAssertEqual(localSummary.syncAvailability, .localOnly)

        localStore = nil
        let folderEnabledStore = try SQLiteConversationStore(
            databaseURL: fixture.databaseURL,
            deviceID: "switch-device",
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: true
        )
        try await folderEnabledStore.migrate()

        let promoted = try await folderEnabledStore.pendingEnvelopes(limit: 10)
        let promotedSummaries = try await folderEnabledStore.listConversations(
            query: nil,
            provider: nil,
            favoritesOnly: false
        )
        let promotedSummary = try XCTUnwrap(promotedSummaries.first)
        XCTAssertEqual(promoted.count, 1)
        XCTAssertEqual(promotedSummary.syncAvailability, .queued)
    }

    func testProviderMigrationPreservesSyncSpaceAndRecoveryKey() async throws {
        let fixture = try SwitchingFixture()
        defer { fixture.cleanup() }
        let sourceFolder = fixture.root.appending(path: "OneDrive", directoryHint: .isDirectory)
        let destinationFolder = fixture.root.appending(path: "GoogleDrive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let keyStore = InMemoryKeyMaterialStore()
        let configurations = SyncConfigurationStore(
            applicationSupportURL: fixture.supportURL,
            keyStore: keyStore
        )
        let created = try await configurations.configure(
            location: .oneDrive,
            intent: .create,
            folderURL: sourceFolder,
            recoveryKey: nil,
            deviceID: "switch-device"
        )
        let originalSpaceID = try XCTUnwrap(created.snapshot.syncSpaceID)
        let key = try SyncConfigurationStore.decodeRecoveryKey(XCTUnwrap(created.recoveryKey))

        let migrated = try await configurations.migrate(
            to: .googleDrive,
            folderURL: destinationFolder
        )
        let copiedManifest = try FolderSyncManifest.load(from: destinationFolder, keyData: key)

        XCTAssertEqual(migrated.location, .googleDrive)
        XCTAssertEqual(migrated.connectionState, .ready)
        XCTAssertEqual(migrated.syncSpaceID, originalSpaceID)
        XCTAssertEqual(copiedManifest.syncSpaceID, originalSpaceID)
        let persisted = await configurations.snapshot()
        XCTAssertEqual(persisted.syncSpaceID, originalSpaceID)
    }
}

private struct SwitchingFixture {
    let root: URL
    let supportURL: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineTransportSwitchingTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        supportURL = root.appending(path: "support", directoryHint: .isDirectory)
        databaseURL = supportURL.appending(path: "Threadline.sqlite")
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func switchingConversation() -> ProviderConversation {
    let timestamp = Date(timeIntervalSince1970: 100)
    let summary = ConversationSummary(
        id: "switching-conversation",
        provider: .claude,
        providerSessionID: "switching-session",
        title: "Promote after transport activation",
        createdAt: timestamp,
        updatedAt: timestamp,
        originDeviceID: "switch-device",
        messageCount: 1
    )
    return ProviderConversation(
        summary: summary,
        events: [ConversationEvent(
            id: "switching-event",
            conversationID: summary.id,
            sequence: 1,
            timestamp: timestamp,
            kind: .assistantMessage,
            role: .assistant,
            text: "Queue me only after folder sync is ready",
            contentHash: "switching-event-hash",
            sourceDeviceID: "switch-device"
        )],
        sourceFingerprint: "switching-source",
        sourceSchemaVersion: "test-v1"
    )
}
