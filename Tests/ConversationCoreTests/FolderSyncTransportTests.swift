import Foundation
import XCTest
@testable import ConversationCore

@MainActor
final class FolderSyncTransportTests: XCTestCase {
    func testPushPullAndCursorAreIncremental() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        let envelopes = [
            folderEnvelope(id: "one", origin: "writer-device", byte: 0x01),
            folderEnvelope(id: "two", origin: "writer-device", byte: 0x02),
        ]

        try await writer.push(envelopes)
        let first = try await reader.pull(since: SyncCursor())
        let second = try await reader.pull(since: first.cursor)

        XCTAssertEqual(first.envelopes.map(\.id), ["one", "two"])
        XCTAssertNotNil(first.cursor.token)
        XCTAssertTrue(second.envelopes.isEmpty)
        XCTAssertNotEqual(first.cursor, SyncCursor())
    }

    func testRepeatedPushOfSameEnvelopeIsIdempotent() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        let envelope = folderEnvelope(id: "same-object", origin: "writer-device", byte: 0x03)

        try await writer.push([envelope])
        try await writer.push([envelope])
        let pulled = try await reader.pull(since: SyncCursor())

        XCTAssertEqual(
            pulled.envelopes.map(\.id),
            [envelope.id],
            "Retrying an upload must not publish a second logical object"
        )
        XCTAssertEqual(try fixture.segmentFiles().count, 1)
    }

    func testLateSequenceIsNotSkippedByCursor() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        try await writer.push([
            folderEnvelope(id: "sequence-one", origin: "writer-device", byte: 0x11),
            folderEnvelope(id: "sequence-two", origin: "writer-device", byte: 0x12),
        ])
        let files = try fixture.segmentFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }
        let delayed = fixture.root.appending(path: ".delayed-sequence")
        try FileManager.default.moveItem(at: try XCTUnwrap(files.first), to: delayed)

        let gapPull = try await reader.pull(since: SyncCursor())
        XCTAssertTrue(gapPull.envelopes.isEmpty)

        try FileManager.default.moveItem(at: delayed, to: try XCTUnwrap(files.first))
        let recovered = try await reader.pull(since: gapPull.cursor)
        XCTAssertEqual(recovered.envelopes.map(\.id), ["sequence-one", "sequence-two"])
    }

    func testCorruptSegmentIsQuarantinedAndDoesNotBlockLaterSequence() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        try await writer.push([
            folderEnvelope(id: "corrupt-me", origin: "writer-device", byte: 0x21),
            folderEnvelope(id: "keep-me", origin: "writer-device", byte: 0x22),
        ])
        let files = try fixture.segmentFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }
        try Data("partial-or-corrupt".utf8).write(
            to: try XCTUnwrap(files.first),
            options: .atomic
        )

        let result = try await reader.pull(since: SyncCursor())

        XCTAssertEqual(result.envelopes.count, 2)
        XCTAssertEqual(result.envelopes.last?.id, "keep-me")
        XCTAssertTrue(result.envelopes.first?.objectType.hasPrefix("invalid-folder-segment:") == true)
        let after = try await reader.pull(since: result.cursor)
        XCTAssertTrue(after.envelopes.isEmpty)
    }

    func testPartialTemporaryFileIsIgnored() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        try await writer.push([
            folderEnvelope(id: "complete", origin: "writer-device", byte: 0x31),
        ])
        let segments = try XCTUnwrap(try fixture.segmentFiles().first?.deletingLastPathComponent())
        try Data("unfinished".utf8).write(to: segments.appending(path: "00000000000000000002.tmp"))

        let result = try await reader.pull(since: SyncCursor())
        XCTAssertEqual(result.envelopes.map(\.id), ["complete"])
    }

    func testSymlinkedDeviceOrSegmentEntryIsRejected() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let reader = fixture.transport(deviceID: "reader-device")
        let devices = fixture.root.appending(path: "devices", directoryHint: .isDirectory)
        let outside = fixture.root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: devices.appending(path: String(repeating: "a", count: 64)),
            withDestinationURL: outside
        )

        await XCTAssertThrowsFolderError(try await reader.pull(since: SyncCursor()))
    }

    func testIdentifierSurvivesFolderMoveAndDoesNotExposePath() throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let original = fixture.transport(deviceID: "writer-device")
        let moved = fixture.root.deletingLastPathComponent().appending(
            path: "moved-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        let movedManifest = try FolderSyncManifest.load(from: moved, keyData: fixture.key)
        let reopened = FolderSyncTransport(
            rootURL: moved,
            manifest: movedManifest,
            currentDeviceID: "writer-device"
        )

        XCTAssertEqual(original.identifier, reopened.identifier)
        XCTAssertFalse(original.identifier.contains(fixture.root.path))
        XCTAssertTrue(original.identifier.contains(fixture.manifest.syncSpaceID))
    }

    func testConcurrentReadsAreLimitedAndResultsPreserveSequenceOrder() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let probe = SegmentReadProbe()
        let reader = fixture.transport(deviceID: "reader-device") { url, maximumByteCount in
            probe.begin()
            defer { probe.end() }
            let sequence = Int(url.lastPathComponent.prefix(20)) ?? 0
            Thread.sleep(forTimeInterval: sequence == 1 ? 0.08 : 0.02)
            return try FolderSyncFileSystem.readImmutableData(
                at: url,
                maximumByteCount: maximumByteCount
            )
        }
        let envelopes = (1...12).map {
            folderEnvelope(id: "envelope-\($0)", origin: "writer-device", byte: UInt8($0))
        }
        try await writer.push(envelopes)

        let result = try await reader.pull(since: SyncCursor())

        XCTAssertEqual(result.envelopes.map(\.id), envelopes.map(\.id))
        XCTAssertGreaterThan(probe.maximumActive, 1)
        XCTAssertLessThanOrEqual(probe.maximumActive, 4)
    }

    func testTransientReadFailureDoesNotAdvanceFailedSequenceCursor() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let failure = OneShotSequenceFailure(sequence: 2)
        let reader = fixture.transport(deviceID: "reader-device") { url, maximumByteCount in
            if failure.shouldFail(url: url) {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try FolderSyncFileSystem.readImmutableData(
                at: url,
                maximumByteCount: maximumByteCount
            )
        }
        let envelopes = (1...3).map {
            folderEnvelope(id: "envelope-\($0)", origin: "writer-device", byte: UInt8($0))
        }
        try await writer.push(envelopes)

        let interrupted = try await reader.pull(since: SyncCursor())
        let resumed = try await reader.pull(since: interrupted.cursor)

        XCTAssertEqual(interrupted.envelopes.map(\.id), ["envelope-1"])
        XCTAssertEqual(interrupted.remainingItemCount, 2)
        XCTAssertEqual(resumed.envelopes.map(\.id), ["envelope-2", "envelope-3"])
        XCTAssertEqual(resumed.remainingItemCount, 0)
    }

    func testProgressAndRemainingCountsUseExactEncodedInventory() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let reader = fixture.transport(deviceID: "reader-device")
        let envelopes = (1...300).map {
            folderEnvelope(
                id: String(format: "envelope-%03d", $0),
                origin: "writer-device",
                byte: UInt8($0 % 251)
            )
        }
        try await writer.push(envelopes)
        let orderedFiles = try fixture.segmentFiles().sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        let expectedTotalBytes = try orderedFiles.reduce(Int64(0)) {
            $0 + Int64(try XCTUnwrap($1.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }
        let expectedFirstPullBytes = try orderedFiles.prefix(256).reduce(Int64(0)) {
            $0 + Int64(try XCTUnwrap($1.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }
        let progress = ProgressRecorder()

        let first = try await reader.pull(since: SyncCursor()) { update in
            progress.record(update)
        }
        let updates = progress.values

        XCTAssertEqual(first.envelopes.map(\.id), Array(envelopes.prefix(256)).map(\.id))
        XCTAssertEqual(first.remainingItemCount, 44)
        XCTAssertEqual(first.remainingByteCount, expectedTotalBytes - expectedFirstPullBytes)
        XCTAssertEqual(updates.first?.activity, .enumerating)
        XCTAssertEqual(updates.last?.completedItemCount, 256)
        XCTAssertEqual(updates.last?.completedByteCount, expectedFirstPullBytes)
        XCTAssertEqual(updates.last?.totalItemCount, 300)
        XCTAssertEqual(updates.last?.totalByteCount, expectedTotalBytes)
        XCTAssertEqual(
            updates.map(\.completedItemCount),
            updates.map(\.completedItemCount).sorted(),
            "Reported item progress must be monotonic"
        )
        XCTAssertEqual(
            updates.map(\.completedByteCount),
            updates.map(\.completedByteCount).sorted(),
            "Reported byte progress must be monotonic"
        )

        let second = try await reader.pull(since: first.cursor)
        XCTAssertEqual(second.envelopes.map(\.id), Array(envelopes.dropFirst(256)).map(\.id))
        XCTAssertEqual(second.remainingItemCount, 0)
        XCTAssertEqual(second.remainingByteCount, 0)
    }

    func testBlockedReadsTimeOutWithoutAdvancingCursorOrLeakingPastLimit() async throws {
        let fixture = try FolderTransportFixture()
        defer { fixture.cleanup() }
        let writer = fixture.transport(deviceID: "writer-device")
        let blocker = DeadlineReadBlocker()
        let reader = fixture.transport(
            deviceID: "reader-device",
            segmentReadTimeout: 0.05
        ) { url, maximumByteCount in
            try blocker.read(url: url, maximumByteCount: maximumByteCount)
        }
        let envelope = folderEnvelope(id: "blocked", origin: "writer-device", byte: 0x51)
        try await writer.push([envelope])

        let startedAt = ContinuousClock.now
        var cursor = SyncCursor()
        for _ in 0..<6 {
            let result = try await reader.pull(since: cursor)
            XCTAssertTrue(result.envelopes.isEmpty)
            XCTAssertEqual(result.remainingItemCount, 1)
            cursor = result.cursor
        }
        let elapsed = startedAt.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(blocker.startedCount, 4)

        blocker.unblock()
        try await Task.sleep(for: .milliseconds(50))
        let resumed = try await reader.pull(since: cursor)
        XCTAssertEqual(resumed.envelopes.map(\.id), [envelope.id])
        XCTAssertEqual(resumed.remainingItemCount, 0)
    }
}

private struct FolderTransportFixture {
    let root: URL
    let key: Data
    let manifest: FolderSyncManifest

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ThreadlineFolderTransportTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        key = Data(repeating: 0x5A, count: 32)
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

    func transport(
        deviceID: String,
        segmentReadTimeout: TimeInterval = 45,
        segmentDataReader: @escaping @Sendable (URL, Int) throws -> Data
    ) -> FolderSyncTransport {
        FolderSyncTransport(
            rootURL: root,
            manifest: manifest,
            currentDeviceID: deviceID,
            segmentReadTimeout: segmentReadTimeout,
            segmentDataReader: segmentDataReader
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

private final class SegmentReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximumActive = 0

    func begin() {
        lock.withLock {
            active += 1
            maximumActive = max(maximumActive, active)
        }
    }

    func end() {
        lock.withLock { active -= 1 }
    }
}

private final class OneShotSequenceFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let sequence: Int
    private var didFail = false

    init(sequence: Int) {
        self.sequence = sequence
    }

    func shouldFail(url: URL) -> Bool {
        lock.withLock {
            guard !didFail,
                  Int(url.lastPathComponent.prefix(20)) == sequence else { return false }
            didFail = true
            return true
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncTransportProgress] = []

    var values: [SyncTransportProgress] {
        lock.withLock { storage }
    }

    func record(_ progress: SyncTransportProgress) {
        lock.withLock { storage.append(progress) }
    }
}

private final class DeadlineReadBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var isBlocking = true
    private var starts = 0

    var startedCount: Int {
        lock.withLock { starts }
    }

    func read(url: URL, maximumByteCount: Int) throws -> Data {
        let shouldBlock = lock.withLock {
            starts += 1
            return isBlocking
        }
        if shouldBlock { semaphore.wait() }
        return try FolderSyncFileSystem.readImmutableData(
            at: url,
            maximumByteCount: maximumByteCount
        )
    }

    func unblock() {
        lock.withLock { isBlocking = false }
        for _ in 0..<4 { semaphore.signal() }
    }
}

private func folderEnvelope(id: String, origin: String, byte: UInt8) -> SyncEnvelope {
    SyncEnvelope(
        id: id,
        objectType: "conversation",
        logicalVersion: SyncEnvelopeLimits.authenticatedFormatVersion,
        originDeviceID: origin,
        createdAt: Date(timeIntervalSince1970: TimeInterval(byte)),
        encryptedPayload: Data(repeating: byte, count: 32),
        payloadHash: String(repeating: String(format: "%02x", byte), count: 32)
    )
}

@MainActor
private func XCTAssertThrowsFolderError<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected folder operation to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
