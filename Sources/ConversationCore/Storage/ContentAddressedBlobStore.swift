import CryptoKit
import Foundation

public actor ContentAddressedBlobStore {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = url(for: hash)
        if FileManager.default.fileExists(atPath: destination.path) { return hash }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: rootURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: destination.deletingLastPathComponent().path
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try data.write(to: temporary, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: destination.path
                )
            } catch where FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ThreadlineError.database("Could not persist content-addressed blob: \(error.localizedDescription)")
        }
        return hash
    }

    public func data(for hash: String) throws -> Data? {
        guard Self.isValidHash(hash) else {
            throw ThreadlineError.invalidPayload("Invalid blob hash")
        }
        let location = url(for: hash)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let data = try Data(contentsOf: location)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == hash else {
            throw ThreadlineError.invalidPayload("Blob content failed its integrity check")
        }
        return data
    }

    public func contains(_ hash: String) -> Bool {
        Self.isValidHash(hash) && FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    public func url(for hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return rootURL.appendingPathComponent(prefix, isDirectory: true).appendingPathComponent(hash)
    }

    private static func isValidHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
