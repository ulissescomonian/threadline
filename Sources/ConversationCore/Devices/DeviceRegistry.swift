import Foundation

public struct DeviceProfile: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var displayName: String
    public var modelIdentifier: String?
    public var systemVersion: String
    public var appVersion: String

    public init(
        id: String,
        displayName: String,
        modelIdentifier: String? = nil,
        systemVersion: String,
        appVersion: String
    ) {
        self.id = id
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.systemVersion = systemVersion
        self.appVersion = appVersion
    }
}

public struct RegisteredDevice: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var displayName: String
    public var modelIdentifier: String?
    public var systemVersion: String
    public var appVersion: String
    public let registeredAt: Date
    public var lastSeenAt: Date
    public var retiredAt: Date?

    public var isRetired: Bool { retiredAt != nil }

    public init(
        id: String,
        displayName: String,
        modelIdentifier: String? = nil,
        systemVersion: String,
        appVersion: String,
        registeredAt: Date,
        lastSeenAt: Date,
        retiredAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
        self.retiredAt = retiredAt
    }
}

public enum DeviceRegistryReadiness: Codable, Sendable, Hashable {
    case localOnly(reason: String)
    case ready
    case unavailable(reason: String)
    case keyMismatch
}

public struct DeviceRegistrySnapshot: Codable, Sendable, Hashable {
    public let currentDeviceID: String
    public var devices: [RegisteredDevice]
    public var readiness: DeviceRegistryReadiness
    public var refreshedAt: Date

    public init(
        currentDeviceID: String,
        devices: [RegisteredDevice],
        readiness: DeviceRegistryReadiness,
        refreshedAt: Date
    ) {
        self.currentDeviceID = currentDeviceID
        self.devices = devices
        self.readiness = readiness
        self.refreshedAt = refreshedAt
    }
}

public protocol DeviceRegistry: Sendable {
    nonisolated var currentDeviceID: String { get }

    func cachedSnapshot() async -> DeviceRegistrySnapshot
    func refresh() async -> DeviceRegistrySnapshot
    func prepareForSync() async -> DeviceRegistrySnapshot
    func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot
    func retireDevice(id: String) async -> DeviceRegistrySnapshot
    func reactivateCurrentDevice() async -> DeviceRegistrySnapshot
}

enum DeviceRegistryValuePolicy {
    static let maximumIdentifierBytes = 512
    static let maximumDisplayNameCharacters = 80
    static let maximumMetadataCharacters = 160
    static let maximumDeviceCount = 512
    static let maximumCacheBytes = 1 * 1_024 * 1_024

    static func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = trimmed.isEmpty ? "This Mac" : trimmed
        return String(usable.prefix(maximumDisplayNameCharacters))
    }

    static func metadata(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumMetadataCharacters))
    }

    static func optionalMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = metadata(value)
        return normalized.isEmpty ? nil : normalized
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentifierBytes
    }

    static func isValidSnapshot(_ snapshot: DeviceRegistrySnapshot) -> Bool {
        guard isValidIdentifier(snapshot.currentDeviceID),
              snapshot.devices.count <= maximumDeviceCount,
              snapshot.refreshedAt.timeIntervalSince1970.isFinite else {
            return false
        }
        var identifiers = Set<String>()
        for device in snapshot.devices {
            guard isValidIdentifier(device.id), identifiers.insert(device.id).inserted,
                  device.displayName.count <= maximumDisplayNameCharacters,
                  device.systemVersion.count <= maximumMetadataCharacters,
                  device.appVersion.count <= maximumMetadataCharacters,
                  (device.modelIdentifier?.count ?? 0) <= maximumMetadataCharacters,
                  device.registeredAt.timeIntervalSince1970.isFinite,
                  device.lastSeenAt.timeIntervalSince1970.isFinite,
                  device.retiredAt?.timeIntervalSince1970.isFinite ?? true else {
                return false
            }
        }
        return true
    }
}

struct DeviceRegistryCache: Sendable {
    let url: URL

    func load() -> DeviceRegistrySnapshot? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= DeviceRegistryValuePolicy.maximumCacheBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= DeviceRegistryValuePolicy.maximumCacheBytes else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snapshot = try? decoder.decode(DeviceRegistrySnapshot.self, from: data),
              DeviceRegistryValuePolicy.isValidSnapshot(snapshot) else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: DeviceRegistrySnapshot) throws {
        guard DeviceRegistryValuePolicy.isValidSnapshot(snapshot) else {
            throw ThreadlineError.invalidPayload("The device registry cache exceeds its safe limits.")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= DeviceRegistryValuePolicy.maximumCacheBytes else {
            throw ThreadlineError.invalidPayload("The device registry cache exceeds its safe size limit.")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
