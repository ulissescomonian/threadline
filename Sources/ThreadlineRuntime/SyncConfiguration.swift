import ConversationCore
import CryptoKit
import Foundation
import Security

public enum SyncLocationKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case local
    case iCloudDrive
    case oneDrive
    case googleDrive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "Local Only"
        case .iCloudDrive: "iCloud Drive"
        case .oneDrive: "OneDrive"
        case .googleDrive: "Google Drive"
        }
    }

    public var systemImage: String {
        switch self {
        case .local: "internaldrive"
        case .iCloudDrive: "icloud"
        case .oneDrive: "cloud"
        case .googleDrive: "externaldrive.connected.to.line.below"
        }
    }
}

public enum SyncSetupIntent: String, Codable, Sendable, Hashable {
    case create
    case join
}

public enum SyncConnectionState: Sendable, Equatable {
    case localOnly
    case ready
    case requiresReconnect(String)
    case unavailable(String)
    case migrating
}

public struct SyncConfigurationSnapshot: Sendable, Equatable {
    public let location: SyncLocationKind
    public let connectionState: SyncConnectionState
    public let folderDisplayName: String?
    public let syncSpaceID: String?
    public let lastSuccessfulSyncAt: Date?

    public init(
        location: SyncLocationKind,
        connectionState: SyncConnectionState,
        folderDisplayName: String? = nil,
        syncSpaceID: String? = nil,
        lastSuccessfulSyncAt: Date? = nil
    ) {
        self.location = location
        self.connectionState = connectionState
        self.folderDisplayName = folderDisplayName
        self.syncSpaceID = syncSpaceID
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }

    public static let localOnly = SyncConfigurationSnapshot(
        location: .local,
        connectionState: .localOnly
    )
}

public struct SyncSetupResult: Sendable, Equatable {
    public let snapshot: SyncConfigurationSnapshot
    public let recoveryKey: String?

    public init(snapshot: SyncConfigurationSnapshot, recoveryKey: String?) {
        self.snapshot = snapshot
        self.recoveryKey = recoveryKey
    }
}

struct StoredSyncConfiguration: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let location: SyncLocationKind
    let syncSpaceID: String
    let folderDisplayName: String
    let bookmarkData: Data
    let keyFingerprint: String
    let configuredAt: Date
    var lastSuccessfulSyncAt: Date?
}

public final class ScopedFolderAccess: @unchecked Sendable {
    let url: URL
    private let didStartSecurityScope: Bool

    init(url: URL) {
        self.url = url
        didStartSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

struct ResolvedFolderSyncConfiguration: Sendable {
    let stored: StoredSyncConfiguration
    let access: ScopedFolderAccess
    let manifest: FolderSyncManifest
    let keyData: Data
}

public actor SyncConfigurationStore {
    private static let maximumConfigurationBytes = 2 * 1_024 * 1_024
    private static let maximumMigrationEntryCount = 500_000
    private static let maximumMigrationDepth = 64
    private static let maximumMigrationPathBytes = 16 * 1_024
    private static let maximumMigrationFileBytes: Int64 = 128 * 1_024 * 1_024
    private static let maximumMigrationTotalBytes: Int64 = 64 * 1_024 * 1_024 * 1_024
    private static let migrationHashChunkBytes = 1 * 1_024 * 1_024
    private static let keyService = "com.ulisses.threadline.folder-sync"
    private static let recoveryPrefix = "TL1-"

    private struct MigrationInventory: Equatable {
        enum EntryKind: String, Equatable {
            case directory
            case file
        }

        struct Entry: Equatable {
            let relativePath: String
            let kind: EntryKind
            let byteCount: Int64
            let sha256: String?
        }

        let entries: [Entry]

        var topLevelNames: Set<String> {
            Set(entries.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) })
        }
    }

    private let configurationURL: URL
    private let keyStore: any KeyMaterialStore
    private let fileManager: FileManager

    public init(
        applicationSupportURL: URL,
        keyStore: any KeyMaterialStore = KeychainKeyMaterialStore(synchronizable: false),
        fileManager: FileManager = .default
    ) {
        configurationURL = applicationSupportURL.appending(path: "sync-configuration.json")
        self.keyStore = keyStore
        self.fileManager = fileManager
    }

    public func snapshot() -> SyncConfigurationSnapshot {
        guard let stored = try? loadStored() else { return .localOnly }
        do {
            let resolved = try resolve(stored)
            _ = try FolderSyncManifest.load(from: resolved.access.url, keyData: resolved.keyData)
            return makeSnapshot(stored, state: .ready)
        } catch SyncConfigurationError.bookmarkUnavailable(let detail) {
            return makeSnapshot(stored, state: .requiresReconnect(detail))
        } catch {
            return makeSnapshot(stored, state: .unavailable(error.localizedDescription))
        }
    }

    func resolvedConfiguration() throws -> ResolvedFolderSyncConfiguration? {
        guard let stored = try loadStored() else { return nil }
        let resolved = try resolve(stored)
        let manifest = try FolderSyncManifest.load(
            from: resolved.access.url,
            keyData: resolved.keyData
        )
        guard manifest.syncSpaceID == stored.syncSpaceID,
              manifest.keyFingerprint == stored.keyFingerprint else {
            throw SyncConfigurationError.spaceMismatch
        }
        return ResolvedFolderSyncConfiguration(
            stored: stored,
            access: resolved.access,
            manifest: manifest,
            keyData: resolved.keyData
        )
    }

    public func configure(
        location: SyncLocationKind,
        intent: SyncSetupIntent,
        folderURL: URL,
        recoveryKey: String?,
        deviceID: String
    ) throws -> SyncSetupResult {
        guard location != .local else {
            try disconnect()
            return SyncSetupResult(snapshot: .localOnly, recoveryKey: nil)
        }
        let root = try validateFolder(folderURL, createIfMissing: intent == .create)
        let access = ScopedFolderAccess(url: root)

        let keyData: Data
        let manifest: FolderSyncManifest
        let presentedRecoveryKey: String?
        switch intent {
        case .create:
            try requireEmptySyncFolder(access.url)
            keyData = try makeRandomKey()
            manifest = try FolderSyncManifest.create(
                at: access.url,
                keyData: keyData,
                createdByDeviceID: deviceID
            )
            presentedRecoveryKey = Self.encodeRecoveryKey(keyData)
        case .join:
            guard let recoveryKey else { throw SyncConfigurationError.recoveryKeyRequired }
            keyData = try Self.decodeRecoveryKey(recoveryKey)
            manifest = try FolderSyncManifest.load(from: access.url, keyData: keyData)
            presentedRecoveryKey = nil
        }

        do {
            let fingerprint = Self.fingerprint(keyData)
            guard manifest.keyFingerprint == fingerprint else {
                throw SyncConfigurationError.keyMismatch
            }
            let bookmark = try makeBookmark(for: access.url)
            let stored = StoredSyncConfiguration(
                version: StoredSyncConfiguration.currentVersion,
                location: location,
                syncSpaceID: manifest.syncSpaceID,
                folderDisplayName: access.url.lastPathComponent,
                bookmarkData: bookmark,
                keyFingerprint: fingerprint,
                configuredAt: Date(),
                lastSuccessfulSyncAt: nil
            )
            let account = keyAccount(manifest.syncSpaceID)
            let previousKey = try keyStore.load(service: Self.keyService, account: account)

            // Key first, configuration second. If the configuration write
            // fails, restore the exact Keychain state that existed before this
            // attempt instead of deleting a valid key from an earlier setup.
            do {
                try keyStore.save(keyData, service: Self.keyService, account: account)
                try saveStored(stored)
            } catch {
                if let previousKey {
                    try? keyStore.save(previousKey, service: Self.keyService, account: account)
                } else {
                    try? keyStore.delete(service: Self.keyService, account: account)
                }
                throw error
            }
            return SyncSetupResult(
                snapshot: makeSnapshot(stored, state: .ready),
                recoveryKey: presentedRecoveryKey
            )
        } catch {
            if intent == .create {
                try? rollbackNewManifest(manifest, keyData: keyData, at: access.url)
            }
            throw error
        }
    }

    public func reconnect(folderURL: URL) throws -> SyncConfigurationSnapshot {
        guard var stored = try loadStored() else {
            throw SyncConfigurationError.notConfigured
        }
        let keyData = try loadKey(for: stored)
        let root = try validateFolder(folderURL, createIfMissing: false)
        let access = ScopedFolderAccess(url: root)
        let manifest = try FolderSyncManifest.load(from: access.url, keyData: keyData)
        guard manifest.syncSpaceID == stored.syncSpaceID,
              manifest.keyFingerprint == stored.keyFingerprint else {
            throw SyncConfigurationError.spaceMismatch
        }
        stored = StoredSyncConfiguration(
            version: stored.version,
            location: stored.location,
            syncSpaceID: stored.syncSpaceID,
            folderDisplayName: access.url.lastPathComponent,
            bookmarkData: try makeBookmark(for: access.url),
            keyFingerprint: stored.keyFingerprint,
            configuredAt: stored.configuredAt,
            lastSuccessfulSyncAt: stored.lastSuccessfulSyncAt
        )
        try saveStored(stored)
        return makeSnapshot(stored, state: .ready)
    }

    public func migrate(
        to location: SyncLocationKind,
        folderURL: URL
    ) throws -> SyncConfigurationSnapshot {
        guard location != .local else {
            try disconnect()
            return .localOnly
        }
        guard var stored = try loadStored() else {
            throw SyncConfigurationError.notConfigured
        }
        let source = try resolve(stored)
        let destinationURL = try validateFolder(folderURL, createIfMissing: true)
        let destination = ScopedFolderAccess(url: destinationURL)
        guard source.access.url.standardizedFileURL != destination.url.standardizedFileURL else {
            throw SyncConfigurationError.sameFolder
        }
        try requireEmptySyncFolder(destination.url)
        let createdTopLevelNames = try coordinatedVerifiedCopyContents(
            from: source.access.url,
            to: destination.url
        )

        do {
            let manifest = try FolderSyncManifest.load(
                from: destination.url,
                keyData: source.keyData
            )
            guard manifest.syncSpaceID == stored.syncSpaceID,
                  manifest.keyFingerprint == stored.keyFingerprint else {
                throw SyncConfigurationError.spaceMismatch
            }
            stored = StoredSyncConfiguration(
                version: stored.version,
                location: location,
                syncSpaceID: stored.syncSpaceID,
                folderDisplayName: destination.url.lastPathComponent,
                bookmarkData: try makeBookmark(for: destination.url),
                keyFingerprint: stored.keyFingerprint,
                configuredAt: stored.configuredAt,
                lastSuccessfulSyncAt: nil
            )
            try saveStored(stored)
            return makeSnapshot(stored, state: .ready)
        } catch {
            do {
                try rollbackMigrationItems(
                    topLevelNames: createdTopLevelNames,
                    at: destination.url
                )
            } catch {
                throw SyncConfigurationError.migrationRollbackFailed
            }
            throw error
        }
    }

    /// Moves this Mac's pointer to an already-migrated copy of its current
    /// encrypted space. Unlike `migrate`, this never copies or removes remote
    /// data and never changes the locally held encryption key.
    public func followExistingMigration(
        to location: SyncLocationKind,
        folderURL: URL
    ) throws -> SyncConfigurationSnapshot {
        guard location != .local else { throw SyncConfigurationError.invalidFolder }
        guard var stored = try loadStored() else {
            throw SyncConfigurationError.notConfigured
        }
        let current = try resolve(stored)
        let destinationURL = try validateFolder(folderURL, createIfMissing: false)
        let destination = ScopedFolderAccess(url: destinationURL)
        guard current.access.url.standardizedFileURL
                != destination.url.standardizedFileURL else {
            throw SyncConfigurationError.sameFolder
        }
        let manifest = try FolderSyncManifest.load(
            from: destination.url,
            keyData: current.keyData
        )
        guard manifest.syncSpaceID == stored.syncSpaceID,
              manifest.keyFingerprint == stored.keyFingerprint else {
            throw SyncConfigurationError.spaceMismatch
        }

        stored = StoredSyncConfiguration(
            version: stored.version,
            location: location,
            syncSpaceID: stored.syncSpaceID,
            folderDisplayName: destination.url.lastPathComponent,
            bookmarkData: try makeBookmark(for: destination.url),
            keyFingerprint: stored.keyFingerprint,
            configuredAt: stored.configuredAt,
            lastSuccessfulSyncAt: nil
        )
        try saveStored(stored)
        return makeSnapshot(stored, state: .ready)
    }

    public func disconnect() throws {
        let stored = try loadStored()
        guard fileManager.fileExists(atPath: configurationURL.path) else { return }
        try fileManager.removeItem(at: configurationURL)
        if let stored {
            // Removing the configuration is authoritative. Key cleanup is
            // best-effort afterward so a Keychain outage cannot trap the app
            // in a half-disconnected state; an orphaned item is unreachable
            // without its sync-space identifier.
            try? keyStore.delete(
                service: Self.keyService,
                account: keyAccount(stored.syncSpaceID)
            )
        }
    }

    public func markSyncSuccessful(at date: Date = Date()) throws {
        guard var stored = try loadStored() else { return }
        stored.lastSuccessfulSyncAt = date
        try saveStored(stored)
    }

    public static func encodeRecoveryKey(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return recoveryPrefix + encoded
    }

    public static func decodeRecoveryKey(_ value: String) throws -> Data {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(recoveryPrefix) else {
            throw SyncConfigurationError.invalidRecoveryKey
        }
        var base64 = String(normalized.dropFirst(recoveryPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw SyncConfigurationError.invalidRecoveryKey
        }
        return data
    }

    private func rollbackNewManifest(
        _ manifest: FolderSyncManifest,
        keyData: Data,
        at rootURL: URL
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        let manifestURL = rootURL.appending(path: FolderSyncManifest.fileName)

        // Never delete an existing or already-active sync space. Rollback is
        // allowed only while this exact authenticated manifest is the sole
        // item in the folder created by the failed setup attempt.
        let unexpectedEntries = entries.filter {
            $0.standardizedFileURL != manifestURL.standardizedFileURL
                && $0.lastPathComponent != ".DS_Store"
        }
        guard unexpectedEntries.isEmpty,
              entries.contains(where: {
                  $0.standardizedFileURL == manifestURL.standardizedFileURL
              }) else {
            return
        }
        let values = try manifestURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
        let onDisk = try FolderSyncManifest.load(from: rootURL, keyData: keyData)
        guard onDisk == manifest else { return }
        try fileManager.removeItem(at: manifestURL)
    }

    private func loadStored() throws -> StoredSyncConfiguration? {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        let values = try configurationURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= Self.maximumConfigurationBytes else {
            throw SyncConfigurationError.invalidConfiguration
        }
        let data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumConfigurationBytes else {
            throw SyncConfigurationError.invalidConfiguration
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let stored = try decoder.decode(StoredSyncConfiguration.self, from: data)
        guard stored.version == StoredSyncConfiguration.currentVersion,
              stored.location != .local,
              UUID(uuidString: stored.syncSpaceID) != nil,
              stored.bookmarkData.count <= Self.maximumConfigurationBytes,
              stored.keyFingerprint.count == 64 else {
            throw SyncConfigurationError.invalidConfiguration
        }
        return stored
    }

    private func saveStored(_ stored: StoredSyncConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        guard data.count <= Self.maximumConfigurationBytes else {
            throw SyncConfigurationError.invalidConfiguration
        }
        try fileManager.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: configurationURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: configurationURL.path
        )
    }

    private func resolve(
        _ stored: StoredSyncConfiguration
    ) throws -> (access: ScopedFolderAccess, keyData: Data) {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: stored.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw SyncConfigurationError.bookmarkUnavailable(
                "The selected sync folder could not be located."
            )
        }
        guard !stale else {
            throw SyncConfigurationError.bookmarkUnavailable(
                "The saved folder permission is stale and must be reconnected."
            )
        }
        let root = try validateFolder(url, createIfMissing: false)
        return (ScopedFolderAccess(url: root), try loadKey(for: stored))
    }

    private func loadKey(for stored: StoredSyncConfiguration) throws -> Data {
        guard let keyData = try keyStore.load(
            service: Self.keyService,
            account: keyAccount(stored.syncSpaceID)
        ), keyData.count == 32 else {
            throw SyncConfigurationError.keyUnavailable
        }
        guard Self.fingerprint(keyData) == stored.keyFingerprint else {
            throw SyncConfigurationError.keyMismatch
        }
        return keyData
    }

    private func validateFolder(_ url: URL, createIfMissing: Bool) throws -> URL {
        let standardized = url.standardizedFileURL
        if !fileManager.fileExists(atPath: standardized.path) {
            guard createIfMissing else {
                throw SyncConfigurationError.bookmarkUnavailable("The selected sync folder is unavailable.")
            }
            try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
        }
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SyncConfigurationError.invalidFolder
        }
        return standardized
    }

    private func requireEmptySyncFolder(_ root: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )
        guard contents.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else {
            throw SyncConfigurationError.folderNotEmpty
        }
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey],
            relativeTo: nil
        )
    }

    private func coordinatedVerifiedCopyContents(
        from source: URL,
        to destination: URL
    ) throws -> Set<String> {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationResult: Result<Set<String>, Error>?
        coordinator.coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { readableSource, writableDestination in
            var createdTopLevelNames: Set<String> = []
            do {
                try requireEmptySyncFolder(writableDestination)
                let sourceInventory = try migrationInventory(at: readableSource)
                try copyMigrationInventory(
                    sourceInventory,
                    from: readableSource,
                    to: writableDestination,
                    createdTopLevelNames: &createdTopLevelNames
                )
                let destinationInventory = try migrationInventory(at: writableDestination)
                guard destinationInventory == sourceInventory else {
                    throw SyncConfigurationError.migrationVerificationFailed
                }
                operationResult = .success(createdTopLevelNames)
            } catch {
                do {
                    try rollbackMigrationItems(
                        topLevelNames: createdTopLevelNames,
                        at: writableDestination
                    )
                    operationResult = .failure(error)
                } catch {
                    operationResult = .failure(SyncConfigurationError.migrationRollbackFailed)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let operationResult else {
            throw SyncConfigurationError.migrationVerificationFailed
        }
        return try operationResult.get()
    }

    private func migrationInventory(at root: URL) throws -> MigrationInventory {
        var entries: [MigrationInventory.Entry] = []
        var totalBytes: Int64 = 0

        func visit(_ directory: URL, components: [String]) throws {
            guard components.count <= Self.maximumMigrationDepth else {
                throw SyncConfigurationError.migrationLimitExceeded
            }
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children where child.lastPathComponent != ".DS_Store" {
                let name = child.lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else {
                    throw SyncConfigurationError.migrationUnsafeEntry
                }
                let childComponents = components + [name]
                guard childComponents.count <= Self.maximumMigrationDepth else {
                    throw SyncConfigurationError.migrationLimitExceeded
                }
                let relativePath = childComponents.joined(separator: "/")
                guard relativePath.utf8.count <= Self.maximumMigrationPathBytes else {
                    throw SyncConfigurationError.migrationLimitExceeded
                }
                guard entries.count < Self.maximumMigrationEntryCount else {
                    throw SyncConfigurationError.migrationLimitExceeded
                }

                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard values.isSymbolicLink != true else {
                    throw SyncConfigurationError.migrationUnsafeEntry
                }
                if values.isDirectory == true {
                    entries.append(MigrationInventory.Entry(
                        relativePath: relativePath,
                        kind: .directory,
                        byteCount: 0,
                        sha256: nil
                    ))
                    try visit(child, components: childComponents)
                } else if values.isRegularFile == true, let fileSize = values.fileSize {
                    let byteCount = Int64(fileSize)
                    guard byteCount >= 0,
                          byteCount <= Self.maximumMigrationFileBytes else {
                        throw SyncConfigurationError.migrationLimitExceeded
                    }
                    let (prospectiveTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
                    guard !overflow,
                          prospectiveTotal <= Self.maximumMigrationTotalBytes else {
                        throw SyncConfigurationError.migrationLimitExceeded
                    }
                    totalBytes = prospectiveTotal
                    entries.append(MigrationInventory.Entry(
                        relativePath: relativePath,
                        kind: .file,
                        byteCount: byteCount,
                        sha256: try sha256(of: child, expectedByteCount: byteCount)
                    ))
                } else {
                    throw SyncConfigurationError.migrationUnsafeEntry
                }
            }
        }

        try visit(root, components: [])
        return MigrationInventory(entries: entries)
    }

    private func sha256(of url: URL, expectedByteCount: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: Self.migrationHashChunkBytes), !chunk.isEmpty {
            let (prospectiveCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflow,
                  prospectiveCount <= Self.maximumMigrationFileBytes else {
                throw SyncConfigurationError.migrationLimitExceeded
            }
            byteCount = prospectiveCount
            digest.update(data: chunk)
        }
        guard byteCount == expectedByteCount else {
            throw SyncConfigurationError.migrationVerificationFailed
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyMigrationInventory(
        _ inventory: MigrationInventory,
        from source: URL,
        to destination: URL,
        createdTopLevelNames: inout Set<String>
    ) throws {
        for entry in inventory.entries {
            let sourceItem = migrationItemURL(root: source, relativePath: entry.relativePath)
            let destinationItem = migrationItemURL(root: destination, relativePath: entry.relativePath)
            if let topLevelName = entry.relativePath.split(separator: "/").first.map(String.init) {
                createdTopLevelNames.insert(topLevelName)
            }
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(
                    at: destinationItem,
                    withIntermediateDirectories: false
                )
            case .file:
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
            }
        }
    }

    private func migrationItemURL(root: URL, relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appending(path: String(component))
        }
    }

    private func rollbackMigrationItems(
        topLevelNames: Set<String>,
        at destination: URL
    ) throws {
        for name in topLevelNames.sorted() {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw SyncConfigurationError.migrationRollbackFailed
            }
            let item = destination.appending(path: name)
            if fileManager.fileExists(atPath: item.path) {
                try fileManager.removeItem(at: item)
            }
        }
    }

    private func makeRandomKey() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SyncConfigurationError.randomGenerationFailed
        }
        return data
    }

    private func keyAccount(_ syncSpaceID: String) -> String {
        "folder-space-\(syncSpaceID.lowercased())"
    }

    private func makeSnapshot(
        _ stored: StoredSyncConfiguration,
        state: SyncConnectionState
    ) -> SyncConfigurationSnapshot {
        SyncConfigurationSnapshot(
            location: stored.location,
            connectionState: state,
            folderDisplayName: stored.folderDisplayName,
            syncSpaceID: stored.syncSpaceID,
            lastSuccessfulSyncAt: stored.lastSuccessfulSyncAt
        )
    }

    private static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncConfigurationError: LocalizedError, Equatable {
    case notConfigured
    case invalidConfiguration
    case invalidFolder
    case folderNotEmpty
    case bookmarkUnavailable(String)
    case recoveryKeyRequired
    case invalidRecoveryKey
    case keyUnavailable
    case keyMismatch
    case spaceMismatch
    case sameFolder
    case migrationUnsafeEntry
    case migrationLimitExceeded
    case migrationVerificationFailed
    case migrationRollbackFailed
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Folder synchronization is not configured."
        case .invalidConfiguration:
            "The saved synchronization configuration is invalid."
        case .invalidFolder:
            "Choose a real folder rather than a file or symbolic link."
        case .folderNotEmpty:
            "Choose an empty folder when creating or migrating a Threadline sync space."
        case .bookmarkUnavailable(let detail):
            detail
        case .recoveryKeyRequired:
            "Enter the recovery key created by the first Mac."
        case .invalidRecoveryKey:
            "The recovery key is invalid."
        case .keyUnavailable:
            "The encryption key for this Threadline sync space is unavailable in Keychain."
        case .keyMismatch:
            "The recovery key does not match this Threadline sync space."
        case .spaceMismatch:
            "The selected folder belongs to a different Threadline sync space."
        case .sameFolder:
            "Choose a different folder for the new sync provider."
        case .migrationUnsafeEntry:
            "The sync space contains a symbolic link or unsupported filesystem entry."
        case .migrationLimitExceeded:
            "The sync space exceeds a safe migration limit."
        case .migrationVerificationFailed:
            "The copied sync space did not match its source exactly."
        case .migrationRollbackFailed:
            "Threadline could not clean up the incomplete destination copy."
        case .randomGenerationFailed:
            "macOS could not generate a secure recovery key."
        }
    }
}
