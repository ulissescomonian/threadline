import Foundation
import XCTest
@testable import ConversationCore

final class SQLitePrimitivesTests: XCTestCase {
    func testCachedStatementsClearBindingsAndRecoverAfterErrorsAndSchemaChanges() throws {
        let database = try SQLiteConnection(path: ":memory:")
        try database.execute("CREATE TABLE sample(value TEXT UNIQUE)")
        try database.execute("INSERT INTO sample VALUES(?)", bindings: [.text("first")])
        XCTAssertThrowsError(try database.execute("INSERT INTO sample VALUES(?)", bindings: [.text("first")]))
        try database.execute("INSERT INTO sample VALUES(?)", bindings: [.text("second")])
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM sample"), 2)
        XCTAssertEqual(try database.rows("SELECT ?", bindings: [.text("private synthetic text")]).first?.first?.string, "private synthetic text")
        XCTAssertNil(try database.rows("SELECT ?").first?.first?.string)
        try database.execute("ALTER TABLE sample ADD COLUMN extra INTEGER")
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM sample"), 2)
        let preparedBefore = database.preparedStatementCount
        for _ in 0..<20 { _ = try database.scalarInt("SELECT COUNT(*) FROM sample") }
        XCTAssertEqual(database.preparedStatementCount, preparedBefore)
        for index in 0..<200 { try database.execute("SELECT \(index)") }
        XCTAssertLessThanOrEqual(database.cachedStatementCount, 128)
    }

    func testCanonicalHexMatchesExistingEncodingForEveryByte() {
        let bytes = (0...255).map(UInt8.init)
        XCTAssertEqual(
            HexEncoding.lowercaseString(bytes),
            bytes.map { String(format: "%02x", $0) }.joined()
        )
    }
}
