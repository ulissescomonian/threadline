import ConversationCore
import Foundation
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class SyncMigrationSafetyTests: XCTestCase {
    func testMigrationCopiesAndVerifiesRecursiveSpaceWithoutChangingItsIdentity() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let destination = try fixture.folder("OneDrive")
        let keyStore = InMemoryKeyMaterialStore()
        let configurations = SyncConfigurationStore(
            applicationSupportURL: fixture.support("primary"),
            keyStore: keyStore
        )
        let created = try await configurations.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "migration-device"
        )
        let recoveryKey = try XCTUnwrap(created.recoveryKey)
        let keyData = try SyncConfigurationStore.decodeRecoveryKey(recoveryKey)
        let originalSpaceID = try XCTUnwrap(created.snapshot.syncSpaceID)

        let nested = source.appending(path: "devices/device-a/segments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let segmentData = Data((0..<32_768).map { UInt8($0 % 251) })
        let sourceSegment = nested.appending(path: "00000001.tlsegment")
        try segmentData.write(to: sourceSegment, options: .atomic)

        let migrated = try await configurations.migrate(
            to: .oneDrive,
            folderURL: destination
        )

        XCTAssertEqual(migrated.location, .oneDrive)
        XCTAssertEqual(migrated.syncSpaceID, originalSpaceID)
        XCTAssertEqual(try Data(contentsOf: sourceSegment), segmentData)
        XCTAssertEqual(
            try Data(contentsOf: destination.appending(path: "devices/device-a/segments/00000001.tlsegment")),
            segmentData
        )
        let manifest = try FolderSyncManifest.load(from: destination, keyData: keyData)
        XCTAssertEqual(manifest.syncSpaceID, originalSpaceID)
        let resolved = try await configurations.resolvedConfiguration()
        XCTAssertEqual(resolved?.keyData, keyData)
    }

    func testFollowExistingMigrationSwitchesProviderWithoutCopyingOrChangingKey() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let destination = try fixture.folder("OneDrive")

        let coordinator = SyncConfigurationStore(
            applicationSupportURL: fixture.support("coordinator"),
            keyStore: InMemoryKeyMaterialStore()
        )
        let created = try await coordinator.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "coordinator-device"
        )
        let recoveryKey = try XCTUnwrap(created.recoveryKey)
        let keyData = try SyncConfigurationStore.decodeRecoveryKey(recoveryKey)
        let payloadURL = source.appending(path: "migration-proof.bin")
        let payload = Data("immutable encrypted payload".utf8)
        try payload.write(to: payloadURL, options: .atomic)
        _ = try await coordinator.migrate(to: .oneDrive, folderURL: destination)

        let follower = SyncConfigurationStore(
            applicationSupportURL: fixture.support("follower"),
            keyStore: InMemoryKeyMaterialStore()
        )
        let joined = try await follower.configure(
            location: .iCloudDrive,
            intent: .join,
            folderURL: source,
            recoveryKey: recoveryKey,
            deviceID: "follower-device"
        )
        let sourceBefore = try Data(contentsOf: payloadURL)
        let destinationPayloadURL = destination.appending(path: "migration-proof.bin")
        let destinationBefore = try Data(contentsOf: destinationPayloadURL)

        let followed = try await follower.followExistingMigration(
            to: .oneDrive,
            folderURL: destination
        )

        XCTAssertEqual(followed.location, .oneDrive)
        XCTAssertEqual(followed.syncSpaceID, joined.snapshot.syncSpaceID)
        XCTAssertEqual(try Data(contentsOf: payloadURL), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: destinationPayloadURL), destinationBefore)
        let resolved = try await follower.resolvedConfiguration()
        XCTAssertEqual(resolved?.keyData, keyData)
    }

    func testFollowExistingMigrationRejectsMismatchedSpaceAndKeepsConfiguration() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let mismatchedDestination = try fixture.folder("OneDrive")
        let support = fixture.support("follower")
        let configurations = SyncConfigurationStore(
            applicationSupportURL: support,
            keyStore: InMemoryKeyMaterialStore()
        )
        let created = try await configurations.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "follower-device"
        )
        let keyData = try SyncConfigurationStore.decodeRecoveryKey(XCTUnwrap(created.recoveryKey))
        _ = try FolderSyncManifest.create(
            at: mismatchedDestination,
            keyData: keyData,
            createdByDeviceID: "other-device"
        )
        let configurationURL = support.appending(path: "sync-configuration.json")
        let configurationBefore = try Data(contentsOf: configurationURL)

        do {
            _ = try await configurations.followExistingMigration(
                to: .oneDrive,
                folderURL: mismatchedDestination
            )
            XCTFail("A different sync space must not replace the active configuration")
        } catch let error as SyncConfigurationError {
            XCTAssertEqual(error, .spaceMismatch)
        }

        XCTAssertEqual(try Data(contentsOf: configurationURL), configurationBefore)
        let snapshot = await configurations.snapshot()
        XCTAssertEqual(snapshot.location, .iCloudDrive)
        XCTAssertEqual(snapshot.syncSpaceID, created.snapshot.syncSpaceID)
    }

    func testFollowExistingMigrationAllowsAnotherFolderInSameProvider() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud-original")
        let destination = try fixture.folder("iCloud-moved")

        let coordinator = SyncConfigurationStore(
            applicationSupportURL: fixture.support("coordinator"),
            keyStore: InMemoryKeyMaterialStore()
        )
        let created = try await coordinator.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "coordinator-device"
        )
        let recoveryKey = try XCTUnwrap(created.recoveryKey)
        _ = try await coordinator.migrate(to: .iCloudDrive, folderURL: destination)

        let follower = SyncConfigurationStore(
            applicationSupportURL: fixture.support("follower"),
            keyStore: InMemoryKeyMaterialStore()
        )
        _ = try await follower.configure(
            location: .iCloudDrive,
            intent: .join,
            folderURL: source,
            recoveryKey: recoveryKey,
            deviceID: "follower-device"
        )

        let followed = try await follower.followExistingMigration(
            to: .iCloudDrive,
            folderURL: destination
        )

        XCTAssertEqual(followed.location, .iCloudDrive)
        XCTAssertEqual(followed.folderDisplayName, destination.lastPathComponent)
        XCTAssertEqual(followed.syncSpaceID, created.snapshot.syncSpaceID)
    }

    func testFollowExistingMigrationRejectsCurrentFolderAndKeepsConfiguration() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let support = fixture.support("follower")
        let configurations = SyncConfigurationStore(
            applicationSupportURL: support,
            keyStore: InMemoryKeyMaterialStore()
        )
        let created = try await configurations.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "follower-device"
        )
        let configurationURL = support.appending(path: "sync-configuration.json")
        let configurationBefore = try Data(contentsOf: configurationURL)

        do {
            _ = try await configurations.followExistingMigration(
                to: .iCloudDrive,
                folderURL: source
            )
            XCTFail("Following the currently active folder must be rejected")
        } catch let error as SyncConfigurationError {
            XCTAssertEqual(error, .sameFolder)
        }

        XCTAssertEqual(try Data(contentsOf: configurationURL), configurationBefore)
        let snapshot = await configurations.snapshot()
        XCTAssertEqual(snapshot.location, .iCloudDrive)
        XCTAssertEqual(snapshot.syncSpaceID, created.snapshot.syncSpaceID)
    }

    func testMigrationRejectsPartialDestinationAndKeepsBothSidesUntouched() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let destination = try fixture.folder("OneDrive")
        let support = fixture.support("primary")
        let configurations = SyncConfigurationStore(
            applicationSupportURL: support,
            keyStore: InMemoryKeyMaterialStore()
        )
        _ = try await configurations.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "migration-device"
        )
        let partialURL = destination.appending(path: "partial-copy")
        let partialData = Data("do not remove user data".utf8)
        try partialData.write(to: partialURL, options: .atomic)
        let configurationURL = support.appending(path: "sync-configuration.json")
        let configurationBefore = try Data(contentsOf: configurationURL)
        let sourceManifestBefore = try Data(
            contentsOf: source.appending(path: FolderSyncManifest.fileName)
        )

        do {
            _ = try await configurations.migrate(to: .oneDrive, folderURL: destination)
            XCTFail("A partially populated destination must be rejected")
        } catch let error as SyncConfigurationError {
            XCTAssertEqual(error, .folderNotEmpty)
        }

        XCTAssertEqual(try Data(contentsOf: configurationURL), configurationBefore)
        XCTAssertEqual(try Data(contentsOf: partialURL), partialData)
        XCTAssertEqual(
            try Data(contentsOf: source.appending(path: FolderSyncManifest.fileName)),
            sourceManifestBefore
        )
    }

    func testMigrationDetectsCopiedCorruptionRollsBackDestinationAndKeepsConfiguration() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let destination = try fixture.folder("OneDrive")
        let support = fixture.support("primary")
        let keyStore = InMemoryKeyMaterialStore()
        let bootstrapConfigurations = SyncConfigurationStore(
            applicationSupportURL: support,
            keyStore: keyStore
        )
        let created = try await bootstrapConfigurations.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "migration-device"
        )
        let keyData = try SyncConfigurationStore.decodeRecoveryKey(XCTUnwrap(created.recoveryKey))
        let nested = source.appending(path: "devices/device-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("profile".utf8).write(to: nested.appending(path: "profile.tldevice"))
        let configurationURL = support.appending(path: "sync-configuration.json")
        let configurationBefore = try Data(contentsOf: configurationURL)
        let fileManager = CorruptingCopyFileManager()
        fileManager.corruptCopiedManifest = true
        let configurations = SyncConfigurationStore(
            applicationSupportURL: support,
            keyStore: keyStore,
            fileManager: fileManager
        )

        do {
            _ = try await configurations.migrate(to: .oneDrive, folderURL: destination)
            XCTFail("Post-copy inventory must detect corruption")
        } catch let error as SyncConfigurationError {
            XCTAssertEqual(error, .migrationVerificationFailed)
        }

        XCTAssertEqual(try Data(contentsOf: configurationURL), configurationBefore)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let sourceManifest = try FolderSyncManifest.load(from: source, keyData: keyData)
        XCTAssertEqual(sourceManifest.syncSpaceID, created.snapshot.syncSpaceID)
    }

    func testMigrationRejectsSymbolicLinksBeforeCopying() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanup() }
        let source = try fixture.folder("iCloud")
        let destination = try fixture.folder("OneDrive")
        let support = fixture.support("primary")
        let configurations = SyncConfigurationStore(
            applicationSupportURL: support,
            keyStore: InMemoryKeyMaterialStore()
        )
        _ = try await configurations.configure(
            location: .iCloudDrive,
            intent: .create,
            folderURL: source,
            recoveryKey: nil,
            deviceID: "migration-device"
        )
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "unsafe-link"),
            withDestinationURL: source.appending(path: FolderSyncManifest.fileName)
        )
        let configurationURL = support.appending(path: "sync-configuration.json")
        let configurationBefore = try Data(contentsOf: configurationURL)

        do {
            _ = try await configurations.migrate(to: .oneDrive, folderURL: destination)
            XCTFail("A symbolic link must not enter a migrated sync space")
        } catch let error as SyncConfigurationError {
            XCTAssertEqual(error, .migrationUnsafeEntry)
        }

        XCTAssertEqual(try Data(contentsOf: configurationURL), configurationBefore)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}

private struct MigrationFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineSyncMigrationSafetyTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func support(_ name: String) -> URL {
        root.appending(path: "support-\(name)", directoryHint: .isDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CorruptingCopyFileManager: FileManager, @unchecked Sendable {
    var corruptCopiedManifest = false

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.copyItem(at: sourceURL, to: destinationURL)
        if corruptCopiedManifest,
           sourceURL.lastPathComponent == FolderSyncManifest.fileName {
            try Data("corrupted after copy".utf8).write(to: destinationURL, options: .atomic)
        }
    }
}
