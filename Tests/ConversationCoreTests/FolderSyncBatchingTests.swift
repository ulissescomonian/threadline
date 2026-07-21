import Foundation
import XCTest
@testable import ConversationCore

@MainActor
final class FolderSyncBatchingTests: XCTestCase {
    func testBatcherSplitsByBytesAndPreservesOrder() throws {
        let envelopes = [
            batchingEnvelope(id: "one", payloadBytes: 4),
            batchingEnvelope(id: "two", payloadBytes: 6),
            batchingEnvelope(id: "three", payloadBytes: 5),
        ]

        let batches = try SyncEnvelopeBatcher.batches(
            envelopes,
            maximumCount: 10,
            maximumBytes: 10
        )

        XCTAssertEqual(batches.map { $0.map(\.id) }, [["one", "two"], ["three"]])
        XCTAssertTrue(batches.allSatisfy {
            $0.reduce(0) { $0 + $1.encryptedPayload.count } <= 10
        })
    }

    func testBatcherSplitsByCountAtExactByteBoundary() throws {
        let envelopes = (1...5).map {
            batchingEnvelope(id: "envelope-\($0)", payloadBytes: 2)
        }

        let batches = try SyncEnvelopeBatcher.batches(
            envelopes,
            maximumCount: 2,
            maximumBytes: 4
        )

        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), envelopes.map(\.id))
    }

    func testBatcherRejectsSingleEnvelopeLargerThanBatch() {
        let envelope = batchingEnvelope(id: "too-large", payloadBytes: 11)

        XCTAssertThrowsError(
            try SyncEnvelopeBatcher.batches(
                [envelope],
                maximumCount: 10,
                maximumBytes: 10
            )
        )
    }

    func testFolderTransportPublishesMoreThanOneInternalCountBatch() async throws {
        let fixture = try FolderBatchingFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        let envelopes = (1...101).map {
            batchingEnvelope(
                id: "envelope-\($0)",
                origin: "writer-device",
                payloadBytes: 32,
                byte: UInt8($0 % 251)
            )
        }

        try await writer.push(envelopes)
        let result = try await reader.pull(since: SyncCursor())

        XCTAssertEqual(result.envelopes.map(\.id), envelopes.map(\.id))
        XCTAssertEqual(try fixture.segmentFiles().count, envelopes.count)
    }

    func testFolderTransportValidatesEveryOriginBeforeWriting() async throws {
        let fixture = try FolderBatchingFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let envelopes = [
            batchingEnvelope(id: "valid", origin: "writer-device", payloadBytes: 32),
            batchingEnvelope(id: "foreign", origin: "other-device", payloadBytes: 32),
        ]

        do {
            try await writer.push(envelopes)
            XCTFail("Expected a foreign-origin envelope to be rejected")
        } catch {
            // Expected.
        }

        XCTAssertTrue(try fixture.segmentFiles().isEmpty)
    }
}

private struct FolderBatchingFixture {
    let root: URL
    let key: Data
    let manifest: FolderSyncManifest

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineFolderBatchingTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        key = Data(repeating: 0x7B, count: 32)
        manifest = try FolderSyncManifest.create(
            at: root,
            keyData: key,
            createdByDeviceID: "fixture-device"
        )
    }

    func transport(deviceID: String) -> FolderSyncTransport {
        FolderSyncTransport(
            rootURL: root,
            manifest: manifest,
            currentDeviceID: deviceID
        )
    }

    func segmentFiles() throws -> [URL] {
        let devices = root.appending(path: "devices", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: devices.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: devices,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).flatMap { device -> [URL] in
            let segments = device.appending(path: "segments", directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: segments.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(
                at: segments,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "tlenvelope" }
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func batchingEnvelope(
    id: String,
    origin: String = "writer-device",
    payloadBytes: Int,
    byte: UInt8 = 0x41
) -> SyncEnvelope {
    SyncEnvelope(
        id: id,
        objectType: "conversation",
        logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
        originDeviceID: origin,
        createdAt: Date(timeIntervalSince1970: TimeInterval(byte)),
        encryptedPayload: Data(repeating: byte, count: payloadBytes),
        payloadHash: String(repeating: String(format: "%02x", byte), count: 32)
    )
}
