import ConversationCore
import Foundation
import ProviderKit
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class FolderSyncEndToEndTests: XCTestCase {
    func testTwoIndependentMacRuntimesExchangeEncryptedConversationAndDiscoverDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineFolderEndToEnd-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let syncFolder = root.appending(path: "shared", directoryHint: .isDirectory)
        let supportA = root.appending(path: "mac-a", directoryHint: .isDirectory)
        let supportB = root.appending(path: "mac-b", directoryHint: .isDirectory)
        for directory in [syncFolder, supportA, supportB] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let key = Data((0..<32).map(UInt8.init))
        let manifest = try FolderSyncManifest.create(
            at: syncFolder,
            keyData: key,
            createdByDeviceID: "mac-a"
        )
        let storeA = try makeStore(at: supportA, deviceID: "mac-a", key: key)
        let storeB = try makeStore(at: supportB, deviceID: "mac-b", key: key)
        try await storeA.migrate()
        try await storeB.migrate()

        let registryA = makeRegistry(
            id: "mac-a",
            name: "Studio Mac",
            root: syncFolder,
            support: supportA,
            key: key,
            fingerprint: manifest.keyFingerprint
        )
        let registryB = makeRegistry(
            id: "mac-b",
            name: "Travel Mac",
            root: syncFolder,
            support: supportB,
            key: key,
            fingerprint: manifest.keyFingerprint
        )
        let servicesA = makeServices(
            support: supportA,
            deviceID: "mac-a",
            store: storeA,
            transport: FolderSyncTransport(
                rootURL: syncFolder,
                manifest: manifest,
                currentDeviceID: "mac-a"
            ),
            registry: registryA
        )
        let servicesB = makeServices(
            support: supportB,
            deviceID: "mac-b",
            store: storeB,
            transport: FolderSyncTransport(
                rootURL: syncFolder,
                manifest: manifest,
                currentDeviceID: "mac-b"
            ),
            registry: registryB
        )

        try await storeA.upsert(conversation(originDeviceID: "mac-a"))
        try await servicesA.syncNow()
        try await servicesB.syncNow()

        let received = try await storeB.conversation(id: "end-to-end-conversation")
        XCTAssertEqual(received?.summary.title, "A private shared thread")
        XCTAssertEqual(received?.events.map(\.text), ["Visible only after local decryption"])
        XCTAssertEqual(received?.summary.syncAvailability, .availableOffline)
        let pendingOnB = try await storeB.pendingEnvelopes(limit: 10)
        XCTAssertTrue(pendingOnB.isEmpty)

        let devices = await servicesA.devicesSnapshot(refreshRemote: true)
        XCTAssertEqual(devices.readiness, .ready)
        XCTAssertEqual(Set(devices.devices.map(\.id)), ["mac-a", "mac-b"])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: devices.devices.map { ($0.id, $0.displayName) }),
            ["mac-a": "Studio Mac", "mac-b": "Travel Mac"]
        )
    }

    private func makeStore(
        at support: URL,
        deviceID: String,
        key: Data
    ) throws -> SQLiteConversationStore {
        try SQLiteConversationStore(
            databaseURL: support.appending(path: "Threadline.sqlite"),
            deviceID: deviceID,
            envelopeCodec: EncryptedEnvelopeCodec(keyData: key),
            queuesForSync: true
        )
    }

    private func makeRegistry(
        id: String,
        name: String,
        root: URL,
        support: URL,
        key: Data,
        fingerprint: String
    ) -> FolderDeviceRegistry {
        FolderDeviceRegistry(
            profile: DeviceProfile(
                id: id,
                displayName: name,
                modelIdentifier: "TestMac",
                systemVersion: "test",
                appVersion: "test"
            ),
            rootURL: root,
            keyData: key,
            keyFingerprint: fingerprint,
            cacheURL: support.appending(path: "devices.json")
        )
    }

    private func makeServices(
        support: URL,
        deviceID: String,
        store: SQLiteConversationStore,
        transport: FolderSyncTransport,
        registry: FolderDeviceRegistry
    ) -> ApplicationServices {
        let configuration = RuntimeConfiguration(
            applicationSupportURL: support,
            codexHomeURL: support.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: support.appending(path: "claude", directoryHint: .isDirectory)
        )
        return ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: deviceID,
            providers: ProviderRegistry(adapters: [:]),
            transport: transport,
            deviceRegistry: registry,
            remoteSyncConfigured: true,
            transportDisplayName: "Test Folder"
        )
    }

    private func conversation(originDeviceID: String) -> ProviderConversation {
        let date = Date(timeIntervalSince1970: 1_000)
        let summary = ConversationSummary(
            id: "end-to-end-conversation",
            provider: .codex,
            providerSessionID: "end-to-end-session",
            title: "A private shared thread",
            preview: "Visible only after local decryption",
            createdAt: date,
            updatedAt: date,
            originDeviceID: originDeviceID,
            messageCount: 1
        )
        return ProviderConversation(
            summary: summary,
            events: [ConversationEvent(
                id: "end-to-end-event",
                conversationID: summary.id,
                sequence: 1,
                timestamp: date,
                kind: .userMessage,
                role: .user,
                text: "Visible only after local decryption",
                contentHash: "end-to-end-content",
                sourceDeviceID: originDeviceID
            )],
            sourceFingerprint: "end-to-end-source",
            sourceSchemaVersion: "test-v1"
        )
    }
}
