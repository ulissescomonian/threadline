@preconcurrency import CloudKit
import CryptoKit
import Foundation

public actor CloudKitDeviceRegistry: DeviceRegistry {
    public nonisolated let currentDeviceID: String

    public static let defaultZoneName = "ThreadlineDeviceRegistry"
    public static let syncSpaceRecordType = "TLSyncSpaceV1"
    public static let deviceRecordType = "TLDeviceV1"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let keyFingerprint: String
    private let cache: DeviceRegistryCache
    private let now: @Sendable () -> Date
    private var currentProfile: DeviceProfile
    private var snapshot: DeviceRegistrySnapshot
    private var zoneReady = false

    public init(
        profile: DeviceProfile,
        containerIdentifier: String,
        keyFingerprint: String,
        cacheURL: URL,
        zoneName: String = CloudKitDeviceRegistry.defaultZoneName,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        currentDeviceID = profile.id
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.keyFingerprint = keyFingerprint
        cache = DeviceRegistryCache(url: CloudDeviceCacheScope.url(
            baseURL: cacheURL,
            keyFingerprint: keyFingerprint
        ))
        self.now = now
        let cached = cache.load()
        var effectiveProfile = profile
        if let cachedDevice = cached?.devices.first(where: { $0.id == profile.id }) {
            effectiveProfile.displayName = cachedDevice.displayName
        }
        currentProfile = effectiveProfile
        snapshot = DeviceRegistrySnapshot(
            currentDeviceID: profile.id,
            devices: cached?.devices ?? [],
            // Cached devices are useful immediately, but a previous launch's
            // readiness must not be presented as a current CloudKit guarantee.
            readiness: .unavailable(reason: "Device synchronization has not been checked yet."),
            refreshedAt: now()
        )
    }

    public func cachedSnapshot() async -> DeviceRegistrySnapshot { snapshot }

    public func refresh() async -> DeviceRegistrySnapshot {
        await synchronize(createSpaceIfMissing: true, heartbeatCurrentDevice: true)
    }

    public func prepareForSync() async -> DeviceRegistrySnapshot {
        await synchronize(createSpaceIfMissing: true, heartbeatCurrentDevice: true)
    }

    public func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot {
        let prepared = await synchronize(createSpaceIfMissing: false, heartbeatCurrentDevice: true)
        guard prepared.readiness == .ready else { return prepared }
        let normalized = DeviceRegistryValuePolicy.displayName(displayName)
        do {
            try await mutateDevice(id: id) { record in
                record[CloudDeviceRecordMapper.displayNameKey] = normalized as CKRecordValue
            }
            if id == currentDeviceID { currentProfile.displayName = normalized }
            return await synchronize(createSpaceIfMissing: false, heartbeatCurrentDevice: false)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    public func retireDevice(id: String) async -> DeviceRegistrySnapshot {
        let prepared = await synchronize(createSpaceIfMissing: false, heartbeatCurrentDevice: true)
        guard prepared.readiness == .ready else { return prepared }
        do {
            let timestamp = now()
            try await mutateDevice(id: id) { record in
                if record[CloudDeviceRecordMapper.retiredAtKey] as? Date == nil {
                    record[CloudDeviceRecordMapper.retiredAtKey] = timestamp as CKRecordValue
                }
            }
            return await synchronize(createSpaceIfMissing: false, heartbeatCurrentDevice: false)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    public func reactivateCurrentDevice() async -> DeviceRegistrySnapshot {
        let prepared = await synchronize(
            createSpaceIfMissing: false,
            heartbeatCurrentDevice: false,
            allowRetiredCurrentDevice: true
        )
        guard prepared.readiness == .ready else { return prepared }
        do {
            let timestamp = now()
            try await mutateDevice(id: currentDeviceID) { record in
                record[CloudDeviceRecordMapper.retiredAtKey] = nil
                record[CloudDeviceRecordMapper.lastSeenAtKey] = timestamp as CKRecordValue
            }
            return await synchronize(createSpaceIfMissing: false, heartbeatCurrentDevice: false)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    private func synchronize(
        createSpaceIfMissing: Bool,
        heartbeatCurrentDevice: Bool,
        allowRetiredCurrentDevice: Bool = false
    ) async -> DeviceRegistrySnapshot {
        guard DeviceRegistryValuePolicy.isValidIdentifier(currentDeviceID),
              !keyFingerprint.isEmpty,
              keyFingerprint.utf8.count <= 512 else {
            return persist(readiness: .unavailable(reason: "The local device identity or encryption key fingerprint is invalid."))
        }

        do {
            guard try await accountIsAvailable() else { return snapshot }
            try await ensureZone()
            let space = try await loadOrCreateSyncSpace(createIfMissing: createSpaceIfMissing)
            guard let space else {
                return persist(readiness: .unavailable(reason: "Device synchronization has not been prepared yet."))
            }
            guard space.keyFingerprint == keyFingerprint else {
                return persist(readiness: .keyMismatch)
            }

            if heartbeatCurrentDevice {
                try await registerOrHeartbeatCurrentDevice()
            }
            let devices = try await fetchAllDevices()
            snapshot.devices = Self.sorted(devices)
            return persist(readiness: Self.readiness(
                currentDeviceID: currentDeviceID,
                devices: devices,
                allowRetiredCurrentDevice: allowRetiredCurrentDevice
            ))
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    private func accountIsAvailable() async throws -> Bool {
        switch try await container.accountStatus() {
        case .available:
            return true
        case .noAccount:
            _ = persist(readiness: .unavailable(reason: "Sign in to iCloud to synchronize registered Macs."))
        case .restricted:
            _ = persist(readiness: .unavailable(reason: "This iCloud account is restricted from using CloudKit."))
        case .couldNotDetermine, .temporarilyUnavailable:
            _ = persist(readiness: .unavailable(reason: "iCloud is temporarily unavailable. Threadline will keep the local library available."))
        @unknown default:
            _ = persist(readiness: .unavailable(reason: "Threadline could not determine the iCloud account status."))
        }
        return false
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
        guard let saveResult = result.saveResults[zoneID] else {
            throw ThreadlineError.cloud("CloudKit did not return a result for the device registry zone.")
        }
        _ = try saveResult.get()
        zoneReady = true
    }

    private func loadOrCreateSyncSpace(createIfMissing: Bool) async throws -> CloudSyncSpace? {
        let recordID = CloudDeviceRecordMapper.syncSpaceRecordID(zoneID: zoneID)
        do {
            return try CloudDeviceRecordMapper.decodeSyncSpace(try await database.record(for: recordID))
        } catch let error as CKError where error.code == .unknownItem {
            guard createIfMissing else { return nil }
        }

        let proposed = CloudDeviceRecordMapper.makeSyncSpaceRecord(
            zoneID: zoneID,
            keyFingerprint: keyFingerprint,
            createdAt: now(),
            createdByDeviceID: currentDeviceID
        )
        do {
            _ = try await save(proposed, policy: .ifServerRecordUnchanged)
            return try CloudDeviceRecordMapper.decodeSyncSpace(proposed)
        } catch {
            // Two first devices may race to create the fixed record. The loser
            // must adopt and validate the winner's manifest; it must never
            // overwrite it with a different key fingerprint.
            return try CloudDeviceRecordMapper.decodeSyncSpace(try await database.record(for: recordID))
        }
    }

    private func registerOrHeartbeatCurrentDevice() async throws {
        let recordID = CloudDeviceRecordMapper.deviceRecordID(for: currentDeviceID, zoneID: zoneID)
        let timestamp = now()
        var lastConflict: Error?
        for _ in 0..<3 {
            do {
                let record: CKRecord
                do {
                    let authoritative = try await database.record(for: recordID)
                    let existing = try CloudDeviceRecordMapper.decodeDevice(authoritative)
                    guard !existing.isRetired else { return }
                    // A rename may have been performed from another Mac after
                    // this installation cached its last snapshot. The cloud
                    // record remains authoritative for the chosen name.
                    currentProfile = CloudDeviceRecordMapper.profileForHeartbeat(
                        discoveredProfile: currentProfile,
                        authoritativeDevice: existing
                    )
                    CloudDeviceRecordMapper.apply(
                        profile: currentProfile,
                        lastSeenAt: timestamp,
                        to: authoritative
                    )
                    record = authoritative
                } catch let error as CKError where error.code == .unknownItem {
                    record = CloudDeviceRecordMapper.makeDeviceRecord(
                        profile: currentProfile,
                        registeredAt: timestamp,
                        lastSeenAt: timestamp,
                        zoneID: zoneID
                    )
                }

                _ = try await save(record, policy: .ifServerRecordUnchanged)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                // App and helper can legitimately heartbeat the same install
                // concurrently. Refetch the winner and retry the CAS update.
                lastConflict = error
            }
        }
        throw lastConflict ?? ThreadlineError.cloud(
            "The current Mac heartbeat could not be updated after repeated conflicts."
        )
    }

    private func fetchAllDevices() async throws -> [RegisteredDevice] {
        var token: CKServerChangeToken?
        var devicesByID: [String: RegisteredDevice] = [:]
        let currentRecordID = CloudDeviceRecordMapper.deviceRecordID(
            for: currentDeviceID,
            zoneID: zoneID
        )
        while true {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: CloudDeviceRecordMapper.deviceKeys,
                resultsLimit: 100
            )
            for (changedRecordID, result) in page.modificationResultsByID {
                let record: CKRecord
                do {
                    record = try result.get().record
                } catch {
                    if changedRecordID == currentRecordID { throw error }
                    continue
                }
                guard let device = try CloudDeviceRecordMapper.decodeDeviceChange(
                    record,
                    currentRecordID: currentRecordID
                ) else { continue }
                if devicesByID[device.id] == nil,
                   devicesByID.count >= DeviceRegistryValuePolicy.maximumDeviceCount {
                    throw ThreadlineError.invalidPayload(
                        "The CloudKit device registry exceeds its safe device limit."
                    )
                }
                devicesByID[device.id] = device
            }
            token = page.changeToken
            guard page.moreComing else { break }
        }
        return Array(devicesByID.values)
    }

    private func mutateDevice(
        id: String,
        mutation: (CKRecord) -> Void
    ) async throws {
        guard DeviceRegistryValuePolicy.isValidIdentifier(id) else {
            throw ThreadlineError.invalidPayload("The device identifier is invalid.")
        }
        let recordID = CloudDeviceRecordMapper.deviceRecordID(for: id, zoneID: zoneID)
        var lastError: Error?
        for _ in 0..<3 {
            do {
                let record = try await database.record(for: recordID)
                _ = try CloudDeviceRecordMapper.decodeDevice(record)
                mutation(record)
                _ = try await save(record, policy: .ifServerRecordUnchanged)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                lastError = error
            }
        }
        throw lastError ?? ThreadlineError.cloud("The device record could not be updated.")
    }

    private func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> CKRecord {
        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: policy,
            atomically: true
        )
        guard let saved = result.saveResults[record.recordID] else {
            throw ThreadlineError.cloud("CloudKit did not return a result for the device registry record.")
        }
        return try saved.get()
    }

    @discardableResult
    private func persist(readiness: DeviceRegistryReadiness) -> DeviceRegistrySnapshot {
        snapshot.readiness = readiness
        snapshot.refreshedAt = now()
        try? cache.save(snapshot)
        return snapshot
    }

    private static func userFacingReason(for error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return "The device registry could not be updated. The local library remains available."
        }
        switch cloudError.code {
        case .notAuthenticated:
            return "Sign in to iCloud to synchronize registered Macs."
        case .permissionFailure:
            return "This build cannot access Threadline's private device registry."
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is temporarily unavailable. Threadline will retry without affecting the local library."
        case .unknownItem:
            return "The requested registered Mac no longer exists."
        default:
            return "The private device registry could not be updated. The local library remains available."
        }
    }

    private static func sorted(_ devices: [RegisteredDevice]) -> [RegisteredDevice] {
        devices.sorted {
            if $0.isRetired != $1.isRetired { return !$0.isRetired }
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id < $1.id
        }
    }

    static func readiness(
        currentDeviceID: String,
        devices: [RegisteredDevice],
        allowRetiredCurrentDevice: Bool
    ) -> DeviceRegistryReadiness {
        guard let currentDevice = devices.first(where: { $0.id == currentDeviceID }) else {
            return .unavailable(reason: "This Mac is not registered for synchronization yet.")
        }
        if currentDevice.isRetired, !allowRetiredCurrentDevice {
            return .unavailable(reason: "This Mac is retired. Reactivate it before synchronizing again.")
        }
        return .ready
    }
}

struct CloudSyncSpace: Sendable, Equatable {
    let keyFingerprint: String
}

enum CloudDeviceRecordMapper {
    static let schemaVersionKey = "schemaVersion"
    static let keyFingerprintKey = "keyFingerprint"
    static let createdAtKey = "createdAt"
    static let createdByDeviceIDKey = "createdByDeviceID"

    static let deviceIDKey = "deviceID"
    static let displayNameKey = "displayName"
    static let modelIdentifierKey = "modelIdentifier"
    static let systemVersionKey = "systemVersion"
    static let appVersionKey = "appVersion"
    static let registeredAtKey = "registeredAt"
    static let lastSeenAtKey = "lastSeenAt"
    static let retiredAtKey = "retiredAt"

    static let deviceKeys = [
        deviceIDKey, displayNameKey, modelIdentifierKey, systemVersionKey,
        appVersionKey, registeredAtKey, lastSeenAtKey, retiredAtKey,
    ]

    static func syncSpaceRecordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "primary", zoneID: zoneID)
    }

    static func deviceRecordID(for deviceID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(deviceID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return CKRecord.ID(recordName: "device-\(digest)", zoneID: zoneID)
    }

    static func makeSyncSpaceRecord(
        zoneID: CKRecordZone.ID,
        keyFingerprint: String,
        createdAt: Date,
        createdByDeviceID: String
    ) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitDeviceRegistry.syncSpaceRecordType,
            recordID: syncSpaceRecordID(zoneID: zoneID)
        )
        record[schemaVersionKey] = 1 as CKRecordValue
        record[keyFingerprintKey] = keyFingerprint as CKRecordValue
        record[CloudDeviceRecordMapper.createdAtKey] = createdAt as CKRecordValue
        record[createdByDeviceIDKey] = createdByDeviceID as CKRecordValue
        return record
    }

    static func decodeSyncSpace(_ record: CKRecord) throws -> CloudSyncSpace {
        guard record.recordType == CloudKitDeviceRegistry.syncSpaceRecordType,
              record[schemaVersionKey] as? Int == 1,
              let fingerprint = record[keyFingerprintKey] as? String,
              !fingerprint.isEmpty,
              fingerprint.utf8.count <= 512,
              record[createdAtKey] is Date,
              let creator = record[createdByDeviceIDKey] as? String,
              DeviceRegistryValuePolicy.isValidIdentifier(creator) else {
            throw ThreadlineError.invalidPayload("The CloudKit sync space record is invalid or unsupported.")
        }
        return CloudSyncSpace(keyFingerprint: fingerprint)
    }

    static func makeDeviceRecord(
        profile: DeviceProfile,
        registeredAt: Date,
        lastSeenAt: Date,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitDeviceRegistry.deviceRecordType,
            recordID: deviceRecordID(for: profile.id, zoneID: zoneID)
        )
        record[registeredAtKey] = registeredAt as CKRecordValue
        apply(profile: profile, lastSeenAt: lastSeenAt, to: record)
        return record
    }

    static func apply(profile: DeviceProfile, lastSeenAt: Date, to record: CKRecord) {
        record[deviceIDKey] = profile.id as CKRecordValue
        record[displayNameKey] = DeviceRegistryValuePolicy.displayName(profile.displayName) as CKRecordValue
        if let model = DeviceRegistryValuePolicy.optionalMetadata(profile.modelIdentifier) {
            record[modelIdentifierKey] = model as CKRecordValue
        } else {
            record[modelIdentifierKey] = nil
        }
        record[systemVersionKey] = DeviceRegistryValuePolicy.metadata(profile.systemVersion) as CKRecordValue
        record[appVersionKey] = DeviceRegistryValuePolicy.metadata(profile.appVersion) as CKRecordValue
        record[lastSeenAtKey] = lastSeenAt as CKRecordValue
    }

    static func profileForHeartbeat(
        discoveredProfile: DeviceProfile,
        authoritativeDevice: RegisteredDevice
    ) -> DeviceProfile {
        var profile = discoveredProfile
        profile.displayName = authoritativeDevice.displayName
        return profile
    }

    static func decodeDevice(_ record: CKRecord) throws -> RegisteredDevice {
        guard record.recordType == CloudKitDeviceRegistry.deviceRecordType,
              let id = record[deviceIDKey] as? String,
              DeviceRegistryValuePolicy.isValidIdentifier(id),
              let displayName = record[displayNameKey] as? String,
              let systemVersion = record[systemVersionKey] as? String,
              let appVersion = record[appVersionKey] as? String,
              let registeredAt = record[registeredAtKey] as? Date,
              let lastSeenAt = record[lastSeenAtKey] as? Date,
              record.recordID == deviceRecordID(for: id, zoneID: record.recordID.zoneID) else {
            throw ThreadlineError.invalidPayload("A CloudKit device registry record is invalid.")
        }
        let modelIdentifier = record[modelIdentifierKey] as? String
        let retiredAt = record[retiredAtKey] as? Date
        return RegisteredDevice(
            id: id,
            displayName: DeviceRegistryValuePolicy.displayName(displayName),
            modelIdentifier: DeviceRegistryValuePolicy.optionalMetadata(modelIdentifier),
            systemVersion: DeviceRegistryValuePolicy.metadata(systemVersion),
            appVersion: DeviceRegistryValuePolicy.metadata(appVersion),
            registeredAt: registeredAt,
            lastSeenAt: lastSeenAt,
            retiredAt: retiredAt
        )
    }

    static func decodeDeviceChange(
        _ record: CKRecord,
        currentRecordID: CKRecord.ID
    ) throws -> RegisteredDevice? {
        guard record.recordType == CloudKitDeviceRegistry.deviceRecordType else {
            if record.recordID == currentRecordID {
                throw ThreadlineError.invalidPayload(
                    "The current Mac has an invalid CloudKit device record."
                )
            }
            return nil
        }
        do {
            return try decodeDevice(record)
        } catch {
            if record.recordID == currentRecordID { throw error }
            return nil
        }
    }
}

enum CloudDeviceCacheScope {
    static func url(baseURL: URL, keyFingerprint: String) -> URL {
        let material = Data("threadline-device-registry-cache-v1:\(keyFingerprint)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return baseURL
            .deletingPathExtension()
            .appendingPathExtension("space-\(digest.prefix(24)).json")
    }
}
