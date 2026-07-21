import Foundation

public actor LocalDeviceRegistry: DeviceRegistry {
    public nonisolated let currentDeviceID: String

    private var currentProfile: DeviceProfile
    private let cache: DeviceRegistryCache
    private let localOnlyReason: String
    private let now: @Sendable () -> Date
    private var snapshot: DeviceRegistrySnapshot

    public init(
        profile: DeviceProfile,
        cacheURL: URL,
        reason: String = "Cloud synchronization is not configured for this build.",
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        currentDeviceID = profile.id
        currentProfile = profile
        cache = DeviceRegistryCache(url: cacheURL)
        localOnlyReason = reason
        self.now = now

        let timestamp = now()
        let cached = cache.load()
        var devices = cached?.devices ?? []
        if let index = devices.firstIndex(where: { $0.id == profile.id }) {
            // The cached name is user-authored. Generic profile discovery on
            // the next launch must not silently replace it with “This Mac”.
            currentProfile.displayName = devices[index].displayName
            devices[index].modelIdentifier = DeviceRegistryValuePolicy.optionalMetadata(profile.modelIdentifier)
            devices[index].systemVersion = DeviceRegistryValuePolicy.metadata(profile.systemVersion)
            devices[index].appVersion = DeviceRegistryValuePolicy.metadata(profile.appVersion)
            if !devices[index].isRetired {
                devices[index].lastSeenAt = timestamp
            }
        } else {
            devices.append(Self.registeredDevice(from: profile, at: timestamp))
        }
        snapshot = DeviceRegistrySnapshot(
            currentDeviceID: profile.id,
            devices: Self.sorted(devices),
            readiness: .localOnly(reason: reason),
            refreshedAt: timestamp
        )
        try? cache.save(snapshot)
    }

    public func cachedSnapshot() async -> DeviceRegistrySnapshot { snapshot }

    public func refresh() async -> DeviceRegistrySnapshot {
        updateCurrentDeviceHeartbeat()
        return persistSnapshot()
    }

    public func prepareForSync() async -> DeviceRegistrySnapshot {
        updateCurrentDeviceHeartbeat()
        return persistSnapshot()
    }

    public func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot {
        guard let index = snapshot.devices.firstIndex(where: { $0.id == id }) else {
            return snapshot
        }
        let normalized = DeviceRegistryValuePolicy.displayName(displayName)
        snapshot.devices[index].displayName = normalized
        if id == currentDeviceID { currentProfile.displayName = normalized }
        snapshot.refreshedAt = now()
        return persistSnapshot()
    }

    public func retireDevice(id: String) async -> DeviceRegistrySnapshot {
        guard let index = snapshot.devices.firstIndex(where: { $0.id == id }) else {
            return snapshot
        }
        if snapshot.devices[index].retiredAt == nil {
            snapshot.devices[index].retiredAt = now()
        }
        snapshot.refreshedAt = now()
        return persistSnapshot()
    }

    public func reactivateCurrentDevice() async -> DeviceRegistrySnapshot {
        guard let index = snapshot.devices.firstIndex(where: { $0.id == currentDeviceID }) else {
            let timestamp = now()
            snapshot.devices.append(Self.registeredDevice(from: currentProfile, at: timestamp))
            snapshot.refreshedAt = timestamp
            return persistSnapshot()
        }
        let timestamp = now()
        snapshot.devices[index].retiredAt = nil
        snapshot.devices[index].lastSeenAt = timestamp
        snapshot.refreshedAt = timestamp
        return persistSnapshot()
    }

    private func updateCurrentDeviceHeartbeat() {
        let timestamp = now()
        if let index = snapshot.devices.firstIndex(where: { $0.id == currentDeviceID }) {
            guard !snapshot.devices[index].isRetired else {
                snapshot.refreshedAt = timestamp
                return
            }
            snapshot.devices[index].displayName = DeviceRegistryValuePolicy.displayName(currentProfile.displayName)
            snapshot.devices[index].modelIdentifier = DeviceRegistryValuePolicy.optionalMetadata(currentProfile.modelIdentifier)
            snapshot.devices[index].systemVersion = DeviceRegistryValuePolicy.metadata(currentProfile.systemVersion)
            snapshot.devices[index].appVersion = DeviceRegistryValuePolicy.metadata(currentProfile.appVersion)
            snapshot.devices[index].lastSeenAt = timestamp
        } else {
            snapshot.devices.append(Self.registeredDevice(from: currentProfile, at: timestamp))
        }
        snapshot.refreshedAt = timestamp
    }

    @discardableResult
    private func persistSnapshot() -> DeviceRegistrySnapshot {
        snapshot.devices = Self.sorted(snapshot.devices)
        snapshot.readiness = .localOnly(reason: localOnlyReason)
        try? cache.save(snapshot)
        return snapshot
    }

    private static func registeredDevice(from profile: DeviceProfile, at date: Date) -> RegisteredDevice {
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
}
