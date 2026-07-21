import ConversationCore
import Foundation
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class KeyRecoveryFlowTests: XCTestCase {
    func testCreateAndJoinUseRecoveryKeyForTheSameAuthenticatedSpace() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }

        let creator = SyncConfigurationStore(
            applicationSupportURL: fixture.creatorSupport,
            keyStore: InMemoryKeyMaterialStore()
        )
        let created = try await creator.configure(
            location: .oneDrive,
            intent: .create,
            folderURL: fixture.syncFolder,
            recoveryKey: nil,
            deviceID: "creator-device"
        )
        let recoveryKey = try XCTUnwrap(created.recoveryKey)
        XCTAssertTrue(recoveryKey.hasPrefix("TL1-"))
        XCTAssertEqual(created.snapshot.connectionState, .ready)

        let joiner = SyncConfigurationStore(
            applicationSupportURL: fixture.joinerSupport,
            keyStore: InMemoryKeyMaterialStore()
        )
        let joined = try await joiner.configure(
            location: .oneDrive,
            intent: .join,
            folderURL: fixture.syncFolder,
            recoveryKey: recoveryKey,
            deviceID: "joiner-device"
        )

        XCTAssertNil(joined.recoveryKey)
        XCTAssertEqual(joined.snapshot.connectionState, .ready)
        XCTAssertEqual(joined.snapshot.syncSpaceID, created.snapshot.syncSpaceID)
        let persistedJoinerSnapshot = await joiner.snapshot()
        XCTAssertEqual(persistedJoinerSnapshot.syncSpaceID, created.snapshot.syncSpaceID)
    }

    func testWrongRecoveryKeyCannotReplaceOrJoinExistingSpace() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let creator = SyncConfigurationStore(
            applicationSupportURL: fixture.creatorSupport,
            keyStore: InMemoryKeyMaterialStore()
        )
        let created = try await creator.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: fixture.syncFolder,
            recoveryKey: nil,
            deviceID: "creator-device"
        )
        let originalSpaceID = try XCTUnwrap(created.snapshot.syncSpaceID)

        let wrongKey = SyncConfigurationStore.encodeRecoveryKey(Data(repeating: 0xEE, count: 32))
        let joiner = SyncConfigurationStore(
            applicationSupportURL: fixture.joinerSupport,
            keyStore: InMemoryKeyMaterialStore()
        )
        do {
            _ = try await joiner.configure(
                location: .iCloudDrive,
                intent: .join,
                folderURL: fixture.syncFolder,
                recoveryKey: wrongKey,
                deviceID: "joiner-device"
            )
            XCTFail("A different recovery key must not join an existing space")
        } catch {
            // The authenticated manifest must reject the unrelated key.
        }

        let rejectedJoinerSnapshot = await joiner.snapshot()
        XCTAssertEqual(rejectedJoinerSnapshot, .localOnly)
        let manifest = try FolderSyncManifest.load(
            from: fixture.syncFolder,
            keyData: try SyncConfigurationStore.decodeRecoveryKey(
                XCTUnwrap(created.recoveryKey)
            )
        )
        XCTAssertEqual(manifest.syncSpaceID, originalSpaceID)
    }

    func testRecoveryKeyCodecRejectsMalformedAndWrongLengthValues() throws {
        let key = Data((0..<32).map(UInt8.init))
        let encoded = SyncConfigurationStore.encodeRecoveryKey(key)
        XCTAssertEqual(try SyncConfigurationStore.decodeRecoveryKey(encoded), key)
        XCTAssertEqual(
            try SyncConfigurationStore.decodeRecoveryKey("  \(encoded)\n"),
            key
        )

        for invalid in [
            "",
            "TL0-not-threadline",
            "TL1-not-base64!",
            SyncConfigurationStore.encodeRecoveryKey(Data(repeating: 1, count: 31)),
            SyncConfigurationStore.encodeRecoveryKey(Data(repeating: 1, count: 33)),
        ] {
            XCTAssertThrowsError(try SyncConfigurationStore.decodeRecoveryKey(invalid))
        }
    }

    func testPersistedConfigurationWithoutItsKeyFailsClosed() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let originalKeyStore = InMemoryKeyMaterialStore()
        let creator = SyncConfigurationStore(
            applicationSupportURL: fixture.creatorSupport,
            keyStore: originalKeyStore
        )
        let created = try await creator.configure(
            location: .googleDrive,
            intent: .create,
            folderURL: fixture.syncFolder,
            recoveryKey: nil,
            deviceID: "creator-device"
        )

        let reopenedWithoutKey = SyncConfigurationStore(
            applicationSupportURL: fixture.creatorSupport,
            keyStore: InMemoryKeyMaterialStore()
        )
        let snapshot = await reopenedWithoutKey.snapshot()

        XCTAssertEqual(snapshot.location, .googleDrive)
        XCTAssertEqual(snapshot.syncSpaceID, created.snapshot.syncSpaceID)
        guard case .unavailable = snapshot.connectionState else {
            return XCTFail("A saved folder without its key must remain unavailable")
        }
    }

    func testCreateRollsBackManifestWhenKeyPersistenceFails() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let configurations = SyncConfigurationStore(
            applicationSupportURL: fixture.creatorSupport,
            keyStore: RejectingRecoveryKeyStore()
        )

        do {
            _ = try await configurations.configure(
                location: .oneDrive,
                intent: .create,
                folderURL: fixture.syncFolder,
                recoveryKey: nil,
                deviceID: "creator-device"
            )
            XCTFail("Injected Keychain persistence must fail setup")
        } catch {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.syncFolder.appending(
            path: FolderSyncManifest.fileName
        ).path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.syncFolder.path),
            [],
            "A failed create must leave the selected folder reusable"
        )
        let snapshot = await configurations.snapshot()
        XCTAssertEqual(snapshot, .localOnly)
    }
}

private struct RecoveryFixture {
    let root: URL
    let creatorSupport: URL
    let joinerSupport: URL
    let syncFolder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineKeyRecoveryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        creatorSupport = root.appending(path: "creator-support", directoryHint: .isDirectory)
        joinerSupport = root.appending(path: "joiner-support", directoryHint: .isDirectory)
        syncFolder = root.appending(path: "shared-space", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: creatorSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: joinerSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RejectingRecoveryKeyStore: KeyMaterialStore {
    func load(service: String, account: String) throws -> Data? { nil }

    func save(_ data: Data, service: String, account: String) throws {
        throw ThreadlineError.encryption("Injected Keychain write failure")
    }

    func delete(service: String, account: String) throws {}
}
