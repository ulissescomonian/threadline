@preconcurrency import CloudKit
import CryptoKit
import Foundation

public enum CloudSyncHealth: Sendable, Equatable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable(String)
    case failed(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var userFacingDescription: String {
        switch self {
        case .unknown: "CloudKit has not been checked yet."
        case .available: "iCloud synchronization is available."
        case .noAccount: "Sign in to iCloud to synchronize conversations."
        case .restricted: "This iCloud account is restricted from using CloudKit."
        case .temporarilyUnavailable(let detail): "iCloud is temporarily unavailable: \(detail)"
        case .failed(let detail): "iCloud synchronization failed: \(detail)"
        }
    }
}

public struct CloudRetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(maximumAttempts: Int = 4, initialDelay: TimeInterval = 0.5, maximumDelay: TimeInterval = 8) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(max(0, initialDelay), maximumDelay)
    }

    public func delay(
        for code: CKError.Code,
        retryAfter: TimeInterval?,
        failedAttempt: Int,
        jitter: Double = 1
    ) -> TimeInterval? {
        guard failedAttempt + 1 < maximumAttempts else { return nil }
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            let requested = retryAfter.map { max(0, $0) }
            let exponential = min(maximumDelay, initialDelay * pow(2, Double(failedAttempt)))
            return min(maximumDelay, (requested ?? exponential) * min(1.25, max(0.75, jitter)))
        default:
            return nil
        }
    }
}

public actor CloudKitSyncTransport: SyncTransport {
    public nonisolated let identifier: String

    private let container: CKContainer
    private let database: CKDatabase
    private let recordType: String
    private let zoneID: CKRecordZone.ID
    private let assetDirectory: URL
    private let retryPolicy: CloudRetryPolicy
    private var currentHealth: CloudSyncHealth = .unknown
    private var zoneReady = false

    public init(
        containerIdentifier: String,
        recordType: String = "EncryptedConversationEnvelope",
        zoneName: String = "ThreadlineConversationSync",
        identifier: String = "cloudkit-private-v1",
        assetDirectory: URL? = nil,
        retryPolicy: CloudRetryPolicy = CloudRetryPolicy()
    ) {
        self.identifier = identifier
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.recordType = recordType
        self.zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.retryPolicy = retryPolicy
        self.assetDirectory = assetDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadlineCloudAssets", isDirectory: true)
    }

    public func push(_ envelopes: [SyncEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        do {
            try envelopes.forEach(SyncEnvelopeLimits.validate)
            try await ensureZone()
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: assetDirectory.path
            )
            for batch in Self.uploadBatches(envelopes) {
                try await upload(batch)
            }
            currentHealth = .available
        } catch {
            currentHealth = Self.health(for: error)
            throw Self.cloudError(error, operation: "upload")
        }
    }

    public func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        do {
            try await ensureZone()
            var serverToken = try Self.decodeCursor(cursor.token)
            var didResetExpiredToken = false
            let pulled: (envelopes: [SyncEnvelope], token: CKServerChangeToken?)
            while true {
                do {
                    pulled = try await pullPages(since: serverToken)
                    break
                } catch let error as CKError
                    where error.code == .changeTokenExpired && !didResetExpiredToken {
                    serverToken = nil
                    didResetExpiredToken = true
                }
            }

            currentHealth = .available
            let newCursor = SyncCursor(
                token: try Self.encodeCursor(pulled.token),
                updatedAt: Date()
            )
            return SyncPullResult(envelopes: pulled.envelopes, cursor: newCursor)
        } catch {
            currentHealth = Self.health(for: error)
            throw Self.cloudError(error, operation: "download")
        }
    }

    public func healthCheck() async -> Bool {
        do {
            switch try await container.accountStatus() {
            case .available:
                currentHealth = .available
            case .noAccount:
                currentHealth = .noAccount
            case .restricted:
                currentHealth = .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                currentHealth = .temporarilyUnavailable("CloudKit could not confirm the account status.")
            @unknown default:
                currentHealth = .failed("CloudKit returned an unknown account status.")
            }
        } catch {
            currentHealth = Self.health(for: error)
        }
        return currentHealth.isAvailable
    }

    public func healthStatus() -> CloudSyncHealth { currentHealth }

    private static func decode(_ record: CKRecord) throws -> SyncEnvelope {
        guard let id = record["envelopeID"] as? String,
              let objectType = record["objectType"] as? String,
              let logicalVersion = record["logicalVersion"] as? Int,
              let originDeviceID = record["originDeviceID"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let payloadHash = record["payloadHash"] as? String
        else { throw ThreadlineError.invalidPayload("A CloudKit envelope is missing required fields") }

        let payload: Data
        if let inline = record["payload"] as? Data {
            guard inline.count <= SyncEnvelopeLimits.maximumPayloadBytes else {
                throw ThreadlineError.invalidPayload("A CloudKit inline payload exceeds the safe size limit")
            }
            payload = inline
        } else if let asset = record["payloadAsset"] as? CKAsset, let url = asset.fileURL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= SyncEnvelopeLimits.maximumPayloadBytes else {
                throw ThreadlineError.invalidPayload("A CloudKit asset exceeds the safe size limit")
            }
            payload = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard payload.count == fileSize,
                  payload.count <= SyncEnvelopeLimits.maximumPayloadBytes else {
                throw ThreadlineError.invalidPayload("A CloudKit asset changed while it was being read")
            }
        } else {
            throw ThreadlineError.invalidPayload("A CloudKit envelope has no encrypted payload")
        }
        let envelope = SyncEnvelope(
            id: id,
            objectType: objectType,
            logicalVersion: logicalVersion,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            encryptedPayload: payload,
            payloadHash: payloadHash
        )
        try SyncEnvelopeLimits.validate(envelope)
        return envelope
    }

    private static func recordName(for envelopeID: String) -> String {
        SHA256.hash(data: Data(envelopeID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeCursor(_ token: CKServerChangeToken?) throws -> Data? {
        guard let token else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeCursor(_ data: Data?) throws -> CKServerChangeToken? {
        guard let data else { return nil }
        guard data.count <= SyncEnvelopeLimits.maximumCursorBytes else {
            throw ThreadlineError.invalidPayload("The CloudKit cursor exceeds the safe size limit")
        }
        do { return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) }
        catch { throw ThreadlineError.invalidPayload("The CloudKit cursor is invalid") }
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        try await withRetry {
            let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let saveResult = result.saveResults[zoneID] else {
                throw ThreadlineError.cloud("CloudKit did not return a result when preparing the private sync zone")
            }
            _ = try saveResult.get()
        }
        zoneReady = true
    }

    private func pullPages(
        since initialToken: CKServerChangeToken?
    ) async throws -> (envelopes: [SyncEnvelope], token: CKServerChangeToken?) {
        var token = initialToken
        var envelopes: [SyncEnvelope] = []
        var payloadBytes = 0
        while true {
            let page = try await withRetry {
                try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: token,
                    desiredKeys: [
                        "envelopeID", "objectType", "logicalVersion", "originDeviceID", "createdAt",
                        "payloadHash", "payload", "payloadAsset",
                    ],
                    resultsLimit: 4
                )
            }
            for (_, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == recordType else { continue }
                let envelope: SyncEnvelope
                do {
                    envelope = try Self.decode(record)
                } catch {
                    // Preserve a bounded diagnostic object so one malformed or
                    // oversized CloudKit record cannot pin the zone cursor.
                    envelope = Self.quarantineEnvelope(for: record, error: error)
                }
                envelopes.append(envelope)
                payloadBytes += envelope.encryptedPayload.count
            }
            token = page.changeToken
            guard page.moreComing else { return (envelopes, token) }
            if payloadBytes >= SyncEnvelopeLimits.maximumPullBatchBytes {
                return (envelopes, token)
            }
        }
    }

    private func upload(_ envelopes: [SyncEnvelope]) async throws {
        var temporaryFiles: [URL] = []
        defer { temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        let records = try envelopes.map { envelope -> CKRecord in
            let recordID = CKRecord.ID(recordName: Self.recordName(for: envelope.id), zoneID: zoneID)
            let record = CKRecord(recordType: recordType, recordID: recordID)
            record["envelopeID"] = envelope.id as CKRecordValue
            record["objectType"] = envelope.objectType as CKRecordValue
            record["logicalVersion"] = envelope.logicalVersion as CKRecordValue
            record["originDeviceID"] = envelope.originDeviceID as CKRecordValue
            record["createdAt"] = envelope.createdAt as CKRecordValue
            record["payloadHash"] = envelope.payloadHash as CKRecordValue

            if envelope.encryptedPayload.count <= 800_000 {
                record["payload"] = envelope.encryptedPayload as CKRecordValue
            } else {
                let file = assetDirectory.appendingPathComponent("\(UUID().uuidString).payload")
                try envelope.encryptedPayload.write(to: file, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: file.path
                )
                temporaryFiles.append(file)
                record["payloadAsset"] = CKAsset(fileURL: file)
            }
            return record
        }

        try await withRetry {
            let result = try await database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .allKeys,
                atomically: false
            )
            for (_, saveResult) in result.saveResults {
                if case .failure(let error) = saveResult { throw error }
            }
        }
    }

    private static func uploadBatches(_ envelopes: [SyncEnvelope]) -> [[SyncEnvelope]] {
        var batches: [[SyncEnvelope]] = []
        var current: [SyncEnvelope] = []
        var currentBytes = 0
        for envelope in envelopes {
            if !current.isEmpty,
               (current.count >= 16
                || currentBytes + envelope.encryptedPayload.count > SyncEnvelopeLimits.maximumTransportBatchBytes) {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(envelope)
            currentBytes += envelope.encryptedPayload.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func quarantineEnvelope(for record: CKRecord, error: Error) -> SyncEnvelope {
        let recordName = record.recordID.recordName
        let errorCode = String(error.localizedDescription.prefix(512))
        return SyncEnvelope(
            id: "cloud-record:\(recordName)",
            objectType: "invalid-cloud-record:\(errorCode)",
            logicalVersion: 0,
            originDeviceID: (record["originDeviceID"] as? String) ?? "unknown",
            createdAt: (record["createdAt"] as? Date) ?? record.modificationDate ?? Date(),
            encryptedPayload: Data(),
            payloadHash: (record["payloadHash"] as? String) ?? "unavailable"
        )
    }

    private func withRetry<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        var failedAttempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as CKError {
                let retryAfter = error.userInfo[CKErrorRetryAfterKey] as? TimeInterval
                guard let delay = retryPolicy.delay(
                    for: error.code,
                    retryAfter: retryAfter,
                    failedAttempt: failedAttempt,
                    jitter: Double.random(in: 0.85...1.15)
                ) else { throw error }
                failedAttempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private static func health(for error: Error) -> CloudSyncHealth {
        guard let cloudError = error as? CKError else { return .failed(error.localizedDescription) }
        switch cloudError.code {
        case .notAuthenticated: return .noAccount
        case .permissionFailure: return .restricted
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .temporarilyUnavailable(cloudError.localizedDescription)
        default: return .failed(cloudError.localizedDescription)
        }
    }

    private static func cloudError(_ error: Error, operation: String) -> ThreadlineError {
        .cloud("CloudKit \(operation) failed: \(error.localizedDescription)")
    }
}

public struct DisabledSyncTransport: SyncTransport {
    public let identifier: String
    public let reason: String

    public init(identifier: String = "disabled", reason: String) {
        self.identifier = identifier
        self.reason = reason
    }

    public func push(_ envelopes: [SyncEnvelope]) async throws {
        throw ThreadlineError.cloud(reason)
    }

    public func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        throw ThreadlineError.cloud(reason)
    }

    public func healthCheck() async -> Bool { false }
}
