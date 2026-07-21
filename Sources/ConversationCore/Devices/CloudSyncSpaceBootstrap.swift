@preconcurrency import CloudKit
import Foundation

public enum CloudSyncSpaceBootstrapState: Sendable, Equatable {
    case missing
    case existing(keyFingerprint: String)
    case unavailable(reason: String)
}

/// Reads or claims the CloudKit sync-space manifest before the runtime loads or
/// creates conversation key material. `inspect` is strictly read-only: a
/// missing custom zone and a missing singleton record both map to `.missing`.
public enum CloudSyncSpaceBootstrap {
    public static func inspect(
        containerIdentifier: String
    ) async -> CloudSyncSpaceBootstrapState {
        guard !containerIdentifier.isEmpty else {
            return .unavailable(reason: "The CloudKit container identifier is invalid.")
        }
        let container = CKContainer(identifier: containerIdentifier)
        do {
            guard let accountFailure = try await accountFailure(for: container) else {
                return await inspect(database: container.privateCloudDatabase)
            }
            return accountFailure
        } catch {
            return .unavailable(reason: userFacingReason(for: error))
        }
    }

    public static func claim(
        containerIdentifier: String,
        keyFingerprint: String,
        createdByDeviceID: String
    ) async -> CloudSyncSpaceBootstrapState {
        guard !containerIdentifier.isEmpty,
              !keyFingerprint.isEmpty,
              keyFingerprint.utf8.count <= 512,
              DeviceRegistryValuePolicy.isValidIdentifier(createdByDeviceID) else {
            return .unavailable(reason: "The sync-space identity is invalid.")
        }

        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        do {
            if let accountFailure = try await accountFailure(for: container) {
                return accountFailure
            }

            let inspected = await inspect(database: database)
            switch inspected {
            case .existing, .unavailable:
                return inspected
            case .missing:
                break
            }

            let zone = CKRecordZone(zoneID: zoneID)
            let zoneResult = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let savedZone = zoneResult.saveResults[zoneID] else {
                return .unavailable(reason: "CloudKit did not confirm the sync-space zone.")
            }
            _ = try savedZone.get()

            // The zone may have existed while only the first inspection failed
            // with zoneNotFound, or another claimant may have created the
            // singleton meanwhile. Re-read before attempting create-only save.
            let afterZoneCreation = await inspect(database: database)
            switch afterZoneCreation {
            case .existing, .unavailable:
                return afterZoneCreation
            case .missing:
                break
            }

            let proposed = CloudDeviceRecordMapper.makeSyncSpaceRecord(
                zoneID: zoneID,
                keyFingerprint: keyFingerprint,
                createdAt: Date(),
                createdByDeviceID: createdByDeviceID
            )
            do {
                let result = try await database.modifyRecords(
                    saving: [proposed],
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: true
                )
                guard let saved = result.saveResults[proposed.recordID] else {
                    return .unavailable(reason: "CloudKit did not confirm the sync-space manifest.")
                }
                _ = try saved.get()
                return .existing(keyFingerprint: keyFingerprint)
            } catch {
                // Create-if-absent races have exactly one winner. Never retry
                // by overwriting: read the singleton and return its fingerprint.
                let winner = await inspect(database: database)
                if case .existing = winner { return winner }
                return .unavailable(reason: userFacingReason(for: error))
            }
        } catch {
            return .unavailable(reason: userFacingReason(for: error))
        }
    }

    private static let zoneID = CKRecordZone.ID(
        zoneName: CloudKitDeviceRegistry.defaultZoneName,
        ownerName: CKCurrentUserDefaultName
    )

    private static func inspect(database: CKDatabase) async -> CloudSyncSpaceBootstrapState {
        let recordID = CloudDeviceRecordMapper.syncSpaceRecordID(zoneID: zoneID)
        do {
            let space = try CloudDeviceRecordMapper.decodeSyncSpace(
                try await database.record(for: recordID)
            )
            return .existing(keyFingerprint: space.keyFingerprint)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return .missing
        } catch is ThreadlineError {
            return .unavailable(reason: "The CloudKit sync-space manifest is invalid or unsupported.")
        } catch {
            return .unavailable(reason: userFacingReason(for: error))
        }
    }

    private static func accountFailure(
        for container: CKContainer
    ) async throws -> CloudSyncSpaceBootstrapState? {
        switch try await container.accountStatus() {
        case .available:
            return nil
        case .noAccount:
            return .unavailable(reason: "Sign in to iCloud to configure Threadline synchronization.")
        case .restricted:
            return .unavailable(reason: "This iCloud account is restricted from using CloudKit.")
        case .couldNotDetermine, .temporarilyUnavailable:
            return .unavailable(reason: "iCloud is temporarily unavailable.")
        @unknown default:
            return .unavailable(reason: "Threadline could not determine the iCloud account status.")
        }
    }

    private static func userFacingReason(for error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return "The CloudKit sync space could not be checked."
        }
        switch cloudError.code {
        case .notAuthenticated:
            return "Sign in to iCloud to configure Threadline synchronization."
        case .permissionFailure:
            return "This build cannot access Threadline's private CloudKit container."
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is temporarily unavailable."
        case .zoneNotFound, .unknownItem:
            return "The CloudKit sync space does not exist yet."
        default:
            return "The CloudKit sync space could not be checked."
        }
    }
}
