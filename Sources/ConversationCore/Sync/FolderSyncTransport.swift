import Foundation

public actor FolderSyncTransport: SyncTransport {
    public nonisolated let identifier: String

    private let rootURL: URL
    private let manifest: FolderSyncManifest
    private let currentDeviceID: String
    private let currentDeviceDirectoryName: String
    private let segmentDataReader: @Sendable (URL, Int) throws -> Data
    private let segmentReadExecutor: FolderSegmentReadExecutor

    public init(
        rootURL: URL,
        manifest: FolderSyncManifest,
        currentDeviceID: String
    ) {
        self.rootURL = rootURL
        self.manifest = manifest
        self.currentDeviceID = currentDeviceID
        currentDeviceDirectoryName = FolderSyncFileSystem.deviceDirectoryName(currentDeviceID)
        segmentDataReader = { url, maximumByteCount in
            try FolderSyncFileSystem.readImmutableData(
                at: url,
                maximumByteCount: maximumByteCount
            )
        }
        segmentReadExecutor = FolderSegmentReadExecutor(
            maximumConcurrentReads: FolderSyncLimits.maximumConcurrentSegmentReads,
            timeout: FolderSyncLimits.segmentReadTimeout
        )
        identifier = "folder-v1:\(manifest.syncSpaceID)"
    }

    init(
        rootURL: URL,
        manifest: FolderSyncManifest,
        currentDeviceID: String,
        segmentReadTimeout: TimeInterval = FolderSyncLimits.segmentReadTimeout,
        segmentDataReader: @escaping @Sendable (URL, Int) throws -> Data
    ) {
        self.rootURL = rootURL
        self.manifest = manifest
        self.currentDeviceID = currentDeviceID
        currentDeviceDirectoryName = FolderSyncFileSystem.deviceDirectoryName(currentDeviceID)
        self.segmentDataReader = segmentDataReader
        segmentReadExecutor = FolderSegmentReadExecutor(
            maximumConcurrentReads: FolderSyncLimits.maximumConcurrentSegmentReads,
            timeout: segmentReadTimeout
        )
        identifier = "folder-v1:\(manifest.syncSpaceID)"
    }

    public func push(_ envelopes: [SyncEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        try validateConfiguredSpace()

        // Validate the complete logical upload before publishing its first
        // immutable segment. A malformed or foreign-origin envelope must not
        // leave a partially accepted prefix behind.
        for envelope in envelopes {
            try SyncEnvelopeLimits.validate(envelope)
            guard envelope.originDeviceID == currentDeviceID else {
                throw ThreadlineError.invalidPayload(
                    "A device can publish only envelopes created by its own Threadline installation."
                )
            }
        }

        let segmentsURL = try currentSegmentsURL()
        let batches = try SyncEnvelopeBatcher.batches(
            envelopes,
            maximumCount: 100,
            maximumBytes: SyncEnvelopeLimits.maximumTransportBatchBytes
        )
        for batch in batches {
            try Task.checkCancellation()
            try append(batch, to: segmentsURL)
        }
    }

    public func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        try await pull(since: cursor) { _ in }
    }

    public func pull(
        since cursor: SyncCursor,
        onProgress: @escaping @Sendable (SyncTransportProgress) async -> Void
    ) async throws -> SyncPullResult {
        try validateConfiguredSpace()
        var folderCursor = try decodeCursor(cursor.token)
        await onProgress(SyncTransportProgress(activity: .enumerating, completedItemCount: 0))
        let devicesURL = rootURL.appendingPathComponent("devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devicesURL.path) else {
            await onProgress(SyncTransportProgress(
                activity: .reading,
                completedItemCount: 0,
                totalItemCount: 0,
                completedByteCount: 0,
                totalByteCount: 0
            ))
            return SyncPullResult(
                envelopes: [],
                cursor: try encodedCursor(folderCursor, updatedAt: Date()),
                remainingItemCount: 0,
                remainingByteCount: 0
            )
        }

        let inventory = try pendingInventory(
            at: devicesURL,
            watermarks: folderCursor.watermarks
        )
        await onProgress(SyncTransportProgress(
            activity: .reading,
            completedItemCount: 0,
            totalItemCount: inventory.itemCount,
            completedByteCount: 0,
            totalByteCount: inventory.byteCount
        ))

        var pulled: [SyncEnvelope] = []
        var pulledPayloadBytes = 0
        var completedItemCount = 0
        var completedByteCount: Int64 = 0
        var reachedBatchLimit = false

        for device in inventory.devices {
            if reachedBatchLimit { break }
            var deviceBlocked = false
            var chunkStart = 0
            while chunkStart < device.sequences.count, !deviceBlocked, !reachedBatchLimit {
                try Task.checkCancellation()
                let chunkEnd = min(
                    chunkStart + FolderSyncLimits.maximumConcurrentSegmentReads,
                    device.sequences.count
                )
                let outcomes = await decodeConcurrently(
                    Array(device.sequences[chunkStart..<chunkEnd]),
                    deviceHash: device.deviceHash
                )
                for (sequence, outcome) in zip(
                    device.sequences[chunkStart..<chunkEnd],
                    outcomes
                ) {
                    try Task.checkCancellation()
                    switch outcome {
                    case .cancelled:
                        throw CancellationError()
                    case .transientFailure:
                        // File Provider can temporarily withhold placeholder
                        // contents. Never advance this device watermark for an
                        // I/O failure, even if later sequence names are visible.
                        deviceBlocked = true
                    case .decoded(let envelopes, let payloadByteCount):
                        let wouldExceedCount = pulled.count + envelopes.count
                            > FolderSyncLimits.maximumSegmentsPerPull
                        let (prospectivePayloadBytes, byteOverflow) = pulledPayloadBytes
                            .addingReportingOverflow(payloadByteCount)
                        let wouldExceedBytes = byteOverflow
                            || prospectivePayloadBytes > SyncEnvelopeLimits.maximumPullBatchBytes
                        if (wouldExceedCount || wouldExceedBytes), !pulled.isEmpty {
                            reachedBatchLimit = true
                            break
                        }
                        guard !wouldExceedCount, !wouldExceedBytes else {
                            throw ThreadlineError.invalidPayload(
                                "A single folder sync sequence exceeds the safe pull batch limits."
                            )
                        }

                        pulled.append(contentsOf: envelopes)
                        pulledPayloadBytes = prospectivePayloadBytes
                        folderCursor.watermarks[device.deviceHash] = sequence.sequence
                        completedItemCount += sequence.itemCount
                        completedByteCount = try Self.addingExact(
                            completedByteCount,
                            sequence.byteCount,
                            message: "The folder sync progress byte count overflowed."
                        )
                        await onProgress(SyncTransportProgress(
                            activity: .reading,
                            completedItemCount: completedItemCount,
                            totalItemCount: inventory.itemCount,
                            completedByteCount: completedByteCount,
                            totalByteCount: inventory.byteCount
                        ))
                    }
                    if deviceBlocked || reachedBatchLimit { break }
                }
                chunkStart = chunkEnd
            }
        }

        return SyncPullResult(
            envelopes: pulled,
            cursor: try encodedCursor(folderCursor, updatedAt: Date()),
            remainingItemCount: inventory.itemCount - completedItemCount,
            remainingByteCount: inventory.byteCount - completedByteCount
        )
    }

    public func healthCheck() async -> Bool {
        do {
            try validateConfiguredSpace()
            let values = try rootURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isWritableKey,
            ])
            return values.isDirectory == true
                && values.isSymbolicLink != true
                && values.isWritable == true
        } catch {
            return false
        }
    }

    private func validateConfiguredSpace() throws {
        try manifest.validateStructure()
        try FolderSyncFileSystem.validateIdentifier(currentDeviceID, label: "device")
        let diskManifest = try FolderSyncManifest.load(from: rootURL, keyData: nil)
        guard diskManifest == manifest else {
            throw ThreadlineError.encryption(
                "The selected folder no longer matches the configured Threadline sync space."
            )
        }
        try FolderSyncFileSystem.ensureDirectory(rootURL)
    }

    private func currentSegmentsURL() throws -> URL {
        let devicesURL = rootURL.appendingPathComponent("devices", isDirectory: true)
        let deviceURL = devicesURL.appendingPathComponent(
            currentDeviceDirectoryName,
            isDirectory: true
        )
        let segmentsURL = deviceURL.appendingPathComponent("segments", isDirectory: true)
        try FolderSyncFileSystem.ensureDirectory(devicesURL)
        try FolderSyncFileSystem.ensureDirectory(deviceURL)
        try FolderSyncFileSystem.ensureDirectory(segmentsURL)
        return segmentsURL
    }

    private func append(_ envelopes: [SyncEnvelope], to segmentsURL: URL) throws {
        let deviceURL = segmentsURL.deletingLastPathComponent()
        let publicationsURL = deviceURL.appendingPathComponent("published", isDirectory: true)
        try FolderSyncFileSystem.ensureDirectory(publicationsURL)
        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: deviceURL,
            options: [.forMerging],
            error: &coordinationError
        ) { coordinatedDeviceURL in
            do {
                let coordinatedURL = coordinatedDeviceURL.appendingPathComponent(
                    "segments",
                    isDirectory: true
                )
                let coordinatedPublicationsURL = coordinatedDeviceURL.appendingPathComponent(
                    "published",
                    isDirectory: true
                )
                let existing = try FileManager.default.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                guard existing.count <= FolderSyncLimits.maximumSegmentFilesPerDevice else {
                    throw ThreadlineError.invalidPayload(
                        "A device folder exceeds the safe segment-count limit."
                    )
                }
                let existingPublications = try FileManager.default.contentsOfDirectory(
                    at: coordinatedPublicationsURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
                guard existingPublications.count
                        <= FolderSyncLimits.maximumSegmentFilesPerDevice else {
                    throw ThreadlineError.invalidPayload(
                        "A device folder exceeds the safe publication-count limit."
                    )
                }
                let publicationsByEnvelopeHash = Dictionary(grouping: existingPublications) {
                    Self.publicationEnvelopeHash(from: $0.lastPathComponent) ?? ""
                }
                var sequence = max(
                    existing.compactMap {
                        Self.sequence(from: $0.lastPathComponent)
                    }.max() ?? 0,
                    existingPublications.compactMap {
                        Self.publicationSequence(from: $0.lastPathComponent)
                    }.max() ?? 0
                )

                for envelope in envelopes {
                    let envelopeHash = FolderSyncFileSystem.sha256(Data(envelope.id.utf8))
                    let existingMarkers = (publicationsByEnvelopeHash[envelopeHash] ?? [])
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    if existingMarkers.count > 1 {
                        throw ThreadlineError.invalidPayload(
                            "A folder sync envelope has competing publication markers."
                        )
                    }
                    if let existingMarkerURL = existingMarkers.first {
                        let marker = try Self.readPublicationMarker(at: existingMarkerURL)
                        try Self.validate(
                            marker,
                            fileName: existingMarkerURL.lastPathComponent,
                            envelope: envelope
                        )
                        let segment = FolderEnvelopeSegment(
                            version: 1,
                            sequence: marker.sequence,
                            writerDeviceHash: currentDeviceDirectoryName,
                            envelope: envelope
                        )
                        let segmentData = try FolderSyncFileSystem.encoder.encode(segment)
                        let segmentHash = FolderSyncFileSystem.sha256(segmentData)
                        let expectedSegmentName = Self.segmentFileName(
                            sequence: marker.sequence,
                            contentHash: segmentHash
                        )
                        guard marker.segmentFileName == expectedSegmentName else {
                            throw ThreadlineError.invalidPayload(
                                "A folder sync publication marker does not match its envelope."
                            )
                        }
                        let segmentURL = coordinatedURL.appendingPathComponent(expectedSegmentName)
                        if FileManager.default.fileExists(atPath: segmentURL.path) {
                            let existingData = try Self.readLocalFile(
                                at: segmentURL,
                                maximumByteCount: FolderSyncLimits.maximumSegmentBytes
                            )
                            guard FolderSyncFileSystem.sha256(existingData) == segmentHash else {
                                throw ThreadlineError.invalidPayload(
                                    "A published folder sync segment failed its integrity check."
                                )
                            }
                        } else {
                            try FolderSyncFileSystem.publishDataWithoutReplacing(
                                segmentData,
                                to: segmentURL
                            )
                        }
                        continue
                    }

                    let (next, overflow) = sequence.addingReportingOverflow(1)
                    guard !overflow, next > 0 else {
                        throw ThreadlineError.invalidPayload(
                            "The device segment sequence is exhausted."
                        )
                    }
                    sequence = next
                    let segment = FolderEnvelopeSegment(
                        version: 1,
                        sequence: sequence,
                        writerDeviceHash: currentDeviceDirectoryName,
                        envelope: envelope
                    )
                    let segmentData = try FolderSyncFileSystem.encoder.encode(segment)
                    guard segmentData.count <= FolderSyncLimits.maximumSegmentBytes else {
                        throw ThreadlineError.invalidPayload(
                            "A folder sync segment exceeds its safe encoded size limit."
                        )
                    }
                    let segmentHash = FolderSyncFileSystem.sha256(segmentData)
                    let segmentName = Self.segmentFileName(
                        sequence: sequence,
                        contentHash: segmentHash
                    )
                    let marker = FolderPublicationMarker(
                        version: 1,
                        sequence: sequence,
                        envelopeID: envelope.id,
                        envelopeHash: envelopeHash,
                        segmentFileName: segmentName,
                        segmentHash: segmentHash
                    )
                    let markerData = try FolderSyncFileSystem.encoder.encode(marker)
                    guard markerData.count <= FolderSyncLimits.maximumPublicationMarkerBytes else {
                        throw ThreadlineError.invalidPayload(
                            "A folder sync publication marker exceeds its safe size limit."
                        )
                    }
                    let markerName = Self.publicationFileName(
                        sequence: sequence,
                        envelopeHash: envelopeHash
                    )
                    try FolderSyncFileSystem.publishDataWithoutReplacing(
                        markerData,
                        to: coordinatedPublicationsURL.appendingPathComponent(markerName)
                    )
                    try FolderSyncFileSystem.publishDataWithoutReplacing(
                        segmentData,
                        to: coordinatedURL.appendingPathComponent(segmentName)
                    )
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func validatedDeviceDirectories(at devicesURL: URL) throws -> [URL] {
        let entries = try FolderSyncFileSystem.directoryContents(at: devicesURL)
        var devices: [URL] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ThreadlineError.invalidPayload(
                    "A symbolic link is not allowed in the folder sync device index."
                )
            }
            guard values.isDirectory == true else { continue }
            guard Self.isLowercaseHash(entry.lastPathComponent) else { continue }
            devices.append(entry)
            guard devices.count <= FolderSyncLimits.maximumDeviceNamespaces else {
                throw ThreadlineError.invalidPayload(
                    "The folder sync space exceeds its safe device limit."
                )
            }
        }
        return devices.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pendingInventory(
        at devicesURL: URL,
        watermarks: [String: Int64]
    ) throws -> FolderPendingInventory {
        var devices: [FolderPendingDevice] = []
        var itemCount = 0
        var byteCount: Int64 = 0

        for deviceURL in try validatedDeviceDirectories(at: devicesURL) {
            try Task.checkCancellation()
            let deviceHash = deviceURL.lastPathComponent
            let segmentsURL = deviceURL.appendingPathComponent("segments", isDirectory: true)
            guard FileManager.default.fileExists(atPath: segmentsURL.path) else { continue }
            let grouped = try segmentFilesBySequence(at: segmentsURL)
            var sequence = (watermarks[deviceHash] ?? 0) + 1
            var pendingSequences: [FolderPendingSequence] = []
            while let candidates = grouped[sequence] {
                let sorted = candidates.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
                let sequenceByteCount = try sorted.reduce(Int64(0)) { partial, candidate in
                    try Self.addingExact(
                        partial,
                        candidate.byteCount,
                        message: "A folder sync sequence byte count overflowed."
                    )
                }
                let sequenceItemCount = sorted.count
                    > FolderSyncLimits.maximumDuplicateSegmentsPerSequence ? 1 : sorted.count
                pendingSequences.append(FolderPendingSequence(
                    sequence: sequence,
                    candidates: sorted,
                    itemCount: sequenceItemCount,
                    byteCount: sequenceByteCount
                ))
                itemCount = try Self.addingExact(
                    itemCount,
                    sequenceItemCount,
                    message: "The folder sync pending item count overflowed."
                )
                byteCount = try Self.addingExact(
                    byteCount,
                    sequenceByteCount,
                    message: "The folder sync pending byte count overflowed."
                )
                sequence += 1
            }
            if !pendingSequences.isEmpty {
                devices.append(FolderPendingDevice(
                    deviceHash: deviceHash,
                    sequences: pendingSequences
                ))
            }
        }
        return FolderPendingInventory(
            devices: devices,
            itemCount: itemCount,
            byteCount: byteCount
        )
    }

    private func segmentFilesBySequence(
        at segmentsURL: URL
    ) throws -> [Int64: [FolderPendingCandidate]] {
        let entries = try FolderSyncFileSystem.directoryContents(at: segmentsURL)
        guard entries.count <= FolderSyncLimits.maximumSegmentFilesPerDevice else {
            throw ThreadlineError.invalidPayload(
                "A device folder exceeds the safe segment-count limit."
            )
        }
        var output: [Int64: [FolderPendingCandidate]] = [:]
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw ThreadlineError.invalidPayload(
                    "A symbolic link is not allowed in a folder sync segment directory."
                )
            }
            guard values.isRegularFile == true,
                  let sequence = Self.sequence(from: entry.lastPathComponent) else { continue }
            let byteCount = Int64(max(0, values.fileSize ?? 0))
            output[sequence, default: []].append(FolderPendingCandidate(
                url: entry,
                byteCount: byteCount
            ))
        }
        return output
    }

    private func decodeConcurrently(
        _ sequences: [FolderPendingSequence],
        deviceHash: String
    ) async -> [FolderSequenceDecodeOutcome] {
        let reader = segmentDataReader
        let executor = segmentReadExecutor
        return await withTaskGroup(
            of: (Int, FolderSequenceDecodeOutcome).self,
            returning: [FolderSequenceDecodeOutcome].self
        ) { group in
            for (index, sequence) in sequences.enumerated() {
                group.addTask {
                    let outcome = await Self.decode(
                        sequence,
                        expectedDeviceHash: deviceHash,
                        reader: reader,
                        executor: executor
                    )
                    return (index, outcome)
                }
            }
            var ordered = Array(
                repeating: FolderSequenceDecodeOutcome.transientFailure,
                count: sequences.count
            )
            for await (index, outcome) in group {
                ordered[index] = outcome
            }
            return ordered
        }
    }

    private nonisolated static func decode(
        _ sequence: FolderPendingSequence,
        expectedDeviceHash: String,
        reader: @escaping @Sendable (URL, Int) throws -> Data,
        executor: FolderSegmentReadExecutor
    ) async -> FolderSequenceDecodeOutcome {
        if Task.isCancelled { return .cancelled }
        if sequence.candidates.count > FolderSyncLimits.maximumDuplicateSegmentsPerSequence {
            return .decoded(
                envelopes: [quarantineEnvelope(
                    deviceHash: expectedDeviceHash,
                    sequence: sequence.sequence,
                    fileHash: "too-many-candidates",
                    reason: "A folder sync sequence contains too many competing segment files."
                )],
                payloadByteCount: 0
            )
        }

        var envelopes: [SyncEnvelope] = []
        var payloadByteCount = 0
        for candidate in sequence.candidates {
            if Task.isCancelled { return .cancelled }
            do {
                let readResult = await executor.read(
                    at: candidate.url,
                    maximumByteCount: FolderSyncLimits.maximumSegmentBytes,
                    reader: reader
                )
                let data: Data
                switch readResult {
                case .data(let value):
                    data = value
                case .failure(let error):
                    throw error
                case .transientFailure:
                    return .transientFailure
                case .cancelled:
                    return .cancelled
                }
                let envelope = try decodeSegment(
                    data: data,
                    at: candidate.url,
                    expectedSequence: sequence.sequence,
                    expectedDeviceHash: expectedDeviceHash
                )
                let (sum, overflow) = payloadByteCount.addingReportingOverflow(
                    envelope.encryptedPayload.count
                )
                guard !overflow, sum <= SyncEnvelopeLimits.maximumPullBatchBytes else {
                    throw ThreadlineError.invalidPayload(
                        "A folder sync sequence exceeds the safe pull size limit."
                    )
                }
                payloadByteCount = sum
                envelopes.append(envelope)
            } catch is CancellationError {
                return .cancelled
            } catch let error as ThreadlineError {
                switch error {
                case .invalidPayload, .encryption:
                    envelopes.append(quarantineEnvelope(
                        deviceHash: expectedDeviceHash,
                        sequence: sequence.sequence,
                        fileHash: fileHash(from: candidate.url.lastPathComponent) ?? "invalid",
                        reason: error.localizedDescription
                    ))
                case .unavailable, .database, .cloud, .incompatibleProvider:
                    return .transientFailure
                }
            } catch {
                return .transientFailure
            }
        }
        return .decoded(envelopes: envelopes, payloadByteCount: payloadByteCount)
    }

    private nonisolated static func decodeSegment(
        data: Data,
        at url: URL,
        expectedSequence: Int64,
        expectedDeviceHash: String
    ) throws -> SyncEnvelope {
        guard let fileHash = Self.fileHash(from: url.lastPathComponent),
              FolderSyncFileSystem.constantTimeEqual(
                FolderSyncFileSystem.sha256(data),
                fileHash
              ) else {
            throw ThreadlineError.invalidPayload(
                "A folder sync segment failed its content-address check."
            )
        }
        let segment: FolderEnvelopeSegment
        do {
            segment = try FolderSyncFileSystem.decoder.decode(FolderEnvelopeSegment.self, from: data)
        } catch {
            throw ThreadlineError.invalidPayload("A folder sync segment is malformed.")
        }
        guard segment.version == 1,
              segment.sequence == expectedSequence,
              segment.writerDeviceHash == expectedDeviceHash,
              FolderSyncFileSystem.deviceDirectoryName(segment.envelope.originDeviceID)
                == expectedDeviceHash else {
            throw ThreadlineError.invalidPayload(
                "A folder sync segment does not match its device namespace."
            )
        }
        try SyncEnvelopeLimits.validate(segment.envelope)
        return segment.envelope
    }

    private nonisolated static func addingExact<T: FixedWidthInteger>(
        _ lhs: T,
        _ rhs: T,
        message: String
    ) throws -> T {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ThreadlineError.invalidPayload(message) }
        return sum
    }

    private func decodeCursor(_ data: Data?) throws -> FolderTransportCursor {
        guard let data else {
            return FolderTransportCursor(
                version: 1,
                syncSpaceID: manifest.syncSpaceID,
                watermarks: [:]
            )
        }
        guard data.count <= FolderSyncLimits.maximumCursorBytes,
              data.count <= SyncEnvelopeLimits.maximumCursorBytes else {
            throw ThreadlineError.invalidPayload(
                "The folder sync cursor exceeds its safe size limit."
            )
        }
        let decoded: FolderTransportCursor
        do {
            decoded = try FolderSyncFileSystem.decoder.decode(FolderTransportCursor.self, from: data)
        } catch {
            throw ThreadlineError.invalidPayload("The folder sync cursor is malformed.")
        }
        guard decoded.version == 1,
              decoded.syncSpaceID == manifest.syncSpaceID,
              decoded.watermarks.count <= FolderSyncLimits.maximumDeviceNamespaces,
              decoded.watermarks.allSatisfy({ key, value in
                  Self.isLowercaseHash(key) && value >= 0
              }) else {
            throw ThreadlineError.invalidPayload("The folder sync cursor is invalid.")
        }
        return decoded
    }

    private func encodedCursor(
        _ folderCursor: FolderTransportCursor,
        updatedAt: Date
    ) throws -> SyncCursor {
        let data = try FolderSyncFileSystem.encoder.encode(folderCursor)
        guard data.count <= FolderSyncLimits.maximumCursorBytes,
              data.count <= SyncEnvelopeLimits.maximumCursorBytes else {
            throw ThreadlineError.invalidPayload(
                "The folder sync cursor exceeds its safe encoded size limit."
            )
        }
        return SyncCursor(token: data, updatedAt: updatedAt)
    }

    private static func sequence(from fileName: String) -> Int64? {
        guard fileName.hasSuffix(".tlenvelope") else { return nil }
        let stem = String(fileName.dropLast(".tlenvelope".count))
        guard stem.count == 20 + 1 + 64 else { return nil }
        let separator = stem.index(stem.startIndex, offsetBy: 20)
        guard stem[separator] == "-" else { return nil }
        let sequenceText = String(stem[..<separator])
        let hashStart = stem.index(after: separator)
        let hash = String(stem[hashStart...])
        guard sequenceText.allSatisfy(\.isNumber),
              isLowercaseHash(hash),
              let sequence = Int64(sequenceText),
              sequence > 0 else { return nil }
        return sequence
    }

    private static func fileHash(from fileName: String) -> String? {
        guard sequence(from: fileName) != nil else { return nil }
        let stem = String(fileName.dropLast(".tlenvelope".count))
        return String(stem.suffix(64))
    }

    private static func segmentFileName(sequence: Int64, contentHash: String) -> String {
        String(format: "%020lld-%@.tlenvelope", sequence, contentHash)
    }

    private static func publicationFileName(sequence: Int64, envelopeHash: String) -> String {
        String(format: "%020lld-%@.tlpublished", sequence, envelopeHash)
    }

    private static func publicationSequence(from fileName: String) -> Int64? {
        guard fileName.hasSuffix(".tlpublished") else { return nil }
        let stem = String(fileName.dropLast(".tlpublished".count))
        guard stem.count == 20 + 1 + 64 else { return nil }
        let separator = stem.index(stem.startIndex, offsetBy: 20)
        guard stem[separator] == "-" else { return nil }
        let sequenceText = String(stem[..<separator])
        let hash = String(stem[stem.index(after: separator)...])
        guard sequenceText.allSatisfy(\.isNumber),
              isLowercaseHash(hash),
              let sequence = Int64(sequenceText),
              sequence > 0 else { return nil }
        return sequence
    }

    private static func publicationEnvelopeHash(from fileName: String) -> String? {
        guard publicationSequence(from: fileName) != nil else { return nil }
        let stem = String(fileName.dropLast(".tlpublished".count))
        return String(stem.suffix(64))
    }

    private static func readPublicationMarker(at url: URL) throws -> FolderPublicationMarker {
        let data = try readLocalFile(
            at: url,
            maximumByteCount: FolderSyncLimits.maximumPublicationMarkerBytes
        )
        do {
            return try FolderSyncFileSystem.decoder.decode(FolderPublicationMarker.self, from: data)
        } catch {
            throw ThreadlineError.invalidPayload(
                "A folder sync publication marker is malformed."
            )
        }
    }

    private static func readLocalFile(at url: URL, maximumByteCount: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumByteCount else {
            throw ThreadlineError.invalidPayload(
                "A local folder sync publication file is unsafe."
            )
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == fileSize else {
            throw ThreadlineError.invalidPayload(
                "A local folder sync publication changed while being read."
            )
        }
        return data
    }

    private static func validate(
        _ marker: FolderPublicationMarker,
        fileName: String,
        envelope: SyncEnvelope
    ) throws {
        guard marker.version == 1,
              marker.sequence == publicationSequence(from: fileName),
              marker.envelopeID == envelope.id,
              marker.envelopeHash == publicationEnvelopeHash(from: fileName),
              marker.envelopeHash == FolderSyncFileSystem.sha256(Data(envelope.id.utf8)),
              fileHash(from: marker.segmentFileName) == marker.segmentHash else {
            throw ThreadlineError.invalidPayload(
                "A folder sync publication marker is invalid."
            )
        }
    }

    private static func isLowercaseHash(_ value: String) -> Bool {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.utf8.count == 64
            && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }

    private static func quarantineEnvelope(
        deviceHash: String,
        sequence: Int64,
        fileHash: String,
        reason: String
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: "folder-segment:\(String(deviceHash.prefix(16))):\(sequence):\(String(fileHash.prefix(32)))",
            objectType: "invalid-folder-segment:\(String(reason.prefix(512)))",
            logicalVersion: 0,
            originDeviceID: "folder-device:\(String(deviceHash.prefix(32)))",
            createdAt: Date(),
            encryptedPayload: Data(),
            payloadHash: "unavailable"
        )
    }
}

private struct FolderEnvelopeSegment: Codable {
    let version: Int
    let sequence: Int64
    let writerDeviceHash: String
    let envelope: SyncEnvelope
}

private struct FolderTransportCursor: Codable {
    let version: Int
    let syncSpaceID: String
    var watermarks: [String: Int64]
}

private struct FolderPublicationMarker: Codable {
    let version: Int
    let sequence: Int64
    let envelopeID: String
    let envelopeHash: String
    let segmentFileName: String
    let segmentHash: String
}

private struct FolderPendingInventory: Sendable {
    let devices: [FolderPendingDevice]
    let itemCount: Int
    let byteCount: Int64
}

private struct FolderPendingDevice: Sendable {
    let deviceHash: String
    let sequences: [FolderPendingSequence]
}

private struct FolderPendingSequence: Sendable {
    let sequence: Int64
    let candidates: [FolderPendingCandidate]
    let itemCount: Int
    let byteCount: Int64
}

private struct FolderPendingCandidate: Sendable {
    let url: URL
    let byteCount: Int64
}

private enum FolderSequenceDecodeOutcome: Sendable {
    case decoded(envelopes: [SyncEnvelope], payloadByteCount: Int)
    case transientFailure
    case cancelled
}

private enum FolderSegmentReadResult: Sendable {
    case data(Data)
    case failure(ThreadlineError)
    case transientFailure
    case cancelled
}

/// Bounds synchronous File Provider materializations independently of Swift's
/// cooperative executor. A timed-out read may finish late, but it keeps its
/// slot until then and its result cannot resume the caller a second time.
private final class FolderSegmentReadExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumConcurrentReads: Int
    private let timeout: TimeInterval
    private var activeReadCount = 0

    init(maximumConcurrentReads: Int, timeout: TimeInterval) {
        self.maximumConcurrentReads = max(1, maximumConcurrentReads)
        self.timeout = max(0.001, timeout)
    }

    func read(
        at url: URL,
        maximumByteCount: Int,
        reader: @escaping @Sendable (URL, Int) throws -> Data
    ) async -> FolderSegmentReadResult {
        let resolution = FolderSegmentReadResolution()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolution.install(continuation)
                guard !Task.isCancelled else {
                    resolution.resolve(.cancelled)
                    return
                }
                guard claimSlot() else {
                    resolution.resolve(.transientFailure)
                    return
                }

                DispatchQueue.global(qos: .utility).async { [self] in
                    let result: FolderSegmentReadResult
                    do {
                        result = .data(try reader(url, maximumByteCount))
                    } catch is CancellationError {
                        result = .cancelled
                    } catch let error as ThreadlineError {
                        result = .failure(error)
                    } catch {
                        result = .transientFailure
                    }
                    releaseSlot()
                    resolution.resolve(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout
                ) {
                    resolution.resolve(.transientFailure)
                }
            }
        } onCancel: {
            resolution.resolve(.cancelled)
        }
    }

    private func claimSlot() -> Bool {
        lock.withLock {
            guard activeReadCount < maximumConcurrentReads else { return false }
            activeReadCount += 1
            return true
        }
    }

    private func releaseSlot() {
        lock.withLock { activeReadCount -= 1 }
    }
}

private final class FolderSegmentReadResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FolderSegmentReadResult, Never>?
    private var pendingResult: FolderSegmentReadResult?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<FolderSegmentReadResult, Never>) {
        let result = lock.withLock { () -> FolderSegmentReadResult? in
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(returning: result) }
    }

    func resolve(_ result: FolderSegmentReadResult) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<FolderSegmentReadResult, Never>? in
            guard !isResolved else { return nil }
            isResolved = true
            if let continuation = self.continuation {
                self.continuation = nil
                return continuation
            }
            pendingResult = result
            return nil
        }
        continuation?.resume(returning: result)
    }
}

private extension FolderSyncLimits {
    static let maximumDuplicateSegmentsPerSequence = 8
    static let maximumConcurrentSegmentReads = 4
    static let segmentReadTimeout: TimeInterval = 45
    static let maximumSegmentFilesPerDevice = 1_000_000
    static let maximumPublicationMarkerBytes = 64 * 1_024
}
