import CryptoKit
import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(foundationObject value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [Any]:
            self = .array(try value.map(JSONValue.init(foundationObject:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(JSONValue.init(foundationObject:)))
        default:
            throw JSONValueConversionError.unsupportedFoundationValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    var compactString: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return ""
        case .array, .object:
            return (try? String(decoding: JSONEncoder.sorted.encode(self), as: UTF8.self)) ?? ""
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

struct JSONLReadResult: Sendable {
    let fingerprint: String
    let validLineCount: Int
    let skippedLineCount: Int
    let bytesRead: Int64
    let isTruncated: Bool
    let omittedByteCount: Int64
}

enum StreamingJSONL {
    static func read(
        _ url: URL,
        chunkSize: Int = 64 * 1_024,
        maximumLineBytes: Int = 4 * 1_024 * 1_024,
        maximumFileBytes: Int = 8 * 1_024 * 1_024,
        onOversizedLine: ((Int64, Int) throws -> Void)? = nil,
        onTruncatedRegion: ((Int64, Int64) throws -> Void)? = nil,
        onValue: (JSONValue, Data, Int64) throws -> Void
    ) throws -> JSONLReadResult {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ProviderKitError.unreadableSource(url.path)
        }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let reportedSize = (attributes?[.size] as? NSNumber)?.int64Value
        let modificationDate = attributes?[.modificationDate] as? Date
        let fileSize: Int64
        if let reportedSize, reportedSize >= 0 {
            fileSize = reportedSize
        } else {
            let end = try handle.seekToEnd()
            guard end <= UInt64(Int64.max) else {
                throw ProviderKitError.unreadableSource(url.path)
            }
            fileSize = Int64(end)
            try handle.seek(toOffset: 0)
        }

        let budget = max(2, maximumFileBytes)
        if fileSize > Int64(budget) {
            return try readSampled(
                handle: handle,
                fileSize: fileSize,
                modificationDate: modificationDate,
                budget: budget,
                chunkSize: max(1, chunkSize),
                maximumLineBytes: maximumLineBytes,
                onOversizedLine: onOversizedLine,
                onTruncatedRegion: onTruncatedRegion,
                onValue: onValue
            )
        }

        try handle.seek(toOffset: 0)
        return try readComplete(
            handle: handle,
            chunkSize: max(1, chunkSize),
            maximumLineBytes: maximumLineBytes,
            onOversizedLine: onOversizedLine,
            onValue: onValue
        )
    }

    private static func readComplete(
        handle: FileHandle,
        chunkSize: Int,
        maximumLineBytes: Int,
        onOversizedLine: ((Int64, Int) throws -> Void)?,
        onValue: (JSONValue, Data, Int64) throws -> Void
    ) throws -> JSONLReadResult {

        var buffer = Data()
        var offset: Int64 = 0
        var hasher = SHA256()
        var valid = 0
        var skipped = 0
        var discardingOversizedLine = false
        var oversizedStartOffset: Int64 = 0
        var oversizedByteCount = 0

        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            buffer.append(chunk)

            if discardingOversizedLine {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let consumed = buffer.distance(from: buffer.startIndex, to: newline) + 1
                    oversizedByteCount += consumed
                    buffer.removeFirst(consumed)
                    offset += Int64(consumed)
                    try onOversizedLine?(oversizedStartOffset, oversizedByteCount)
                    discardingOversizedLine = false
                    oversizedByteCount = 0
                } else {
                    oversizedByteCount += buffer.count
                    offset += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
            }

            while let newline = buffer.firstIndex(of: 0x0A) {
                try Task.checkCancellation()
                let lineLength = buffer.distance(from: buffer.startIndex, to: newline)
                if lineLength > maximumLineBytes {
                    try onOversizedLine?(offset, lineLength + 1)
                    skipped += 1
                    buffer.removeFirst(lineLength + 1)
                    offset += Int64(lineLength + 1)
                    continue
                }
                let line = Data(buffer.prefix(lineLength))
                buffer.removeFirst(lineLength + 1)
                try decode(line: line, offset: offset, maximumLineBytes: maximumLineBytes, valid: &valid, skipped: &skipped, onValue: onValue)
                offset += Int64(lineLength + 1)
            }

            if buffer.count > maximumLineBytes {
                skipped += 1
                discardingOversizedLine = true
                oversizedStartOffset = offset
                oversizedByteCount = buffer.count
                offset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if discardingOversizedLine {
            try onOversizedLine?(oversizedStartOffset, oversizedByteCount)
        } else if !buffer.isEmpty {
            try decode(line: buffer, offset: offset, maximumLineBytes: maximumLineBytes, valid: &valid, skipped: &skipped, onValue: onValue)
        }

        return JSONLReadResult(
            fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            validLineCount: valid,
            skippedLineCount: skipped,
            bytesRead: offset + Int64(buffer.count),
            isTruncated: false,
            omittedByteCount: 0
        )
    }

    private static func readSampled(
        handle: FileHandle,
        fileSize: Int64,
        modificationDate: Date?,
        budget: Int,
        chunkSize: Int,
        maximumLineBytes: Int,
        onOversizedLine: ((Int64, Int) throws -> Void)?,
        onTruncatedRegion: ((Int64, Int64) throws -> Void)?,
        onValue: (JSONValue, Data, Int64) throws -> Void
    ) throws -> JSONLReadResult {
        // Reserve one byte so the tail can include the byte immediately before
        // its window and determine whether it already starts on a line boundary.
        let headBudget = max(1, budget / 2 - 1)
        let tailBudget = max(1, budget - headBudget)
        let head = try readRange(
            handle: handle,
            offset: 0,
            count: headBudget,
            chunkSize: chunkSize
        )
        let desiredTailStart = max(0, fileSize - Int64(tailBudget - 1))
        let tailReadStart = max(0, desiredTailStart - 1)
        let tail = try readRange(
            handle: handle,
            offset: tailReadStart,
            count: Int(min(Int64(tailBudget), fileSize - tailReadStart)),
            chunkSize: chunkSize
        )

        let headCompleteCount: Int
        if let newline = head.lastIndex(of: 0x0A) {
            headCompleteCount = head.distance(from: head.startIndex, to: newline) + 1
        } else {
            headCompleteCount = 0
        }
        let tailContentIndex: Data.Index
        if tailReadStart == 0 {
            tailContentIndex = tail.startIndex
        } else if tail.first == 0x0A {
            tailContentIndex = tail.index(after: tail.startIndex)
        } else if let newline = tail.firstIndex(of: 0x0A) {
            tailContentIndex = tail.index(after: newline)
        } else {
            tailContentIndex = tail.endIndex
        }
        let tailContentOffset = tailReadStart + Int64(tail.distance(from: tail.startIndex, to: tailContentIndex))
        let headContentEnd = Int64(headCompleteCount)
        let omittedBytes = max(0, tailContentOffset - headContentEnd)

        var valid = 0
        var skipped = 0
        try decodeRegion(
            Data(head.prefix(headCompleteCount)),
            baseOffset: 0,
            includesFinalPartialLine: false,
            maximumLineBytes: maximumLineBytes,
            valid: &valid,
            skipped: &skipped,
            onOversizedLine: onOversizedLine,
            onValue: onValue
        )
        if omittedBytes > 0 {
            try Task.checkCancellation()
            try onTruncatedRegion?(headContentEnd, omittedBytes)
        }
        try decodeRegion(
            Data(tail[tailContentIndex...]),
            baseOffset: tailContentOffset,
            includesFinalPartialLine: true,
            maximumLineBytes: maximumLineBytes,
            valid: &valid,
            skipped: &skipped,
            onOversizedLine: onOversizedLine,
            onValue: onValue
        )

        var hasher = SHA256()
        hasher.update(data: Data("threadline-jsonl-sample-v2\u{0}\(fileSize)\u{0}".utf8))
        let modifiedNanoseconds = Int64(((modificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000_000).rounded())
        hasher.update(data: Data("\(modifiedNanoseconds)\u{0}".utf8))
        hasher.update(data: head)
        hasher.update(data: Data([0]))
        hasher.update(data: tail)
        return JSONLReadResult(
            fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            validLineCount: valid,
            skippedLineCount: skipped,
            bytesRead: Int64(head.count + tail.count),
            isTruncated: true,
            omittedByteCount: omittedBytes
        )
    }

    private static func readRange(
        handle: FileHandle,
        offset: Int64,
        count: Int,
        chunkSize: Int
    ) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        var output = Data()
        output.reserveCapacity(count)
        while output.count < count {
            try Task.checkCancellation()
            let requested = min(chunkSize, count - output.count)
            let chunk = try handle.read(upToCount: requested) ?? Data()
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        return output
    }

    private static func decodeRegion(
        _ data: Data,
        baseOffset: Int64,
        includesFinalPartialLine: Bool,
        maximumLineBytes: Int,
        valid: inout Int,
        skipped: inout Int,
        onOversizedLine: ((Int64, Int) throws -> Void)?,
        onValue: (JSONValue, Data, Int64) throws -> Void
    ) throws {
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            try Task.checkCancellation()
            let line = Data(data[lineStart..<newline])
            let relativeOffset = data.distance(from: data.startIndex, to: lineStart)
            if line.count > maximumLineBytes {
                skipped += 1
                try onOversizedLine?(baseOffset + Int64(relativeOffset), line.count + 1)
            } else {
                try decode(
                    line: line,
                    offset: baseOffset + Int64(relativeOffset),
                    maximumLineBytes: maximumLineBytes,
                    valid: &valid,
                    skipped: &skipped,
                    onValue: onValue
                )
            }
            lineStart = data.index(after: newline)
        }
        if includesFinalPartialLine, lineStart < data.endIndex {
            try Task.checkCancellation()
            let relativeOffset = data.distance(from: data.startIndex, to: lineStart)
            let line = Data(data[lineStart...])
            if line.count > maximumLineBytes {
                skipped += 1
                try onOversizedLine?(baseOffset + Int64(relativeOffset), line.count)
            } else {
                try decode(
                    line: line,
                    offset: baseOffset + Int64(relativeOffset),
                    maximumLineBytes: maximumLineBytes,
                    valid: &valid,
                    skipped: &skipped,
                    onValue: onValue
                )
            }
        }
    }

    private static func decode(
        line: Data,
        offset: Int64,
        maximumLineBytes: Int,
        valid: inout Int,
        skipped: inout Int,
        onValue: (JSONValue, Data, Int64) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let normalized = line.last == 0x0D ? Data(line.dropLast()) : line
        guard !normalized.isEmpty, normalized.count <= maximumLineBytes else {
            if !normalized.isEmpty { skipped += 1 }
            return
        }
        do {
            // Foundation's JSON parser avoids the recursive failed-decoding
            // probes required by `JSONValue.init(from:)` for every scalar in a
            // provider event. Converting the parsed tree preserves the same
            // value model while substantially reducing full-history CPU time.
            let object = try JSONSerialization.jsonObject(
                with: normalized,
                options: [.fragmentsAllowed]
            )
            let value = try JSONValue(foundationObject: object)
            try onValue(value, normalized, offset)
            valid += 1
        } catch let error as CancellationError {
            throw error
        } catch let error as ProviderKitError {
            throw error
        } catch {
            // A live writer can leave one partial line. The next reconciliation reads it again.
            skipped += 1
        }
    }
}

private enum JSONValueConversionError: Error {
    case unsupportedFoundationValue
}

enum ProviderFiles {
    private struct ImportCandidate {
        let url: URL
        let modificationDate: Date
        let fileSize: Int64
    }

    static func jsonlFiles(
        below root: URL,
        modifiedSince: Date? = nil,
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [ImportCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl",
                  !url.lastPathComponent.lowercased().contains("auth"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else { continue }
            let modificationDate = values.contentModificationDate ?? .distantPast
            if let modifiedSince, modificationDate < modifiedSince { continue }
            files.append(ImportCandidate(
                url: url.standardizedFileURL,
                modificationDate: modificationDate,
                fileSize: Int64(values.fileSize ?? Int.max)
            ))
        }
        return files.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            if lhs.fileSize != rhs.fileSize { return lhs.fileSize < rhs.fileSize }
            return lhs.url.path < rhs.url.path
        }.map(\.url)
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max)
    }

    static func importPriority(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftDate = modificationDate(lhs) ?? .distantPast
        let rightDate = modificationDate(rhs) ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        let leftSize = fileSize(lhs)
        let rightSize = fileSize(rhs)
        if leftSize != rightSize { return leftSize < rightSize }
        return lhs.path < rhs.path
    }
}
