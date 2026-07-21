import Foundation
import XCTest
@testable import ConversationCore

@MainActor
final class SQLiteConversationStoreTests: XCTestCase {
    func testIncompleteHistoricalProviderCursorRevisionsAreIgnored() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        let inspection = try SQLiteConnection(
            path: fixture.directory.appendingPathComponent("library.sqlite").path
        )
        try inspection.execute(
            "INSERT INTO store_metadata(key, text_value) VALUES(?, ?)",
            bindings: [
                .text("threadline.cursor.v1.provider.codex"),
                .text(#"{"provider":"codex","completedThrough":4000000000}"#),
            ]
        )
        try inspection.execute(
            "INSERT INTO store_metadata(key, text_value) VALUES(?, ?)",
            bindings: [
                .text("threadline.ingest-cursor.v2.provider.codex"),
                .text(#"{"provider":"codex","completedThrough":4000000000}"#),
            ]
        )
        try inspection.execute(
            "INSERT INTO store_metadata(key, text_value) VALUES(?, ?)",
            bindings: [
                .text("threadline.ingest-cursor.v3.provider.codex"),
                .text(#"{"provider":"codex","completedThrough":4000000000}"#),
            ]
        )
        try inspection.execute(
            "INSERT INTO store_metadata(key, text_value) VALUES(?, ?)",
            bindings: [
                .text("threadline.ingest-cursor.v4.provider.codex"),
                .text(#"{"provider":"codex","completedThrough":4000000000}"#),
            ]
        )

        let ignoredLegacyCursor = try await fixture.store.loadProviderIngestCursor(provider: .codex)
        XCTAssertNil(ignoredLegacyCursor)

        let completeReconciliation = Date(timeIntervalSince1970: 70_007)
        try await fixture.store.saveProviderIngestCursor(completeReconciliation, provider: .codex)
        let persistedReconciliation = try await fixture.store.loadProviderIngestCursor(provider: .codex)
        XCTAssertEqual(persistedReconciliation, completeReconciliation)
    }

    func testCursorStateIsAbsentForNewDatabaseAndIsolatedByProviderAndTransport() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        let absentCodex = try await fixture.store.loadProviderIngestCursor(provider: .codex)
        let absentClaude = try await fixture.store.loadProviderIngestCursor(provider: .claude)
        let absentCloud = try await fixture.store.loadSyncCursor(transportIdentifier: "cloudkit")
        XCTAssertNil(absentCodex)
        XCTAssertNil(absentClaude)
        XCTAssertEqual(absentCloud, SyncCursor())

        let codexDate = Date(timeIntervalSince1970: 10_001)
        let claudeDate = Date(timeIntervalSince1970: 20_002)
        try await fixture.store.saveProviderIngestCursor(codexDate, provider: .codex)
        try await fixture.store.saveProviderIngestCursor(claudeDate, provider: .claude)

        let cloudCursor = SyncCursor(
            token: Data([0x01, 0x02, 0x03, 0x04]),
            updatedAt: Date(timeIntervalSince1970: 30_003)
        )
        let peerCursor = SyncCursor(
            token: Data([0xaa, 0xbb]),
            updatedAt: Date(timeIntervalSince1970: 40_004)
        )
        try await fixture.store.saveSyncCursor(cloudCursor, transportIdentifier: "cloudkit")
        try await fixture.store.saveSyncCursor(peerCursor, transportIdentifier: "peer-to-peer")

        let loadedCodex = try await fixture.store.loadProviderIngestCursor(provider: .codex)
        let loadedClaude = try await fixture.store.loadProviderIngestCursor(provider: .claude)
        let loadedCloud = try await fixture.store.loadSyncCursor(transportIdentifier: "cloudkit")
        let loadedPeer = try await fixture.store.loadSyncCursor(transportIdentifier: "peer-to-peer")
        XCTAssertEqual(loadedCodex, codexDate)
        XCTAssertEqual(loadedClaude, claudeDate)
        XCTAssertEqual(loadedCloud, cloudCursor)
        XCTAssertEqual(loadedPeer, peerCursor)

        let inspection = try SQLiteConnection(
            path: fixture.directory.appendingPathComponent("library.sqlite").path
        )
        let syncJSON = try XCTUnwrap(inspection.rows(
            "SELECT text_value FROM store_metadata WHERE key LIKE 'threadline.cursor.v1.transport.%' AND text_value LIKE '%cloudkit%'"
        ).first?.first?.string)
        XCTAssertTrue(syncJSON.contains(Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString()))
    }

    func testCursorStateSurvivesIdempotentMigrationAndDatabaseReopen() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        let providerDate = Date(timeIntervalSince1970: 50_005)
        let syncCursor = SyncCursor(
            token: Data("opaque-change-token".utf8),
            updatedAt: Date(timeIntervalSince1970: 60_006)
        )
        try await fixture.store.saveProviderIngestCursor(providerDate, provider: .codex)
        try await fixture.store.saveSyncCursor(syncCursor, transportIdentifier: "cloudkit")
        try await fixture.store.migrate()

        let reopened = try SQLiteConversationStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite"),
            deviceID: "mini",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await reopened.migrate()

        let reopenedCodex = try await reopened.loadProviderIngestCursor(provider: .codex)
        let reopenedClaude = try await reopened.loadProviderIngestCursor(provider: .claude)
        let reopenedCloud = try await reopened.loadSyncCursor(transportIdentifier: "cloudkit")
        let reopenedOther = try await reopened.loadSyncCursor(transportIdentifier: "another-transport")
        XCTAssertEqual(reopenedCodex, providerDate)
        XCTAssertNil(reopenedClaude)
        XCTAssertEqual(reopenedCloud, syncCursor)
        XCTAssertEqual(reopenedOther, SyncCursor())
    }

    func testCursorStateRejectsInvalidDatesIdentifiersAndOversizedTokens() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        await XCTAssertThrowsErrorAsync {
            try await fixture.store.saveProviderIngestCursor(
                Date(timeIntervalSince1970: .infinity),
                provider: .codex
            )
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.store.saveSyncCursor(
                SyncCursor(updatedAt: Date(timeIntervalSince1970: .nan)),
                transportIdentifier: "cloudkit"
            )
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.store.saveSyncCursor(
                SyncCursor(
                    token: Data(repeating: 0x41, count: SyncEnvelopeLimits.maximumCursorBytes + 1),
                    updatedAt: Date()
                ),
                transportIdentifier: "cloudkit"
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.loadSyncCursor(transportIdentifier: "")
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.store.loadSyncCursor(
                transportIdentifier: String(
                    repeating: "x",
                    count: SyncEnvelopeLimits.maximumIdentifierBytes + 1
                )
            )
        }
    }

    func testMigrationIsIdempotentAndStoreSupportsLibraryOperations() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()
        try await fixture.store.migrate()

        try await fixture.store.upsert(Self.conversation())
        var summaries = try await fixture.store.listConversations(query: nil, provider: nil, favoritesOnly: false)
        XCTAssertEqual(summaries.map(\.id), ["conversation-1"])
        XCTAssertEqual(summaries[0].syncAvailability, .queued)
        XCTAssertEqual(summaries[0].project?.displayName, "Threadline")

        let loadedDetail = try await fixture.store.conversation(id: "conversation-1")
        let detail = try XCTUnwrap(loadedDetail)
        XCTAssertEqual(detail.events.map(\.text), ["Find the migration", "Needle appears in the SQLite migration"])
        XCTAssertEqual(detail.events[1].metadata["command"], "swift test")
        XCTAssertNil(detail.events[1].rawPayload)

        let matching = try await fixture.store.listConversations(query: "needle sqlite", provider: nil, favoritesOnly: false)
        let missing = try await fixture.store.listConversations(query: "missing", provider: nil, favoritesOnly: false)
        let claude = try await fixture.store.listConversations(query: nil, provider: .claude, favoritesOnly: false)
        XCTAssertEqual(matching.count, 1)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertTrue(claude.isEmpty)

        try await fixture.store.setFavorite(true, conversationID: "conversation-1")
        try await fixture.store.setNotes("Important local note", conversationID: "conversation-1")
        summaries = try await fixture.store.listConversations(query: nil, provider: nil, favoritesOnly: true)
        XCTAssertEqual(summaries.count, 1)
        let noteMatches = try await fixture.store.listConversations(query: "important", provider: nil, favoritesOnly: false)
        XCTAssertEqual(noteMatches.count, 1)
        let loadedUpdated = try await fixture.store.conversation(id: "conversation-1")
        let updated = try XCTUnwrap(loadedUpdated)
        XCTAssertTrue(updated.summary.isFavorite)
        XCTAssertEqual(updated.notes, "Important local note")

        let outbox = try await fixture.store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox[0].originDeviceID, "mini")
        try await fixture.store.markEnvelopesAcknowledged(ids: [outbox[0].id])
        let acknowledgedOutbox = try await fixture.store.pendingEnvelopes(limit: 10)
        XCTAssertTrue(acknowledgedOutbox.isEmpty)

        let health = try await fixture.store.healthSnapshot()
        XCTAssertEqual(health.indexedConversationCount, 1)
        XCTAssertEqual(health.pendingObjectCount, 0)
        XCTAssertNotNil(health.lastIngestAt)
        XCTAssertNotNil(health.lastSyncAt)
        XCTAssertTrue(health.codexAvailable)
        XCTAssertFalse(health.claudeAvailable)
        XCTAssertTrue(health.issues.isEmpty)
    }

    func testRepeatedFingerprintDoesNotCreateDuplicateOutboxWork() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()
        let conversation = Self.conversation()

        try await fixture.store.upsert(conversation)
        try await fixture.store.upsert(conversation)

        let outbox = try await fixture.store.pendingEnvelopes(limit: 100)
        let loaded = try await fixture.store.conversation(id: conversation.summary.id)
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(loaded?.events.count, 2)
    }

    func testSourceSchemaRevisionRewritesSameFingerprintWhileIdenticalSourceIsNoop() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        try await fixture.store.upsert(Self.conversation(
            fingerprint: "stable-fingerprint",
            sourceSchemaVersion: "provider-v1",
            secondEventText: "Original normalized event"
        ))
        let firstPendingValues = try await fixture.store.pendingEnvelopes(limit: 10)
        let firstPending = try XCTUnwrap(firstPendingValues.first)

        try await fixture.store.upsert(Self.conversation(
            fingerprint: "stable-fingerprint",
            sourceSchemaVersion: "provider-v1",
            secondEventText: "Must be ignored while source identity is unchanged"
        ))
        let unchangedDetail = try await fixture.store.conversation(id: "conversation-1")
        var detail = try XCTUnwrap(unchangedDetail)
        var pending = try await fixture.store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(detail.events[1].text, "Original normalized event")
        XCTAssertEqual(pending.map(\.id), [firstPending.id])

        try await fixture.store.upsert(Self.conversation(
            fingerprint: "stable-fingerprint",
            sourceSchemaVersion: "provider-v2",
            secondEventText: "Rewritten by the safer adapter schema"
        ))
        let rewrittenDetail = try await fixture.store.conversation(id: "conversation-1")
        detail = try XCTUnwrap(rewrittenDetail)
        pending = try await fixture.store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(detail.events[1].text, "Rewritten by the safer adapter schema")
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotEqual(pending[0].id, firstPending.id)
        let rewritten = try PlaintextEnvelopeCodec().open(pending[0])
        XCTAssertEqual(rewritten.sourceFingerprint, "stable-fingerprint")
        XCTAssertEqual(rewritten.sourceSchemaVersion, "provider-v2")
    }

    func testLocalOnlyModeDropsOutboxAndRawPayloadThenCloudModePromotesCompleteSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadlineQueueModeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")

        do {
            let syncStore = try SQLiteConversationStore(
                databaseURL: databaseURL,
                deviceID: "mini",
                envelopeCodec: PlaintextEnvelopeCodec()
            )
            try await syncStore.migrate()
            try await syncStore.upsert(Self.conversation())
            try await syncStore.setFavorite(true, conversationID: "conversation-1")
            try await syncStore.setNotes("Preserved local note", conversationID: "conversation-1")
            let initialPending = try await syncStore.pendingEnvelopes(limit: 10)
            XCTAssertEqual(initialPending.count, 1)
        }

        let legacyInspection = try SQLiteConnection(path: databaseURL.path)
        try legacyInspection.execute("UPDATE events SET raw_payload = X'CAFE'")
        try legacyInspection.execute("DELETE FROM schema_migrations WHERE version = 4")
        try legacyInspection.execute(
            """
            INSERT INTO sync_quarantine(
              envelope_id, object_type, logical_version, origin_device_id, created_at,
              encrypted_payload, payload_hash, payload_byte_count, payload_omitted,
              error_message, first_seen_at, last_seen_at, attempt_count
            ) VALUES(
              'local-mode-quarantine', 'conversation', 2, 'remote', 100,
              X'CAFE', 'invalid', 2, 0, 'existing cloud quarantine', 100, 100, 7
            )
            """
        )

        do {
            let localStore = try SQLiteConversationStore(
                databaseURL: databaseURL,
                deviceID: "mini",
                envelopeCodec: RejectingSealCodec(),
                queuesForSync: false
            )
            try await localStore.migrate()
            try await localStore.upsert(Self.conversation(
                title: "Updated without envelope work",
                fingerprint: "local-only-v2",
                sourceSchemaVersion: "test-v2"
            ))
            let localPending = try await localStore.pendingEnvelopes(limit: 10)
            XCTAssertTrue(localPending.isEmpty)
            let localDetailValue = try await localStore.conversation(id: "conversation-1")
            let localDetail = try XCTUnwrap(localDetailValue)
            XCTAssertEqual(localDetail.summary.syncAvailability, .localOnly)
            XCTAssertTrue(localDetail.summary.isFavorite)
            XCTAssertEqual(localDetail.notes, "Preserved local note")
            XCTAssertTrue(localDetail.events.allSatisfy { $0.rawPayload == nil })
        }

        XCTAssertEqual(try legacyInspection.scalarInt("SELECT COUNT(*) FROM sync_outbox"), 0)
        XCTAssertEqual(
            try legacyInspection.scalarInt(
                "SELECT attempt_count FROM sync_quarantine WHERE envelope_id = 'local-mode-quarantine'"
            ),
            7,
            "Local-only migration must not open or retry cloud quarantine with its ephemeral codec key"
        )
        XCTAssertEqual(
            try legacyInspection.scalarInt("SELECT COUNT(*) FROM events WHERE raw_payload IS NOT NULL"),
            0
        )
        try legacyInspection.execute(
            "DELETE FROM sync_quarantine WHERE envelope_id = 'local-mode-quarantine'"
        )

        let cloudStore = try SQLiteConversationStore(
            databaseURL: databaseURL,
            deviceID: "mini",
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: true
        )
        try await cloudStore.migrate()
        try await cloudStore.migrate()

        let promotedValues = try await cloudStore.pendingEnvelopes(limit: 10)
        let promoted = try XCTUnwrap(promotedValues.first)
        XCTAssertEqual(promotedValues.count, 1)
        let snapshot = try PlaintextEnvelopeCodec().open(promoted)
        XCTAssertTrue(snapshot.summary.isFavorite)
        XCTAssertEqual(snapshot.events.map(\.id), ["event-1", "event-2"])
        XCTAssertTrue(snapshot.events.allSatisfy { $0.rawPayload == nil })

        let promotedDetailValue = try await cloudStore.conversation(id: "conversation-1")
        let promotedDetail = try XCTUnwrap(promotedDetailValue)
        XCTAssertEqual(promotedDetail.summary.syncAvailability, .queued)
        XCTAssertEqual(promotedDetail.notes, "Preserved local note")
    }

    func testMigrationCreatesFilterOrderingIndexes() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()
        let inspection = try SQLiteConnection(
            path: fixture.directory.appendingPathComponent("library.sqlite").path
        )

        let names = Set(try inspection.rows(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'conversations_%_updated_at_id'"
        ).compactMap { $0.first?.string })
        XCTAssertEqual(names, [
            "conversations_provider_updated_at_id",
            "conversations_favorite_updated_at_id",
            "conversations_provider_favorite_updated_at_id",
        ])

        let queryPlans: [(sql: String, expectedIndex: String)] = [
            (
                "EXPLAIN QUERY PLAN SELECT id FROM conversations WHERE provider = 'codex' ORDER BY updated_at DESC, id ASC",
                "conversations_provider_updated_at_id"
            ),
            (
                "EXPLAIN QUERY PLAN SELECT id FROM conversations WHERE is_favorite = 1 ORDER BY updated_at DESC, id ASC",
                "conversations_favorite_updated_at_id"
            ),
            (
                "EXPLAIN QUERY PLAN SELECT id FROM conversations WHERE provider = 'codex' AND is_favorite = 1 ORDER BY updated_at DESC, id ASC",
                "conversations_provider_favorite_updated_at_id"
            ),
        ]
        for queryPlan in queryPlans {
            let details = try inspection.rows(queryPlan.sql).compactMap { row in
                row.count > 3 ? row[3].string : nil
            }
            XCTAssertTrue(
                details.contains { $0.contains(queryPlan.expectedIndex) },
                "Expected SQLite to use \(queryPlan.expectedIndex); plan was \(details)"
            )
        }
    }

    func testHealthSnapshotCachesIntegrityCheckButKeepsLightweightCountsFresh() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        let emptyHealth = try await fixture.store.healthSnapshot()
        XCTAssertEqual(emptyHealth.indexedConversationCount, 0)
        let firstIntegrityCheckCount = await fixture.store.integrityCheckExecutionCount
        XCTAssertEqual(firstIntegrityCheckCount, 1)

        try await fixture.store.upsert(Self.conversation())
        let populatedHealth = try await fixture.store.healthSnapshot()
        XCTAssertEqual(populatedHealth.indexedConversationCount, 1)
        XCTAssertEqual(populatedHealth.pendingObjectCount, 1)
        let secondIntegrityCheckCount = await fixture.store.integrityCheckExecutionCount
        XCTAssertEqual(secondIntegrityCheckCount, 1)
    }

    func testChangedFingerprintReplacesOlderPendingSnapshot() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        try await fixture.store.upsert(Self.conversation(
            title: "First pending snapshot",
            fingerprint: "fingerprint-v1"
        ))
        let initialPendingValues = try await fixture.store.pendingEnvelopes(limit: 10)
        let initialPending = try XCTUnwrap(initialPendingValues.first)

        try await fixture.store.upsert(Self.conversation(
            title: "Latest pending snapshot",
            updatedAt: Date(timeIntervalSince1970: 1_200),
            fingerprint: "fingerprint-v2"
        ))

        let pending = try await fixture.store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotEqual(pending[0].id, initialPending.id)
        let latest = try PlaintextEnvelopeCodec().open(pending[0])
        XCTAssertEqual(latest.sourceFingerprint, "fingerprint-v2")
        XCTAssertEqual(latest.summary.title, "Latest pending snapshot")

        let health = try await fixture.store.healthSnapshot()
        XCTAssertEqual(health.pendingObjectCount, 1)
        XCTAssertEqual(health.pendingByteCount, Int64(pending[0].encryptedPayload.count))
    }

    func testMigrationCoalescesLegacyPendingSnapshotsAndPreservesAcknowledgedHistory() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        let databasePath = fixture.directory.appendingPathComponent("library.sqlite").path

        do {
            let legacy = try SQLiteConnection(path: databasePath)
            try legacy.execute(
                """
                CREATE TABLE sync_outbox (
                    id TEXT PRIMARY KEY,
                    object_id TEXT NOT NULL,
                    object_type TEXT NOT NULL,
                    logical_version INTEGER NOT NULL,
                    origin_device_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    encrypted_payload BLOB NOT NULL,
                    payload_hash TEXT NOT NULL,
                    acknowledged_at REAL
                )
                """
            )
            try legacy.execute(
                """
                INSERT INTO sync_outbox(
                  id, object_id, object_type, logical_version, origin_device_id,
                  created_at, encrypted_payload, payload_hash, acknowledged_at
                ) VALUES
                  ('pending-old', 'conversation-1', 'conversation', 1, 'mini', 100, X'01', 'old', NULL),
                  ('pending-latest', 'conversation-1', 'conversation', 1, 'mini', 200, X'02', 'latest', NULL),
                  ('acknowledged', 'conversation-1', 'conversation', 1, 'mini', 50, X'03', 'ack', 75),
                  ('other-object', 'conversation-2', 'conversation', 1, 'mini', 150, X'04', 'other', NULL)
                """
            )
        }

        try await fixture.store.migrate()
        try await fixture.store.migrate()

        let pending = try await fixture.store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(Set(pending.map(\.id)), ["pending-latest", "other-object"])

        let inspection = try SQLiteConnection(path: databasePath)
        XCTAssertEqual(
            try inspection.scalarInt(
                "SELECT COUNT(*) FROM sync_outbox WHERE id = 'acknowledged' AND acknowledged_at = 75"
            ),
            1
        )
        XCTAssertEqual(
            try inspection.scalarInt("SELECT COUNT(*) FROM schema_migrations WHERE version = 3"),
            1
        )
        XCTAssertEqual(
            try inspection.scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'sync_outbox_one_pending_per_object'"
            ),
            1
        )

        XCTAssertThrowsError(try inspection.execute(
            """
            INSERT INTO sync_outbox(
              id, object_id, object_type, logical_version, origin_device_id,
              created_at, encrypted_payload, payload_hash, acknowledged_at
            ) VALUES('duplicate-pending', 'conversation-1', 'conversation', 1, 'mini', 300, X'05', 'duplicate', NULL)
            """
        ))
    }

    func testVersion5MigrationBacksUpRepairsAvailabilityAndRebuildsFTSByStableRowID() async throws {
        let fixture = try StoreFixture(deviceID: "book")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()
        try await fixture.store.upsert(Self.conversation(
            title: "Preserved before migration",
            originDeviceID: "book"
        ))
        try await fixture.store.setNotes("Migration backup marker", conversationID: "conversation-1")

        let databasePath = fixture.directory.appendingPathComponent("library.sqlite").path
        let backupPath = databasePath + SQLiteConversationStore.preVersion5BackupSuffix
        let legacyInspection = try SQLiteConnection(path: databasePath)
        let eventCountBefore = try legacyInspection.scalarInt("SELECT COUNT(*) FROM events")
        let payloadCountBefore = try legacyInspection.scalarInt("SELECT COUNT(*) FROM sync_outbox")
        try legacyInspection.transaction {
            try legacyInspection.execute("DELETE FROM schema_migrations WHERE version = 5")
            try legacyInspection.execute("DROP TABLE conversation_fts_map")
            try legacyInspection.execute(
                "UPDATE conversations SET sync_availability = 'availableOffline' WHERE id = 'conversation-1'"
            )
        }

        let migratingStore = try SQLiteConversationStore(
            databasePath: databasePath,
            deviceID: "book",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await migratingStore.migrate()

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        XCTAssertEqual(try permissionBits(at: backupPath), 0o600)
        let backupInspection = try SQLiteConnection(path: backupPath)
        XCTAssertEqual(
            try backupInspection.scalarInt("SELECT COUNT(*) FROM schema_migrations WHERE version = 5"),
            0
        )
        XCTAssertEqual(
            try backupInspection.rows(
                "SELECT sync_availability FROM conversations WHERE id = 'conversation-1'"
            ).first?.first?.string,
            "availableOffline"
        )

        let migratedInspection = try SQLiteConnection(path: databasePath)
        XCTAssertEqual(
            try migratedInspection.scalarInt("SELECT COUNT(*) FROM schema_migrations WHERE version = 5"),
            1
        )
        XCTAssertEqual(try migratedInspection.scalarInt("SELECT COUNT(*) FROM events"), eventCountBefore)
        XCTAssertEqual(try migratedInspection.scalarInt("SELECT COUNT(*) FROM sync_outbox"), payloadCountBefore)
        XCTAssertEqual(
            try migratedInspection.rows(
                "SELECT sync_availability FROM conversations WHERE id = 'conversation-1'"
            ).first?.first?.string,
            SyncAvailability.queued.rawValue
        )

        let mapping = try XCTUnwrap(migratedInspection.rows(
            "SELECT fts_rowid FROM conversation_fts_map WHERE conversation_id = 'conversation-1'"
        ).first?.first?.int64)
        XCTAssertEqual(
            try migratedInspection.rows(
                "SELECT rowid FROM conversation_fts WHERE conversation_id = 'conversation-1'"
            ).first?.first?.int64,
            mapping
        )
        let matches = try await migratingStore.listConversations(
            query: "migration backup marker",
            provider: nil,
            favoritesOnly: false
        )
        XCTAssertEqual(matches.map(\.id), ["conversation-1"])

        let deletePlan = try migratedInspection.rows(
            """
            EXPLAIN QUERY PLAN
            DELETE FROM conversation_fts
            WHERE rowid = (
              SELECT fts_rowid FROM conversation_fts_map WHERE conversation_id = 'conversation-1'
            )
            """
        ).compactMap { $0.count > 3 ? $0[3].string : nil }.joined(separator: " | ")
        XCTAssertTrue(
            deletePlan.contains("conversation_fts VIRTUAL TABLE INDEX 0:="),
            "FTS5 reports rowid equality as virtual-table index 0:=. Plan: \(deletePlan)"
        )
        XCTAssertTrue(deletePlan.contains("SEARCH conversation_fts_map USING INDEX"), deletePlan)

        try await migratingStore.setNotes("Updated through stable rowid", conversationID: "conversation-1")
        XCTAssertEqual(
            try migratedInspection.rows(
                "SELECT fts_rowid FROM conversation_fts_map WHERE conversation_id = 'conversation-1'"
            ).first?.first?.int64,
            mapping
        )
        XCTAssertEqual(
            try migratedInspection.rows(
                "SELECT rowid FROM conversation_fts WHERE conversation_id = 'conversation-1'"
            ).first?.first?.int64,
            mapping
        )

        let originalBackup = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        try migratedInspection.transaction {
            try migratedInspection.execute("DELETE FROM schema_migrations WHERE version = 5")
            try migratedInspection.execute("DROP TABLE conversation_fts_map")
        }
        try await migratingStore.migrate()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backupPath)), originalBackup)
    }

    func testVersion5MigrationDoesNotBackUpNewOrInMemoryDatabase() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()
        let backupPath = fixture.directory.appendingPathComponent("library.sqlite").path
            + SQLiteConversationStore.preVersion5BackupSuffix
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath))

        let memoryStore = try SQLiteConversationStore(
            databasePath: ":memory:",
            deviceID: "mini",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await memoryStore.migrate()
    }

    func testDuplicateProviderEventIDsArePersistedLosslesslyAndIdempotently() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        let base = Self.conversation(fingerprint: "duplicates-v1")
        let duplicateEvents = [
            ConversationEvent(
                id: "provider-event",
                conversationID: base.summary.id,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_010),
                kind: .assistantMessage,
                role: .assistant,
                text: "First occurrence",
                contentHash: "shared-source-hash",
                sourceDeviceID: "mini"
            ),
            ConversationEvent(
                id: "provider-event",
                conversationID: base.summary.id,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_010),
                kind: .assistantMessage,
                role: .assistant,
                text: "Second occurrence",
                contentHash: "shared-source-hash",
                sourceDeviceID: "mini"
            ),
        ]
        let firstImport = ProviderConversation(
            summary: base.summary,
            events: duplicateEvents,
            sourceFingerprint: "duplicates-v1",
            sourceSchemaVersion: base.sourceSchemaVersion
        )
        try await fixture.store.upsert(firstImport)

        let initiallyLoadedValue = try await fixture.store.conversation(id: base.summary.id)
        let initiallyLoaded = try XCTUnwrap(initiallyLoadedValue)
        let initialIDs = initiallyLoaded.events.map(\.id).sorted()
        XCTAssertEqual(initiallyLoaded.events.count, 2)
        XCTAssertEqual(Set(initialIDs).count, 2)
        XCTAssertEqual(
            Set(initiallyLoaded.events.compactMap { $0.metadata["_threadlineSourceEventID"] }),
            ["provider-event"]
        )

        let repeatedImport = ProviderConversation(
            summary: base.summary,
            events: duplicateEvents,
            sourceFingerprint: "duplicates-v2",
            sourceSchemaVersion: base.sourceSchemaVersion
        )
        try await fixture.store.upsert(repeatedImport)

        let reloadedValue = try await fixture.store.conversation(id: base.summary.id)
        let reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloaded.events.map(\.id).sorted(), initialIDs)
        XCTAssertEqual(Set(reloaded.events.map(\.text)), ["First occurrence", "Second occurrence"])
    }

    func testProviderEventIDsMayRepeatAcrossConversations() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        let first = Self.conversation(
            conversationID: "conversation-1",
            providerSessionID: "provider-session-1",
            fingerprint: "first"
        )
        let second = Self.conversation(
            conversationID: "conversation-2",
            providerSessionID: "provider-session-2",
            fingerprint: "second"
        )
        try await fixture.store.upsert(first)
        try await fixture.store.upsert(second)

        let firstLoadedValue = try await fixture.store.conversation(id: first.summary.id)
        let secondLoadedValue = try await fixture.store.conversation(id: second.summary.id)
        let firstLoaded = try XCTUnwrap(firstLoadedValue)
        let secondLoaded = try XCTUnwrap(secondLoadedValue)
        XCTAssertEqual(firstLoaded.events.count, 2)
        XCTAssertEqual(secondLoaded.events.count, 2)
        XCTAssertTrue(Set(firstLoaded.events.map(\.id)).isDisjoint(with: secondLoaded.events.map(\.id)))
        XCTAssertEqual(
            Set(secondLoaded.events.compactMap { $0.metadata["_threadlineSourceEventID"] }),
            ["event-1", "event-2"]
        )
    }

    func testRemoteApplicationIsIdempotentAndDoesNotEcho() async throws {
        let source = try StoreFixture(deviceID: "mini")
        let destination = try StoreFixture(deviceID: "book")
        defer { source.cleanup(); destination.cleanup() }
        try await source.store.migrate()
        try await destination.store.migrate()

        try await source.store.upsert(Self.conversation())
        let envelopes = try await source.store.pendingEnvelopes(limit: 10)
        try await destination.store.applyRemote(envelopes)
        try await destination.store.applyRemote(envelopes)

        let loadedImported = try await destination.store.conversation(id: "conversation-1")
        let imported = try XCTUnwrap(loadedImported)
        XCTAssertEqual(imported.events.count, 2)
        XCTAssertTrue(imported.events.allSatisfy { $0.rawPayload == nil })
        XCTAssertEqual(imported.summary.syncAvailability, .availableOffline)
        let destinationOutbox = try await destination.store.pendingEnvelopes(limit: 10)
        let destinationHealth = try await destination.store.healthSnapshot()
        XCTAssertTrue(destinationOutbox.isEmpty)
        XCTAssertNotNil(destinationHealth.lastSyncAt)
    }

    func testIdenticalRemoteSourcePreservesQueuedConversationOutboxOriginAndEvents() async throws {
        let local = try StoreFixture(deviceID: "book")
        defer { local.cleanup() }
        try await local.store.migrate()

        let original = Self.conversation(
            title: "Local queued snapshot",
            fingerprint: "identical-source",
            originDeviceID: "book",
            sourceSchemaVersion: "adapter-v1",
            secondEventText: "Original normalized event"
        )
        try await local.store.upsert(original)
        let pendingBefore = try await local.store.pendingEnvelopes(limit: 10)
        let envelopeID = try XCTUnwrap(pendingBefore.first?.id)

        let replay = Self.conversation(
            title: "Must not replace local state",
            updatedAt: Date(timeIntervalSince1970: 9_000),
            fingerprint: "identical-source",
            originDeviceID: "mini",
            sourceSchemaVersion: "adapter-v1",
            secondEventText: "Must not rewrite the normalized event"
        )
        let remoteEnvelope = try PlaintextEnvelopeCodec().seal(
            replay,
            originDeviceID: "mini",
            createdAt: Date(timeIntervalSince1970: 9_001)
        )
        try await local.store.applyRemote([remoteEnvelope])

        let loadedValue = try await local.store.conversation(id: original.summary.id)
        let loaded = try XCTUnwrap(loadedValue)
        let pendingAfter = try await local.store.pendingEnvelopes(limit: 10)
        XCTAssertEqual(loaded.summary.title, "Local queued snapshot")
        XCTAssertEqual(loaded.summary.syncAvailability, .queued)
        XCTAssertEqual(loaded.summary.originDeviceID, "book")
        XCTAssertEqual(loaded.events[1].text, "Original normalized event")
        XCTAssertEqual(pendingAfter.map(\.id), [envelopeID])
    }

    func testRemoteSourceSchemaRevisionWithSameFingerprintIsApplied() async throws {
        let destination = try StoreFixture(deviceID: "book")
        defer { destination.cleanup() }
        try await destination.store.migrate()
        let codec = PlaintextEnvelopeCodec()

        let original = Self.conversation(
            title: "Adapter v1",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            fingerprint: "stable-provider-bytes",
            originDeviceID: "mini",
            sourceSchemaVersion: "adapter-v1",
            secondEventText: "Old normalization"
        )
        try await destination.store.applyRemote([
            try codec.seal(original, originDeviceID: "mini", createdAt: Date(timeIntervalSince1970: 2_001))
        ])

        let revised = Self.conversation(
            title: "Adapter v2",
            updatedAt: Date(timeIntervalSince1970: 2_100),
            fingerprint: "stable-provider-bytes",
            originDeviceID: "mini",
            sourceSchemaVersion: "adapter-v2",
            secondEventText: "Safer normalization"
        )
        try await destination.store.applyRemote([
            try codec.seal(revised, originDeviceID: "mini", createdAt: Date(timeIntervalSince1970: 2_101))
        ])

        let loadedValue = try await destination.store.conversation(id: original.summary.id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.summary.title, "Adapter v2")
        XCTAssertEqual(loaded.events[1].text, "Safer normalization")
        XCTAssertEqual(loaded.summary.syncAvailability, .availableOffline)
    }

    func testRemoteDivergenceCreatesForkAndPreservesLocalContinuation() async throws {
        let local = try StoreFixture(deviceID: "book")
        let remoteCodec = PlaintextEnvelopeCodec()
        defer { local.cleanup() }
        try await local.store.migrate()

        let localConversation = Self.conversation(
            title: "Local continuation",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            fingerprint: "local-new",
            originDeviceID: "book"
        )
        try await local.store.upsert(localConversation)

        let remoteConversation = Self.conversation(
            title: "Remote continuation",
            updatedAt: Date(timeIntervalSince1970: 1_500),
            fingerprint: "remote-old"
        )
        let envelope = try remoteCodec.seal(
            remoteConversation,
            originDeviceID: "mini",
            createdAt: Date(timeIntervalSince1970: 1_501)
        )
        try await local.store.applyRemote([envelope])

        let all = try await local.store.listConversations(query: nil, provider: nil, favoritesOnly: false)
        XCTAssertEqual(all.count, 2)
        let original = try XCTUnwrap(all.first(where: { $0.id == "conversation-1" }))
        let fork = try XCTUnwrap(all.first(where: { $0.id != "conversation-1" }))
        XCTAssertEqual(original.title, "Local continuation")
        XCTAssertEqual(original.status, .divergent)
        XCTAssertTrue(fork.id.hasPrefix("conversation-1:fork:"))
        XCTAssertEqual(fork.status, .divergent)
        let forkDetail = try await local.store.conversation(id: fork.id)
        XCTAssertEqual(forkDetail?.events.count, 2)
    }

    func testRemoteDivergenceAfterTransportAcknowledgementStillCreatesFork() async throws {
        let local = try StoreFixture(deviceID: "book")
        let remoteCodec = PlaintextEnvelopeCodec()
        defer { local.cleanup() }
        try await local.store.migrate()

        try await local.store.upsert(Self.conversation(
            title: "Acknowledged local branch",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            fingerprint: "local-acknowledged",
            originDeviceID: "book"
        ))
        let pending = try await local.store.pendingEnvelopes(limit: 10)
        try await local.store.markEnvelopesAcknowledged(ids: pending.map(\.id))

        let remote = Self.conversation(
            title: "Remote branch after ACK",
            updatedAt: Date(timeIntervalSince1970: 2_500),
            fingerprint: "remote-after-ack",
            originDeviceID: "mini"
        )
        try await local.store.applyRemote([
            try remoteCodec.seal(remote, originDeviceID: "mini", createdAt: Date(timeIntervalSince1970: 2_501))
        ])

        let conversations = try await local.store.listConversations(query: nil, provider: nil, favoritesOnly: false)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations.first(where: { $0.id == "conversation-1" })?.title, "Acknowledged local branch")
        XCTAssertEqual(conversations.first(where: { $0.id != "conversation-1" })?.title, "Remote branch after ACK — Conflicting continuation")
        XCTAssertTrue(conversations.allSatisfy { $0.status == .divergent })
    }

    func testInvalidEnvelopeIsQuarantinedWithoutBlockingValidEnvelope() async throws {
        let destination = try StoreFixture(deviceID: "book")
        let codec = PlaintextEnvelopeCodec()
        defer { destination.cleanup() }
        try await destination.store.migrate()

        let validConversation = Self.conversation(originDeviceID: "mini")
        let valid = try codec.seal(validConversation, originDeviceID: "mini", createdAt: Date())
        let invalid = SyncEnvelope(
            id: "conversation:poison:bad",
            objectType: "conversation",
            logicalVersion: SyncEnvelopeLimits.legacyFormatVersion,
            originDeviceID: "mini",
            createdAt: Date(),
            encryptedPayload: Data("not-json".utf8),
            payloadHash: String(repeating: "0", count: 64)
        )

        try await destination.store.applyRemote([invalid, valid])

        let imported = try await destination.store.conversation(id: validConversation.summary.id)
        XCTAssertNotNil(imported)
        let health = try await destination.store.healthSnapshot()
        XCTAssertTrue(health.issues.contains { $0.id == "sync-quarantine" })
        XCTAssertNotNil(health.lastSyncAt)
    }

    func testQuarantinedEnvelopeIsRetriedAfterCompatibleKeyBecomesAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadlineQuarantineRetry-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let correctKey = Data(repeating: 0x41, count: 32)
        let wrongKey = Data(repeating: 0x42, count: 32)
        let envelope = try EncryptedEnvelopeCodec(keyData: correctKey).seal(
            Self.conversation(originDeviceID: "mini"),
            originDeviceID: "mini",
            createdAt: Date()
        )

        var incompatibleStore: SQLiteConversationStore? = try SQLiteConversationStore(
            databaseURL: databaseURL,
            deviceID: "book",
            envelopeCodec: EncryptedEnvelopeCodec(keyData: wrongKey)
        )
        try await incompatibleStore?.migrate()
        try await incompatibleStore?.applyRemote([envelope])
        let quarantinedHealth = try await incompatibleStore?.healthSnapshot()
        XCTAssertTrue(quarantinedHealth?.issues.contains { $0.id == "sync-quarantine" } == true)
        incompatibleStore = nil

        let compatibleStore = try SQLiteConversationStore(
            databaseURL: databaseURL,
            deviceID: "book",
            envelopeCodec: EncryptedEnvelopeCodec(keyData: correctKey)
        )
        try await compatibleStore.migrate()

        let recoveredConversation = try await compatibleStore.conversation(id: "conversation-1")
        XCTAssertNotNil(recoveredConversation)
        let recoveredHealth = try await compatibleStore.healthSnapshot()
        XCTAssertFalse(recoveredHealth.issues.contains { $0.id == "sync-quarantine" })
    }

    func testDatabaseAndJournalUsePrivatePermissions() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()
        try await fixture.store.upsert(Self.conversation())

        let directoryMode = try permissionBits(at: fixture.directory.path)
        let databaseMode = try permissionBits(at: fixture.directory.appendingPathComponent("library.sqlite").path)
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(databaseMode, 0o600)
        for suffix in ["-wal", "-shm"] {
            let path = fixture.directory.appendingPathComponent("library.sqlite\(suffix)").path
            if FileManager.default.fileExists(atPath: path) {
                XCTAssertEqual(try permissionBits(at: path), 0o600)
            }
        }
    }

    func testUnknownConversationMetadataUpdateFailsClearly() async throws {
        let fixture = try StoreFixture(deviceID: "mini")
        defer { fixture.cleanup() }
        try await fixture.store.migrate()

        do {
            try await fixture.store.setFavorite(true, conversationID: "missing")
            XCTFail("Expected a database error")
        } catch let error as ThreadlineError {
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }
    }

    private static func conversation(
        conversationID: String = "conversation-1",
        providerSessionID: String = "provider-session-1",
        title: String = "SQLite migration",
        updatedAt: Date = Date(timeIntervalSince1970: 1_100),
        fingerprint: String = "fingerprint-v1",
        originDeviceID: String = "mini",
        sourceSchemaVersion: String = "test-v1",
        secondEventText: String = "Needle appears in the SQLite migration"
    ) -> ProviderConversation {
        let project = ProjectIdentity(
            id: "project-1",
            displayName: "Threadline",
            canonicalPath: "/tmp/threadline",
            gitRemote: "git@example.com:threadline.git"
        )
        let summary = ConversationSummary(
            id: conversationID,
            provider: .codex,
            providerSessionID: providerSessionID,
            title: title,
            preview: "Database work",
            project: project,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: updatedAt,
            status: .idle,
            originDeviceID: originDeviceID,
            tags: ["database", "core"],
            messageCount: 2
        )
        let events = [
            ConversationEvent(
                id: "event-1",
                conversationID: summary.id,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_010),
                kind: .userMessage,
                role: .user,
                text: "Find the migration",
                contentHash: "hash-1",
                sourceDeviceID: "mini"
            ),
            ConversationEvent(
                id: "event-2",
                conversationID: summary.id,
                sequence: 2,
                timestamp: Date(timeIntervalSince1970: 1_020),
                kind: .assistantMessage,
                role: .assistant,
                text: secondEventText,
                metadata: ["command": "swift test"],
                rawPayload: Data([0x01, 0x02]),
                contentHash: "hash-2",
                sourceDeviceID: "mini"
            ),
        ]
        return ProviderConversation(
            summary: summary,
            events: events,
            sourceFingerprint: fingerprint,
            sourceSchemaVersion: sourceSchemaVersion
        )
    }

}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

private func permissionBits(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private struct RejectingSealCodec: SyncEnvelopeCodec {
    func seal(
        _ conversation: ProviderConversation,
        originDeviceID: String,
        createdAt: Date
    ) throws -> SyncEnvelope {
        throw ThreadlineError.encryption("Local-only mode must not seal an envelope")
    }

    func open(_ envelope: SyncEnvelope) throws -> ProviderConversation {
        try PlaintextEnvelopeCodec().open(envelope)
    }
}

private struct StoreFixture {
    let directory: URL
    let store: SQLiteConversationStore

    init(deviceID: String, queuesForSync: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadlineStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try SQLiteConversationStore(
            databaseURL: directory.appendingPathComponent("library.sqlite"),
            deviceID: deviceID,
            envelopeCodec: PlaintextEnvelopeCodec(),
            queuesForSync: queuesForSync
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
