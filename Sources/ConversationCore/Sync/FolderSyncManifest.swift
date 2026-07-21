import CryptoKit
import Foundation

public struct FolderSyncManifest: Codable, Sendable, Hashable {
    public static let fileName = "manifest.json"
    public static let currentVersion = 1

    public let version: Int
    public let syncSpaceID: String
    public let keyFingerprint: String
    public let createdAt: Date
    public let createdByDeviceID: String
    public let authenticationCode: String

    public init(
        version: Int = FolderSyncManifest.currentVersion,
        syncSpaceID: String,
        keyFingerprint: String,
        createdAt: Date,
        createdByDeviceID: String,
        authenticationCode: String
    ) {
        self.version = version
        self.syncSpaceID = syncSpaceID
        self.keyFingerprint = keyFingerprint
        self.createdAt = createdAt
        self.createdByDeviceID = createdByDeviceID
        self.authenticationCode = authenticationCode
    }

    public static func create(
        at rootURL: URL,
        keyData: Data,
        createdByDeviceID: String
    ) throws -> FolderSyncManifest {
        try FolderSyncFileSystem.validateKey(keyData)
        try FolderSyncFileSystem.validateIdentifier(createdByDeviceID, label: "device")
        let manifestURL = rootURL.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try load(from: rootURL, keyData: keyData)
        }

        let unsigned = UnsignedFields(
            version: currentVersion,
            syncSpaceID: UUID().uuidString.lowercased(),
            keyFingerprint: FolderSyncFileSystem.sha256(keyData),
            createdAt: Date(),
            createdByDeviceID: createdByDeviceID
        )
        let manifest = FolderSyncManifest(
            version: unsigned.version,
            syncSpaceID: unsigned.syncSpaceID,
            keyFingerprint: unsigned.keyFingerprint,
            createdAt: unsigned.createdAt,
            createdByDeviceID: unsigned.createdByDeviceID,
            authenticationCode: try authenticationCode(for: unsigned, keyData: keyData)
        )
        try manifest.write(to: rootURL, keyData: keyData)
        return try load(from: rootURL, keyData: keyData)
    }

    public static func load(
        from rootURL: URL,
        keyData: Data?
    ) throws -> FolderSyncManifest {
        let url = rootURL.appendingPathComponent(fileName, isDirectory: false)
        let data = try FolderSyncFileSystem.readData(
            at: url,
            maximumByteCount: FolderSyncLimits.maximumManifestBytes
        )
        let manifest: FolderSyncManifest
        do {
            manifest = try FolderSyncFileSystem.decoder.decode(FolderSyncManifest.self, from: data)
        } catch {
            throw ThreadlineError.invalidPayload("The folder sync manifest is malformed.")
        }
        try manifest.validateStructure()
        if let keyData {
            try manifest.validateAuthentication(keyData: keyData)
        }
        return manifest
    }

    public func write(to rootURL: URL, keyData: Data) throws {
        try validateStructure()
        try validateAuthentication(keyData: keyData)
        try FolderSyncFileSystem.ensureDirectory(rootURL)
        let data = try FolderSyncFileSystem.encoder.encode(self)
        guard data.count <= FolderSyncLimits.maximumManifestBytes else {
            throw ThreadlineError.invalidPayload("The folder sync manifest exceeds its safe size limit.")
        }
        let destination = rootURL.appendingPathComponent(Self.fileName, isDirectory: false)
        do {
            try FolderSyncFileSystem.writeDataAtomically(
                data,
                to: destination,
                replaceExisting: false
            )
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Self.load(from: rootURL, keyData: keyData)
            guard existing == self else {
                throw ThreadlineError.encryption(
                    "This folder already belongs to a different Threadline sync space."
                )
            }
        }
    }

    internal func validateStructure() throws {
        guard version == Self.currentVersion else {
            throw ThreadlineError.invalidPayload(
                "Unsupported folder sync manifest version: \(version)."
            )
        }
        guard UUID(uuidString: syncSpaceID) != nil,
              syncSpaceID.utf8.count <= FolderSyncLimits.maximumSyncSpaceIdentifierBytes else {
            throw ThreadlineError.invalidPayload("The folder sync-space identifier is invalid.")
        }
        try FolderSyncFileSystem.validateHash(keyFingerprint, label: "key fingerprint")
        try FolderSyncFileSystem.validateIdentifier(createdByDeviceID, label: "device")
        try FolderSyncFileSystem.validateHash(authenticationCode, label: "manifest authentication code")
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw ThreadlineError.invalidPayload("The folder sync manifest contains an invalid date.")
        }
    }

    internal func validateAuthentication(keyData: Data) throws {
        try FolderSyncFileSystem.validateKey(keyData)
        let actualFingerprint = FolderSyncFileSystem.sha256(keyData)
        guard actualFingerprint == keyFingerprint else {
            throw ThreadlineError.encryption(
                "The selected folder uses a different Threadline encryption key."
            )
        }
        let expected = try Self.authenticationCode(for: unsignedFields, keyData: keyData)
        guard FolderSyncFileSystem.constantTimeEqual(expected, authenticationCode) else {
            throw ThreadlineError.encryption("The folder sync manifest failed authentication.")
        }
    }

    private var unsignedFields: UnsignedFields {
        UnsignedFields(
            version: version,
            syncSpaceID: syncSpaceID,
            keyFingerprint: keyFingerprint,
            createdAt: createdAt,
            createdByDeviceID: createdByDeviceID
        )
    }

    private static func authenticationCode(
        for fields: UnsignedFields,
        keyData: Data
    ) throws -> String {
        let canonical = try FolderSyncFileSystem.encoder.encode(fields)
        let code = HMAC<SHA256>.authenticationCode(
            for: canonical,
            using: SymmetricKey(data: keyData)
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private struct UnsignedFields: Codable {
        let version: Int
        let syncSpaceID: String
        let keyFingerprint: String
        let createdAt: Date
        let createdByDeviceID: String
    }
}

enum FolderSyncLimits {
    static let maximumManifestBytes = 64 * 1_024
    static let maximumSegmentBytes = ((SyncEnvelopeLimits.maximumPayloadBytes + 2) / 3 * 4) + 128 * 1_024
    static let maximumProfileBytes = 128 * 1_024
    static let maximumRegistryOperationBytes = 64 * 1_024
    static let maximumRegistryOperationCount = 16_384
    static let maximumDeviceNamespaces = 512
    static let maximumSegmentsPerPull = 256
    static let maximumCursorBytes = 256 * 1_024
    static let maximumSyncSpaceIdentifierBytes = 128
}

enum FolderSyncFileSystem {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func validateKey(_ keyData: Data) throws {
        guard keyData.count == 32 else {
            throw ThreadlineError.encryption("Folder synchronization requires a 32-byte master key.")
        }
    }

    static func validateIdentifier(_ value: String, label: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= SyncEnvelopeLimits.maximumIdentifierBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ThreadlineError.invalidPayload("The folder sync \(label) identifier is invalid.")
        }
    }

    static func validateHash(_ value: String, label: String) throws {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw ThreadlineError.invalidPayload("The folder sync \(label) is invalid.")
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deviceDirectoryName(_ deviceID: String) -> String {
        sha256(Data(deviceID.utf8))
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    static func ensureDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ThreadlineError.invalidPayload(
                    "A folder sync path is not a safe directory."
                )
            }
            return
        }
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ThreadlineError.invalidPayload("A folder sync directory could not be created safely.")
        }
    }

    static func directoryContents(at url: URL) throws -> [URL] {
        var operationError: Error?
        var output: [URL] = []
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: url,
            options: [.immediatelyAvailableMetadataOnly],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                output = try FileManager.default.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    ],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return output
    }

    static func readData(at url: URL, maximumByteCount: Int) throws -> Data {
        var operationError: Error?
        var output: Data?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let fileSize = values.fileSize,
                      fileSize >= 0,
                      fileSize <= maximumByteCount else {
                    throw ThreadlineError.invalidPayload(
                        "A folder sync file exceeds its safe size or type limits."
                    )
                }
                let data = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
                guard data.count == fileSize, data.count <= maximumByteCount else {
                    throw ThreadlineError.invalidPayload(
                        "A folder sync file changed while it was being read."
                    )
                }
                output = data
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        guard let output else {
            throw ThreadlineError.unavailable("The folder sync file could not be read.")
        }
        return output
    }

    /// Reads an immutable, content-addressed sync object without file
    /// coordination. Callers must validate the object's content hash after
    /// this returns. Keeping this synchronous operation off transport actors
    /// lets File Provider materialization block only a cooperative worker.
    static func readImmutableData(at url: URL, maximumByteCount: Int) throws -> Data {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumByteCount else {
            throw ThreadlineError.invalidPayload(
                "A folder sync file exceeds its safe size or type limits."
            )
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try Task.checkCancellation()
        let finalValues = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              finalValues.fileSize == fileSize,
              data.count == fileSize,
              data.count <= maximumByteCount else {
            throw ThreadlineError.invalidPayload(
                "A folder sync file changed while it was being read."
            )
        }
        return data
    }

    static func writeDataAtomically(
        _ data: Data,
        to url: URL,
        replaceExisting: Bool
    ) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ThreadlineError.invalidPayload("Refusing to replace a symbolic link in the sync folder.")
        }

        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: url,
            options: replaceExisting ? [.forReplacing] : [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                if replaceExisting {
                    try data.write(to: coordinatedURL, options: [.atomic])
                } else {
                    try publishDataWithoutReplacing(data, to: coordinatedURL)
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    /// Publishes a complete file using an atomic same-directory rename. The
    /// temporary name is never observed by readers, and `moveItem` refuses to
    /// replace a winner that another process published first.
    static func publishDataWithoutReplacing(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(UUID().uuidString).partial",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
