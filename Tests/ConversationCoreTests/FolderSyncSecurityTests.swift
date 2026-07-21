import Foundation
import XCTest
@testable import ConversationCore

@MainActor
final class FolderSyncSecurityTests: XCTestCase {
    func testManifestCreateAndLoadAuthenticatesEveryPersistedField() throws {
        let fixture = try FolderSecurityFixture()
        defer { fixture.cleanup() }
        let key = Data(repeating: 0x41, count: 32)

        let created = try FolderSyncManifest.create(
            at: fixture.folder,
            keyData: key,
            createdByDeviceID: "creator-device"
        )
        let loaded = try FolderSyncManifest.load(from: fixture.folder, keyData: key)

        XCTAssertEqual(loaded, created)
        XCTAssertEqual(loaded.version, FolderSyncManifest.currentVersion)
        XCTAssertNotNil(UUID(uuidString: loaded.syncSpaceID))
        XCTAssertEqual(loaded.createdByDeviceID, "creator-device")
        XCTAssertEqual(loaded.keyFingerprint.count, 64)
        XCTAssertEqual(loaded.authenticationCode.count, 64)
    }

    func testWrongKeyCannotLoadOrReplaceExistingManifest() throws {
        let fixture = try FolderSecurityFixture()
        defer { fixture.cleanup() }
        let winnerKey = Data(repeating: 0x11, count: 32)
        let wrongKey = Data(repeating: 0x22, count: 32)
        let winner = try FolderSyncManifest.create(
            at: fixture.folder,
            keyData: winnerKey,
            createdByDeviceID: "winner-device"
        )

        XCTAssertThrowsError(try FolderSyncManifest.load(from: fixture.folder, keyData: wrongKey))
        XCTAssertThrowsError(try FolderSyncManifest.create(
            at: fixture.folder,
            keyData: wrongKey,
            createdByDeviceID: "loser-device"
        ))
        XCTAssertEqual(
            try FolderSyncManifest.load(from: fixture.folder, keyData: winnerKey),
            winner
        )
    }

    func testTamperedManifestFailsAuthentication() throws {
        let fixture = try FolderSecurityFixture()
        defer { fixture.cleanup() }
        let key = Data(repeating: 0x33, count: 32)
        _ = try FolderSyncManifest.create(
            at: fixture.folder,
            keyData: key,
            createdByDeviceID: "creator-device"
        )
        let url = fixture.folder.appending(path: FolderSyncManifest.fileName)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["createdByDeviceID"] = "tampered-device"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        XCTAssertThrowsError(try FolderSyncManifest.load(from: fixture.folder, keyData: key))
    }

    func testMalformedOversizedAndSymlinkManifestAreRejected() throws {
        let fixture = try FolderSecurityFixture()
        defer { fixture.cleanup() }
        let key = Data(repeating: 0x44, count: 32)
        let manifestURL = fixture.folder.appending(path: FolderSyncManifest.fileName)

        try Data("not-json".utf8).write(to: manifestURL)
        XCTAssertThrowsError(try FolderSyncManifest.load(from: fixture.folder, keyData: key))

        try Data(repeating: 0x78, count: FolderSyncLimits.maximumManifestBytes + 1)
            .write(to: manifestURL, options: .atomic)
        XCTAssertThrowsError(try FolderSyncManifest.load(from: fixture.folder, keyData: key))

        try FileManager.default.removeItem(at: manifestURL)
        let outside = fixture.root.appending(path: "outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outside)
        XCTAssertThrowsError(try FolderSyncManifest.load(from: fixture.folder, keyData: key))
    }

    func testManifestNeverPersistsTheMasterKey() throws {
        let fixture = try FolderSecurityFixture()
        defer { fixture.cleanup() }
        let key = Data((0..<32).map(UInt8.init))
        _ = try FolderSyncManifest.create(
            at: fixture.folder,
            keyData: key,
            createdByDeviceID: "privacy-device"
        )

        let bytes = try Data(contentsOf: fixture.folder.appending(path: FolderSyncManifest.fileName))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(bytes.range(of: key) != nil)
        XCTAssertFalse(text.contains(key.base64EncodedString()))
        XCTAssertFalse(text.contains(key.map { String(format: "%02x", $0) }.joined()))
    }

    func testDirectImmutableReaderRejectsSymlinkAndOversizedFile() throws {
        let fixture = try FolderSecurityFixture()
        defer { fixture.cleanup() }
        let regular = fixture.folder.appending(path: "regular.tlenvelope")
        let symlink = fixture.folder.appending(path: "linked.tlenvelope")
        let oversized = fixture.folder.appending(path: "oversized.tlenvelope")
        try Data("segment".utf8).write(to: regular)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
        try Data(repeating: 0x41, count: 17).write(to: oversized)

        XCTAssertThrowsError(try FolderSyncFileSystem.readImmutableData(
            at: symlink,
            maximumByteCount: 64
        ))
        XCTAssertThrowsError(try FolderSyncFileSystem.readImmutableData(
            at: oversized,
            maximumByteCount: 16
        ))
    }
}

private struct FolderSecurityFixture {
    let root: URL
    let folder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineFolderSecurityTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        folder = root.appending(path: "sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
