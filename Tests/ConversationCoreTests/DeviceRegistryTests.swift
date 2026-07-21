import CloudKit
import Foundation
import XCTest
@testable import ConversationCore

@MainActor
final class DeviceRegistryTests: XCTestCase {
    func testModelsRoundTripAssociatedReadinessAndRetirement() throws {
        let retiredAt = Date(timeIntervalSince1970: 400)
        let device = RegisteredDevice(
            id: "mac-mini",
            displayName: "Studio",
            modelIdentifier: "Mac14,3",
            systemVersion: "15.5",
            appVersion: "1.0 (42)",
            registeredAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 300),
            retiredAt: retiredAt
        )
        let snapshot = DeviceRegistrySnapshot(
            currentDeviceID: device.id,
            devices: [device],
            readiness: .localOnly(reason: "Unsigned build"),
            refreshedAt: Date(timeIntervalSince1970: 500)
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DeviceRegistrySnapshot.self, from: encoded)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.devices[0].isRetired)
        XCTAssertEqual(decoded.devices[0].retiredAt, retiredAt)
    }

    func testLocalRegistryPersistsPrivateCacheAndPreservesChosenName() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let profile = Self.profile(id: "device-a", displayName: "This Mac")
        let registry = LocalDeviceRegistry(
            profile: profile,
            cacheURL: fixture.cacheURL,
            reason: "Local engineering build",
            now: clock.read
        )

        XCTAssertEqual(registry.currentDeviceID, profile.id)
        var snapshot = await registry.cachedSnapshot()
        XCTAssertEqual(snapshot.devices.map(\.id), [profile.id])
        XCTAssertEqual(snapshot.readiness, .localOnly(reason: "Local engineering build"))

        snapshot = await registry.renameDevice(id: profile.id, displayName: "  Work Studio  ")
        XCTAssertEqual(snapshot.devices[0].displayName, "Work Studio")
        XCTAssertEqual(try permissionBits(at: fixture.directory.path), 0o700)
        XCTAssertEqual(try permissionBits(at: fixture.cacheURL.path), 0o600)

        let relaunched = LocalDeviceRegistry(
            profile: profile,
            cacheURL: fixture.cacheURL,
            reason: "Local engineering build",
            now: clock.read
        )
        let reloaded = await relaunched.cachedSnapshot()
        XCTAssertEqual(reloaded.currentDeviceID, profile.id)
        XCTAssertEqual(reloaded.devices.first?.displayName, "Work Studio")
    }

    func testLocalRegistryDoesNotHeartbeatOrReactivateRetiredDeviceImplicitly() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let registry = LocalDeviceRegistry(
            profile: Self.profile(id: "device-a"),
            cacheURL: fixture.cacheURL,
            now: clock.read
        )

        var snapshot = await registry.retireDevice(id: "device-a")
        let retiredAt = try XCTUnwrap(snapshot.devices.first?.retiredAt)
        let lastSeenAt = try XCTUnwrap(snapshot.devices.first?.lastSeenAt)

        clock.set(Date(timeIntervalSince1970: 500))
        snapshot = await registry.prepareForSync()
        XCTAssertEqual(snapshot.devices.first?.retiredAt, retiredAt)
        XCTAssertEqual(snapshot.devices.first?.lastSeenAt, lastSeenAt)

        snapshot = await registry.reactivateCurrentDevice()
        XCTAssertFalse(try XCTUnwrap(snapshot.devices.first).isRetired)
        XCTAssertEqual(snapshot.devices.first?.lastSeenAt, Date(timeIntervalSince1970: 500))
    }

    func testLocalRegistryRebuildsSnapshotForNewInstallationIdentity() async throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let first = LocalDeviceRegistry(
            profile: Self.profile(id: "old-install"),
            cacheURL: fixture.cacheURL
        )
        _ = await first.renameDevice(id: "old-install", displayName: "Previous Install")

        let replacement = LocalDeviceRegistry(
            profile: Self.profile(id: "new-install"),
            cacheURL: fixture.cacheURL
        )
        let snapshot = await replacement.cachedSnapshot()

        XCTAssertEqual(replacement.currentDeviceID, "new-install")
        XCTAssertEqual(snapshot.currentDeviceID, "new-install")
        XCTAssertTrue(snapshot.devices.contains { $0.id == "old-install" })
        XCTAssertTrue(snapshot.devices.contains { $0.id == "new-install" })
    }

    func testCloudKitDeviceRecordMappingUsesOnlyApprovedMetadata() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitDeviceRegistry.defaultZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let profile = Self.profile(id: "device-a", displayName: "Studio")
        let registeredAt = Date(timeIntervalSince1970: 100)
        let lastSeenAt = Date(timeIntervalSince1970: 200)
        let record = CloudDeviceRecordMapper.makeDeviceRecord(
            profile: profile,
            registeredAt: registeredAt,
            lastSeenAt: lastSeenAt,
            zoneID: zoneID
        )

        let decoded = try CloudDeviceRecordMapper.decodeDevice(record)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.displayName, profile.displayName)
        XCTAssertEqual(decoded.modelIdentifier, profile.modelIdentifier)
        XCTAssertEqual(decoded.registeredAt, registeredAt)
        XCTAssertEqual(decoded.lastSeenAt, lastSeenAt)
        XCTAssertNil(record["hostname"])
        XCTAssertNil(record["username"])
        XCTAssertNil(record["homePath"])
        XCTAssertNil(record["projectPath"])
        XCTAssertEqual(
            Set(record.allKeys()),
            Set(CloudDeviceRecordMapper.deviceKeys).subtracting([CloudDeviceRecordMapper.retiredAtKey])
        )

        let sameID = CloudDeviceRecordMapper.deviceRecordID(for: profile.id, zoneID: zoneID)
        let repeatedID = CloudDeviceRecordMapper.deviceRecordID(for: profile.id, zoneID: zoneID)
        XCTAssertEqual(sameID, repeatedID)
        XCTAssertFalse(sameID.recordName.contains(profile.id))
    }

    func testCloudKitSyncSpaceMappingCarriesFingerprintButNoKeyMaterial() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitDeviceRegistry.defaultZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let fingerprint = String(repeating: "a", count: 64)
        let record = CloudDeviceRecordMapper.makeSyncSpaceRecord(
            zoneID: zoneID,
            keyFingerprint: fingerprint,
            createdAt: Date(timeIntervalSince1970: 100),
            createdByDeviceID: "device-a"
        )

        XCTAssertEqual(try CloudDeviceRecordMapper.decodeSyncSpace(record).keyFingerprint, fingerprint)
        XCTAssertEqual(record.recordID.recordName, "primary")
        XCTAssertNil(record["key"])
        XCTAssertNil(record["masterKey"])
        XCTAssertNil(record["encryptedKey"])
    }

    func testCloudReadinessRequiresAnActiveCurrentDeviceUnlessExplicitlyReactivating() {
        let active = RegisteredDevice(
            id: "device-a",
            displayName: "Studio",
            systemVersion: "15.5",
            appVersion: "1.0",
            registeredAt: .distantPast,
            lastSeenAt: .distantPast
        )
        var retired = active
        retired.retiredAt = Date(timeIntervalSince1970: 200)

        XCTAssertEqual(
            CloudKitDeviceRegistry.readiness(
                currentDeviceID: active.id,
                devices: [active],
                allowRetiredCurrentDevice: false
            ),
            .ready
        )
        XCTAssertEqual(
            CloudKitDeviceRegistry.readiness(
                currentDeviceID: retired.id,
                devices: [retired],
                allowRetiredCurrentDevice: false
            ),
            .unavailable(reason: "This Mac is retired. Reactivate it before synchronizing again.")
        )
        XCTAssertEqual(
            CloudKitDeviceRegistry.readiness(
                currentDeviceID: retired.id,
                devices: [retired],
                allowRetiredCurrentDevice: true
            ),
            .ready
        )
        XCTAssertEqual(
            CloudKitDeviceRegistry.readiness(
                currentDeviceID: "unknown",
                devices: [active],
                allowRetiredCurrentDevice: false
            ),
            .unavailable(reason: "This Mac is not registered for synchronization yet.")
        )
    }

    func testCloudHeartbeatPreservesTheRemoteAuthoritativeName() {
        let discovered = Self.profile(id: "device-a", displayName: "This Mac")
        let authoritative = RegisteredDevice(
            id: discovered.id,
            displayName: "Renamed from another Mac",
            modelIdentifier: "Mac14,3",
            systemVersion: "15.4",
            appVersion: "0.9",
            registeredAt: .distantPast,
            lastSeenAt: .distantPast
        )

        let heartbeatProfile = CloudDeviceRecordMapper.profileForHeartbeat(
            discoveredProfile: discovered,
            authoritativeDevice: authoritative
        )

        XCTAssertEqual(heartbeatProfile.displayName, "Renamed from another Mac")
        XCTAssertEqual(heartbeatProfile.modelIdentifier, discovered.modelIdentifier)
        XCTAssertEqual(heartbeatProfile.systemVersion, discovered.systemVersion)
        XCTAssertEqual(heartbeatProfile.appVersion, discovered.appVersion)
    }

    func testCacheRejectsOversizedFilesAndTooManyDevices() throws {
        let fixture = try RegistryFixture()
        defer { fixture.cleanup() }
        let cache = DeviceRegistryCache(url: fixture.cacheURL)

        try Data(
            repeating: 0x41,
            count: DeviceRegistryValuePolicy.maximumCacheBytes + 1
        ).write(to: fixture.cacheURL)
        XCTAssertNil(cache.load())

        let devices = (0...DeviceRegistryValuePolicy.maximumDeviceCount).map { index in
            RegisteredDevice(
                id: "device-\(index)",
                displayName: "Mac \(index)",
                systemVersion: "15.5",
                appVersion: "1.0",
                registeredAt: .distantPast,
                lastSeenAt: .distantPast
            )
        }
        let oversized = DeviceRegistrySnapshot(
            currentDeviceID: "device-0",
            devices: devices,
            readiness: .ready,
            refreshedAt: .distantPast
        )
        XCTAssertThrowsError(try cache.save(oversized))
    }

    func testCloudCacheURLIsStableAndScopedWithoutExposingFingerprint() {
        let base = URL(filePath: "/tmp/device-registry.json")
        let firstFingerprint = String(repeating: "a", count: 64)
        let secondFingerprint = String(repeating: "b", count: 64)
        let first = CloudDeviceCacheScope.url(
            baseURL: base,
            keyFingerprint: firstFingerprint
        )
        let repeated = CloudDeviceCacheScope.url(
            baseURL: base,
            keyFingerprint: firstFingerprint
        )
        let second = CloudDeviceCacheScope.url(
            baseURL: base,
            keyFingerprint: secondFingerprint
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.lastPathComponent.contains(firstFingerprint))
        XCTAssertFalse(second.lastPathComponent.contains(secondFingerprint))
        XCTAssertEqual(first.deletingLastPathComponent(), base.deletingLastPathComponent())
    }

    func testMalformedForeignDeviceIsSkippedButMalformedCurrentDeviceBlocks() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitDeviceRegistry.defaultZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let currentRecordID = CloudDeviceRecordMapper.deviceRecordID(
            for: "current-device",
            zoneID: zoneID
        )
        let foreign = CKRecord(
            recordType: CloudKitDeviceRegistry.deviceRecordType,
            recordID: CloudDeviceRecordMapper.deviceRecordID(for: "foreign-device", zoneID: zoneID)
        )
        let current = CKRecord(
            recordType: CloudKitDeviceRegistry.deviceRecordType,
            recordID: currentRecordID
        )

        XCTAssertNil(try CloudDeviceRecordMapper.decodeDeviceChange(
            foreign,
            currentRecordID: currentRecordID
        ))
        XCTAssertThrowsError(try CloudDeviceRecordMapper.decodeDeviceChange(
            current,
            currentRecordID: currentRecordID
        ))
    }

    func testBootstrapStateReportsWinningFingerprint() {
        let state = CloudSyncSpaceBootstrapState.existing(keyFingerprint: "winner")
        XCTAssertEqual(state, .existing(keyFingerprint: "winner"))
        XCTAssertNotEqual(state, .missing)
        XCTAssertNotEqual(state, .unavailable(reason: "offline"))
    }

    private static func profile(
        id: String,
        displayName: String = "This Mac"
    ) -> DeviceProfile {
        DeviceProfile(
            id: id,
            displayName: displayName,
            modelIdentifier: "Mac14,3",
            systemVersion: "15.5",
            appVersion: "1.0 (42)"
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func read() -> Date { lock.withLock { value } }

    func set(_ value: Date) { lock.withLock { self.value = value } }
}

private struct RegistryFixture {
    let directory: URL
    let cacheURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ThreadlineDeviceRegistryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cacheURL = directory.appending(path: "device-registry.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func permissionBits(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
