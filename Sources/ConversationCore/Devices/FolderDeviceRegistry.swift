import CryptoKit
import Foundation

public actor FolderDeviceRegistry: DeviceRegistry {
    public nonisolated let currentDeviceID: String

    private let rootURL: URL
    private let keyData: Data
    private let configuredKeyFingerprint: String
    private let cache: DeviceRegistryCache
    private let now: @Sendable () -> Date
    private let currentDeviceDirectoryName: String
    private var currentProfile: DeviceProfile
    private var snapshot: DeviceRegistrySnapshot

    public init(
        profile: DeviceProfile,
        rootURL: URL,
        keyData: Data,
        keyFingerprint: String,
        cacheURL: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        currentDeviceID = profile.id
        self.rootURL = rootURL
        self.keyData = keyData
        configuredKeyFingerprint = keyFingerprint
        cache = DeviceRegistryCache(url: cacheURL)
        self.now = now
        currentDeviceDirectoryName = FolderSyncFileSystem.deviceDirectoryName(profile.id)

        let cached = cache.load()
        var effectiveProfile = profile
        if let cachedDevice = cached?.devices.first(where: { $0.id == profile.id }) {
            effectiveProfile.displayName = cachedDevice.displayName
        }
        currentProfile = effectiveProfile
        snapshot = DeviceRegistrySnapshot(
            currentDeviceID: profile.id,
            devices: cached?.devices ?? [],
            readiness: .unavailable(
                reason: "The selected sync folder has not been verified yet."
            ),
            refreshedAt: now()
        )
    }

    public func cachedSnapshot() async -> DeviceRegistrySnapshot { snapshot }

    public func refresh() async -> DeviceRegistrySnapshot {
        await synchronize(heartbeatCurrentDevice: true)
    }

    public func prepareForSync() async -> DeviceRegistrySnapshot {
        await synchronize(heartbeatCurrentDevice: true)
    }

    public func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot {
        let prepared = await synchronize(heartbeatCurrentDevice: true)
        guard prepared.readiness == .ready,
              prepared.devices.contains(where: { $0.id == id }) else { return prepared }
        do {
            let normalized = DeviceRegistryValuePolicy.displayName(displayName)
            try appendOperation(
                kind: .rename,
                targetDeviceID: id,
                displayName: normalized
            )
            if id == currentDeviceID { currentProfile.displayName = normalized }
            return await synchronize(heartbeatCurrentDevice: false)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    public func retireDevice(id: String) async -> DeviceRegistrySnapshot {
        let prepared = await synchronize(heartbeatCurrentDevice: true)
        guard prepared.readiness == .ready,
              prepared.devices.contains(where: { $0.id == id }) else { return prepared }
        do {
            try appendOperation(kind: .retire, targetDeviceID: id)
            return await synchronize(heartbeatCurrentDevice: false)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    public func reactivateCurrentDevice() async -> DeviceRegistrySnapshot {
        let prepared = await synchronize(
            heartbeatCurrentDevice: false,
            allowRetiredCurrentDevice: true
        )
        guard prepared.readiness == .ready else { return prepared }
        do {
            try appendOperation(kind: .reactivate, targetDeviceID: currentDeviceID)
            return await synchronize(heartbeatCurrentDevice: true)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    private func synchronize(
        heartbeatCurrentDevice: Bool,
        allowRetiredCurrentDevice: Bool = false
    ) async -> DeviceRegistrySnapshot {
        do {
            try FolderSyncFileSystem.validateIdentifier(currentDeviceID, label: "device")
            try FolderSyncFileSystem.validateKey(keyData)
            try FolderSyncFileSystem.validateHash(
                configuredKeyFingerprint,
                label: "key fingerprint"
            )
            guard FolderSyncFileSystem.sha256(keyData) == configuredKeyFingerprint else {
                return persist(readiness: .keyMismatch)
            }

            let unauthenticatedManifest = try FolderSyncManifest.load(
                from: rootURL,
                keyData: nil
            )
            guard unauthenticatedManifest.keyFingerprint == configuredKeyFingerprint else {
                return persist(readiness: .keyMismatch)
            }
            let manifest: FolderSyncManifest
            do {
                manifest = try FolderSyncManifest.load(from: rootURL, keyData: keyData)
            } catch let error as ThreadlineError {
                if case .encryption = error { return persist(readiness: .keyMismatch) }
                throw error
            }

            var devices = try readProfiles(manifest: manifest)
            if !devices.contains(where: { $0.id == currentDeviceID }) {
                let timestamp = now()
                let registered = Self.registeredDevice(from: currentProfile, at: timestamp)
                try writeCurrentProfile(registered, manifest: manifest)
                devices.append(registered)
            }

            let operations = try readOperations(manifest: manifest)
            devices = try Self.apply(operations: operations, to: devices)

            guard var currentDevice = devices.first(where: { $0.id == currentDeviceID }) else {
                return persist(readiness: .unavailable(
                    reason: "This Mac is not registered in the selected sync folder."
                ))
            }
            currentProfile.displayName = currentDevice.displayName

            if currentDevice.isRetired, !allowRetiredCurrentDevice {
                snapshot.devices = Self.sorted(devices)
                return persist(readiness: .unavailable(
                    reason: "This Mac is retired. Reactivate it before synchronizing again."
                ))
            }

            if heartbeatCurrentDevice, !currentDevice.isRetired {
                currentDevice.modelIdentifier = DeviceRegistryValuePolicy.optionalMetadata(
                    currentProfile.modelIdentifier
                )
                currentDevice.systemVersion = DeviceRegistryValuePolicy.metadata(
                    currentProfile.systemVersion
                )
                currentDevice.appVersion = DeviceRegistryValuePolicy.metadata(
                    currentProfile.appVersion
                )
                currentDevice.lastSeenAt = now()
                // Retirement is an administrative overlay, never a mutable
                // field another Mac writes into this device's profile.
                currentDevice.retiredAt = nil
                try writeCurrentProfile(currentDevice, manifest: manifest)
                if let index = devices.firstIndex(where: { $0.id == currentDeviceID }) {
                    devices[index] = currentDevice
                }
                devices = try Self.apply(operations: operations, to: devices)
            }

            snapshot.devices = Self.sorted(devices)
            snapshot.refreshedAt = now()
            let currentAfterHeartbeat = snapshot.devices.first { $0.id == currentDeviceID }
            let readiness: DeviceRegistryReadiness =
                (currentAfterHeartbeat?.isRetired == true && !allowRetiredCurrentDevice)
                ? .unavailable(
                    reason: "This Mac is retired. Reactivate it before synchronizing again."
                )
                : .ready
            return persist(readiness: readiness)
        } catch {
            return persist(readiness: .unavailable(reason: Self.userFacingReason(for: error)))
        }
    }

    private func readProfiles(manifest: FolderSyncManifest) throws -> [RegisteredDevice] {
        let devicesURL = rootURL.appendingPathComponent("devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devicesURL.path) else { return [] }
        let entries = try FolderSyncFileSystem.directoryContents(at: devicesURL)
        var devices: [RegisteredDevice] = []
        var seenIDs = Set<String>()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ThreadlineError.invalidPayload(
                    "A symbolic link is not allowed in the folder device registry."
                )
            }
            guard values.isDirectory == true,
                  Self.isLowercaseHash(entry.lastPathComponent) else { continue }
            let profileURL = entry.appendingPathComponent("profile.tldevice")
            guard FileManager.default.fileExists(atPath: profileURL.path) else { continue }
            let encrypted = try FolderSyncFileSystem.readData(
                at: profileURL,
                maximumByteCount: FolderSyncLimits.maximumProfileBytes
            )
            let profile = try decrypt(
                RegisteredDevice.self,
                data: encrypted,
                purpose: "profile",
                deviceHash: entry.lastPathComponent,
                manifest: manifest
            )
            try Self.validate(profile)
            guard FolderSyncFileSystem.deviceDirectoryName(profile.id)
                    == entry.lastPathComponent,
                  seenIDs.insert(profile.id).inserted else {
                throw ThreadlineError.invalidPayload(
                    "A device profile does not match its folder namespace."
                )
            }
            devices.append(profile)
            guard devices.count <= DeviceRegistryValuePolicy.maximumDeviceCount else {
                throw ThreadlineError.invalidPayload(
                    "The folder device registry exceeds its safe device limit."
                )
            }
        }
        return devices
    }

    private func writeCurrentProfile(
        _ device: RegisteredDevice,
        manifest: FolderSyncManifest
    ) throws {
        try Self.validate(device)
        guard device.id == currentDeviceID else {
            throw ThreadlineError.invalidPayload(
                "A device may write only its own folder registry profile."
            )
        }
        let directory = try currentDeviceDirectory()
        let data = try encrypt(
            device,
            purpose: "profile",
            deviceHash: currentDeviceDirectoryName,
            manifest: manifest
        )
        guard data.count <= FolderSyncLimits.maximumProfileBytes else {
            throw ThreadlineError.invalidPayload(
                "The encrypted device profile exceeds its safe size limit."
            )
        }
        try FolderSyncFileSystem.writeDataAtomically(
            data,
            to: directory.appendingPathComponent("profile.tldevice"),
            replaceExisting: true
        )
    }

    private func appendOperation(
        kind: FolderRegistryOperation.Kind,
        targetDeviceID: String,
        displayName: String? = nil
    ) throws {
        try FolderSyncFileSystem.validateIdentifier(targetDeviceID, label: "target device")
        let manifest = try FolderSyncManifest.load(from: rootURL, keyData: keyData)
        let operation = FolderRegistryOperation(
            version: 1,
            id: UUID().uuidString.lowercased(),
            actorDeviceID: currentDeviceID,
            targetDeviceID: targetDeviceID,
            kind: kind,
            displayName: displayName,
            occurredAt: now()
        )
        try Self.validate(operation)
        let encrypted = try encrypt(
            operation,
            purpose: "registry-operation",
            deviceHash: currentDeviceDirectoryName,
            manifest: manifest
        )
        guard encrypted.count <= FolderSyncLimits.maximumRegistryOperationBytes else {
            throw ThreadlineError.invalidPayload(
                "A folder registry operation exceeds its safe size limit."
            )
        }
        let directory = try currentDeviceDirectory()
            .appendingPathComponent("registry-operations", isDirectory: true)
        try FolderSyncFileSystem.ensureDirectory(directory)
        let hash = FolderSyncFileSystem.sha256(encrypted)
        try FolderSyncFileSystem.writeDataAtomically(
            encrypted,
            to: directory.appendingPathComponent("\(hash).tlregistry"),
            replaceExisting: false
        )
    }

    private func readOperations(
        manifest: FolderSyncManifest
    ) throws -> [FolderRegistryOperation] {
        let devicesURL = rootURL.appendingPathComponent("devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devicesURL.path) else { return [] }
        let deviceDirectories = try FolderSyncFileSystem.directoryContents(at: devicesURL)
        var operations: [FolderRegistryOperation] = []
        var operationIDs = Set<String>()

        for deviceDirectory in deviceDirectories {
            let values = try deviceDirectory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ThreadlineError.invalidPayload(
                    "A symbolic link is not allowed in the folder device registry."
                )
            }
            let actorHash = deviceDirectory.lastPathComponent
            guard values.isDirectory == true, Self.isLowercaseHash(actorHash) else { continue }
            let operationDirectory = deviceDirectory.appendingPathComponent(
                "registry-operations",
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: operationDirectory.path) else { continue }
            let files = try FolderSyncFileSystem.directoryContents(at: operationDirectory)
            for file in files {
                let fileValues = try file.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard fileValues.isSymbolicLink != true else {
                    throw ThreadlineError.invalidPayload(
                        "A symbolic link is not allowed in registry operations."
                    )
                }
                guard fileValues.isRegularFile == true,
                      file.pathExtension == "tlregistry",
                      Self.isLowercaseHash(file.deletingPathExtension().lastPathComponent) else {
                    continue
                }
                let encrypted = try FolderSyncFileSystem.readData(
                    at: file,
                    maximumByteCount: FolderSyncLimits.maximumRegistryOperationBytes
                )
                guard FolderSyncFileSystem.sha256(encrypted)
                        == file.deletingPathExtension().lastPathComponent else {
                    throw ThreadlineError.invalidPayload(
                        "A folder registry operation failed its content-address check."
                    )
                }
                let operation = try decrypt(
                    FolderRegistryOperation.self,
                    data: encrypted,
                    purpose: "registry-operation",
                    deviceHash: actorHash,
                    manifest: manifest
                )
                try Self.validate(operation)
                guard FolderSyncFileSystem.deviceDirectoryName(operation.actorDeviceID)
                        == actorHash,
                      operationIDs.insert(operation.id).inserted else {
                    throw ThreadlineError.invalidPayload(
                        "A registry operation does not match its actor namespace."
                    )
                }
                operations.append(operation)
                guard operations.count <= FolderSyncLimits.maximumRegistryOperationCount else {
                    throw ThreadlineError.invalidPayload(
                        "The folder device registry exceeds its safe operation limit."
                    )
                }
            }
        }
        return operations
    }

    private func currentDeviceDirectory() throws -> URL {
        let devicesURL = rootURL.appendingPathComponent("devices", isDirectory: true)
        let directory = devicesURL.appendingPathComponent(
            currentDeviceDirectoryName,
            isDirectory: true
        )
        try FolderSyncFileSystem.ensureDirectory(devicesURL)
        try FolderSyncFileSystem.ensureDirectory(directory)
        return directory
    }

    private func encrypt<T: Encodable>(
        _ value: T,
        purpose: String,
        deviceHash: String,
        manifest: FolderSyncManifest
    ) throws -> Data {
        let cleartext = try FolderSyncFileSystem.encoder.encode(value)
        let sealed = try AES.GCM.seal(
            cleartext,
            using: SymmetricKey(data: keyData),
            authenticating: Self.authenticationData(
                purpose: purpose,
                deviceHash: deviceHash,
                manifest: manifest
            )
        )
        guard let combined = sealed.combined else {
            throw ThreadlineError.encryption(
                "AES-GCM did not produce a folder registry payload."
            )
        }
        return combined
    }

    private func decrypt<T: Decodable>(
        _ type: T.Type,
        data: Data,
        purpose: String,
        deviceHash: String,
        manifest: FolderSyncManifest
    ) throws -> T {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let cleartext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: keyData),
                authenticating: Self.authenticationData(
                    purpose: purpose,
                    deviceHash: deviceHash,
                    manifest: manifest
                )
            )
            return try FolderSyncFileSystem.decoder.decode(type, from: cleartext)
        } catch {
            throw ThreadlineError.encryption(
                "A folder device registry payload failed authentication."
            )
        }
    }

    private static func authenticationData(
        purpose: String,
        deviceHash: String,
        manifest: FolderSyncManifest
    ) -> Data {
        Data("threadline-folder-\(purpose)-v1|\(manifest.syncSpaceID)|\(deviceHash)".utf8)
    }

    private static func apply(
        operations: [FolderRegistryOperation],
        to devices: [RegisteredDevice]
    ) throws -> [RegisteredDevice] {
        var byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let ordered = operations.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.actorDeviceID != $1.actorDeviceID {
                return $0.actorDeviceID < $1.actorDeviceID
            }
            return $0.id < $1.id
        }
        for operation in ordered {
            guard var target = byID[operation.targetDeviceID] else { continue }
            switch operation.kind {
            case .rename:
                target.displayName = DeviceRegistryValuePolicy.displayName(
                    operation.displayName ?? target.displayName
                )
            case .retire:
                if target.retiredAt == nil { target.retiredAt = operation.occurredAt }
            case .reactivate:
                guard operation.actorDeviceID == operation.targetDeviceID else {
                    throw ThreadlineError.invalidPayload(
                        "Only a device can reactivate its own folder registry identity."
                    )
                }
                target.retiredAt = nil
            }
            byID[target.id] = target
        }
        return Array(byID.values)
    }

    private static func validate(_ device: RegisteredDevice) throws {
        guard DeviceRegistryValuePolicy.isValidIdentifier(device.id),
              device.displayName.count <= DeviceRegistryValuePolicy.maximumDisplayNameCharacters,
              device.systemVersion.count <= DeviceRegistryValuePolicy.maximumMetadataCharacters,
              device.appVersion.count <= DeviceRegistryValuePolicy.maximumMetadataCharacters,
              (device.modelIdentifier?.count ?? 0)
                <= DeviceRegistryValuePolicy.maximumMetadataCharacters,
              device.registeredAt.timeIntervalSince1970.isFinite,
              device.lastSeenAt.timeIntervalSince1970.isFinite,
              device.retiredAt?.timeIntervalSince1970.isFinite ?? true else {
            throw ThreadlineError.invalidPayload("A folder device profile is invalid.")
        }
    }

    private static func validate(_ operation: FolderRegistryOperation) throws {
        guard operation.version == 1,
              UUID(uuidString: operation.id) != nil,
              DeviceRegistryValuePolicy.isValidIdentifier(operation.actorDeviceID),
              DeviceRegistryValuePolicy.isValidIdentifier(operation.targetDeviceID),
              operation.occurredAt.timeIntervalSince1970.isFinite,
              (operation.displayName?.count ?? 0)
                <= DeviceRegistryValuePolicy.maximumDisplayNameCharacters else {
            throw ThreadlineError.invalidPayload("A folder registry operation is invalid.")
        }
        switch operation.kind {
        case .rename:
            guard let displayName = operation.displayName,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ThreadlineError.invalidPayload(
                    "A folder registry rename operation has no display name."
                )
            }
        case .retire, .reactivate:
            guard operation.displayName == nil else {
                throw ThreadlineError.invalidPayload(
                    "A folder registry operation contains unexpected metadata."
                )
            }
        }
    }

    private static func registeredDevice(
        from profile: DeviceProfile,
        at date: Date
    ) -> RegisteredDevice {
        RegisteredDevice(
            id: profile.id,
            displayName: DeviceRegistryValuePolicy.displayName(profile.displayName),
            modelIdentifier: DeviceRegistryValuePolicy.optionalMetadata(profile.modelIdentifier),
            systemVersion: DeviceRegistryValuePolicy.metadata(profile.systemVersion),
            appVersion: DeviceRegistryValuePolicy.metadata(profile.appVersion),
            registeredAt: date,
            lastSeenAt: date
        )
    }

    private static func sorted(_ devices: [RegisteredDevice]) -> [RegisteredDevice] {
        devices.sorted {
            if $0.isRetired != $1.isRetired { return !$0.isRetired }
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id < $1.id
        }
    }

    private static func isLowercaseHash(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.utf8.count == 64
            && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }

    @discardableResult
    private func persist(readiness: DeviceRegistryReadiness) -> DeviceRegistrySnapshot {
        snapshot.devices = Self.sorted(snapshot.devices)
        snapshot.readiness = readiness
        snapshot.refreshedAt = now()
        try? cache.save(snapshot)
        return snapshot
    }

    private static func userFacingReason(for error: Error) -> String {
        if let threadlineError = error as? ThreadlineError {
            switch threadlineError {
            case .encryption:
                return "The selected folder could not authenticate this device."
            case .invalidPayload:
                return "The selected folder contains invalid Threadline registry data."
            case .unavailable:
                return "The selected sync folder is temporarily unavailable."
            case .database, .cloud, .incompatibleProvider:
                break
            }
        }
        return "The selected sync folder could not update the device registry."
    }
}

private struct FolderRegistryOperation: Codable {
    enum Kind: String, Codable {
        case rename
        case retire
        case reactivate
    }

    let version: Int
    let id: String
    let actorDeviceID: String
    let targetDeviceID: String
    let kind: Kind
    let displayName: String?
    let occurredAt: Date
}
