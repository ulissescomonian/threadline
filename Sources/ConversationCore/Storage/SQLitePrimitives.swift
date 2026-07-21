import CSQLite
import Foundation

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let path: String

    init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: parent.path
            )
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ThreadlineError.database("Could not open the conversation database: \(message)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        try enforceSecurePermissions()
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw databaseError(prefix: "SQLite statement failed")
        }
    }

    func rows(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var output: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else {
                throw databaseError(prefix: "SQLite query failed")
            }
            output.append((0..<sqlite3_column_count(statement)).map { columnValue(statement, index: $0) })
        }
    }

    func scalarInt(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int64 {
        guard let row = try rows(sql, bindings: bindings).first,
              case .integer(let value) = row.first
        else { return 0 }
        return value
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            try enforceSecurePermissions()
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func enforceSecurePermissions() throws {
        guard path != ":memory:" else { return }
        let fileManager = FileManager.default
        for candidate in [path, path + "-wal", path + "-shm"] where fileManager.fileExists(atPath: candidate) {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: candidate
            )
        }
    }

    /// Creates a transactionally consistent snapshot using SQLite's online
    /// backup API. A healthy snapshot already at `destinationPath` is kept so
    /// a later launch cannot replace the known-good pre-migration recovery
    /// point. New snapshots are written privately and atomically published.
    func backupIfNeeded(to destinationPath: String) throws {
        guard path != ":memory:", destinationPath != ":memory:" else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationPath),
           Self.databaseValidationError(at: destinationPath) == nil {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destinationPath
            )
            return
        }

        let temporaryPath = destinationPath + ".tmp-" + UUID().uuidString
        defer { try? fileManager.removeItem(atPath: temporaryPath) }

        var destinationHandle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            temporaryPath,
            &destinationHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, destinationHandle != nil else {
            let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw ThreadlineError.database("Could not create the migration backup: \(message)")
        }
        defer {
            if let destinationHandle { sqlite3_close(destinationHandle) }
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporaryPath
        )
        guard let handle else { throw ThreadlineError.database("The database is closed") }
        guard let backup = sqlite3_backup_init(destinationHandle, "main", handle, "main") else {
            throw ThreadlineError.database(
                "Could not initialize the migration backup: \(String(cString: sqlite3_errmsg(destinationHandle)))"
            )
        }
        var stepResult = sqlite3_backup_step(backup, -1)
        var busyAttempts = 0
        while (stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED), busyAttempts < 100 {
            sqlite3_sleep(50)
            busyAttempts += 1
            stepResult = sqlite3_backup_step(backup, -1)
        }
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw ThreadlineError.database(
                "Could not complete the migration backup: \(String(cString: sqlite3_errmsg(destinationHandle)))"
            )
        }
        guard sqlite3_close(destinationHandle) == SQLITE_OK else {
            throw ThreadlineError.database("Could not close the completed migration backup")
        }
        destinationHandle = nil
        if let validationError = Self.databaseValidationError(at: temporaryPath) {
            throw ThreadlineError.database(
                "The migration backup did not pass SQLite integrity validation: \(validationError)"
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporaryPath
        )

        if fileManager.fileExists(atPath: destinationPath) {
            _ = try fileManager.replaceItemAt(
                URL(fileURLWithPath: destinationPath),
                withItemAt: URL(fileURLWithPath: temporaryPath),
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(atPath: temporaryPath, toPath: destinationPath)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destinationPath
        )
    }

    private static func databaseValidationError(at path: String) -> String? {
        var inspectionHandle: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &inspectionHandle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let inspectionHandle else {
            if let inspectionHandle { sqlite3_close(inspectionHandle) }
            return "could not open the snapshot"
        }
        defer { sqlite3_close(inspectionHandle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(inspectionHandle, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return "could not prepare quick_check: \(String(cString: sqlite3_errmsg(inspectionHandle)))"
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return "quick_check returned no result" }
        let quickCheck = String(cString: value)
        guard quickCheck == "ok" else { return quickCheck }

        var schemaStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            inspectionHandle,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('schema_migrations', 'conversations')",
            -1,
            &schemaStatement,
            nil
        ) == SQLITE_OK, let schemaStatement else { return "could not inspect the application schema" }
        defer { sqlite3_finalize(schemaStatement) }
        guard sqlite3_step(schemaStatement) == SQLITE_ROW,
              sqlite3_column_int64(schemaStatement, 0) == 2 else {
            return "the snapshot does not contain the Threadline schema"
        }
        return nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw ThreadlineError.database("The database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw databaseError(prefix: "Could not prepare SQLite statement")
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
                }
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else {
                throw databaseError(prefix: "Could not bind SQLite value")
            }
        }
    }

    private func columnValue(_ statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    private func databaseError(prefix: String) -> ThreadlineError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return .database("\(prefix): \(message)")
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteValue {
    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var int64: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var double: Double? {
        switch self {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    var data: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }
}
