import CryptoKit
import Foundation

public actor SQLiteConversationStore: ConversationStore {
    public nonisolated let databasePath: String
    public nonisolated let deviceID: String

    private let database: SQLiteConnection
    private let envelopeCodec: any SyncEnvelopeCodec
    private let queuesForSync: Bool
    private var cachedIntegrityCheck: (result: String, checkedAtUptime: TimeInterval)?
    internal private(set) var integrityCheckExecutionCount = 0

    public init(
        databaseURL: URL,
        deviceID: String,
        envelopeCodec: any SyncEnvelopeCodec,
        queuesForSync: Bool = true
    ) throws {
        try self.init(
            databasePath: databaseURL.path,
            deviceID: deviceID,
            envelopeCodec: envelopeCodec,
            queuesForSync: queuesForSync
        )
    }

    public init(
        databasePath: String,
        deviceID: String,
        envelopeCodec: any SyncEnvelopeCodec,
        queuesForSync: Bool = true
    ) throws {
        guard !deviceID.isEmpty else {
            throw ThreadlineError.database("A non-empty device identifier is required")
        }
        self.databasePath = databasePath
        self.deviceID = deviceID
        self.database = try SQLiteConnection(path: databasePath)
        self.envelopeCodec = envelopeCodec
        self.queuesForSync = queuesForSync
    }

    public func migrate() async throws {
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")

        let hasExistingApplicationSchema = try database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('schema_migrations', 'conversations')"
        ) > 0
        let hasFTSRowIDMigration = try database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'"
        ) > 0 && database.scalarInt(
            "SELECT COUNT(*) FROM schema_migrations WHERE version = 5"
        ) > 0
        if hasExistingApplicationSchema, !hasFTSRowIDMigration, databasePath != ":memory:" {
            try database.backupIfNeeded(to: databasePath + Self.preVersion5BackupSuffix)
        }

        let statements = [
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                canonical_path TEXT,
                git_remote TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                provider_session_id TEXT NOT NULL,
                title TEXT NOT NULL,
                preview TEXT NOT NULL,
                project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL,
                sync_availability TEXT NOT NULL,
                origin_device_id TEXT NOT NULL,
                active_owner_device_id TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                tags_json TEXT NOT NULL DEFAULT '[]',
                message_count INTEGER NOT NULL DEFAULT 0,
                notes TEXT NOT NULL DEFAULT '',
                branch_id TEXT NOT NULL DEFAULT 'main',
                parent_branch_id TEXT,
                source_fingerprint TEXT NOT NULL,
                source_schema_version TEXT NOT NULL
            )
            """,
            "CREATE UNIQUE INDEX IF NOT EXISTS conversations_provider_session ON conversations(provider, provider_session_id, id)",
            "CREATE INDEX IF NOT EXISTS conversations_updated_at ON conversations(updated_at DESC)",
            "CREATE INDEX IF NOT EXISTS conversations_provider_updated_at_id ON conversations(provider, updated_at DESC, id ASC)",
            "CREATE INDEX IF NOT EXISTS conversations_favorite_updated_at_id ON conversations(updated_at DESC, id ASC) WHERE is_favorite = 1",
            "CREATE INDEX IF NOT EXISTS conversations_provider_favorite_updated_at_id ON conversations(provider, updated_at DESC, id ASC) WHERE is_favorite = 1",
            """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                metadata_json TEXT NOT NULL,
                raw_payload BLOB,
                content_hash TEXT NOT NULL,
                source_device_id TEXT NOT NULL,
                UNIQUE(conversation_id, sequence, id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS events_conversation_sequence ON events(conversation_id, sequence, timestamp)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS conversation_fts USING fts5(
                conversation_id UNINDEXED,
                title,
                preview,
                event_text,
                notes,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sync_outbox (
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
            """,
            "CREATE INDEX IF NOT EXISTS sync_outbox_pending ON sync_outbox(acknowledged_at, created_at)",
            """
            CREATE TABLE IF NOT EXISTS sync_quarantine (
                envelope_id TEXT PRIMARY KEY,
                object_type TEXT NOT NULL,
                logical_version INTEGER NOT NULL,
                origin_device_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                encrypted_payload BLOB,
                payload_hash TEXT NOT NULL,
                payload_byte_count INTEGER NOT NULL,
                payload_omitted INTEGER NOT NULL DEFAULT 0,
                error_message TEXT NOT NULL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 1
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS store_metadata (
                key TEXT PRIMARY KEY,
                real_value REAL,
                text_value TEXT,
                blob_value BLOB
            )
            """,
        ]

        var appliedSchemaTransformation = false
        try database.transaction {
            for statement in statements { try database.execute(statement) }
            try database.execute(
                "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, ?)",
                bindings: [.real(Date().timeIntervalSince1970)]
            )
            try database.execute(
                "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, ?)",
                bindings: [.real(Date().timeIntervalSince1970)]
            )
            let hasCoalescedOutboxMigration = try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 3"
            ) > 0
            if !hasCoalescedOutboxMigration {
                try Self.compactPendingOutbox(using: database)
                try database.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES(3, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
                appliedSchemaTransformation = true
            }
            try database.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS sync_outbox_one_pending_per_object
                ON sync_outbox(object_type, object_id)
                WHERE acknowledged_at IS NULL
                """
            )
            let hasRawPayloadMinimizationMigration = try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 4"
            ) > 0
            if !hasRawPayloadMinimizationMigration {
                try database.execute("UPDATE events SET raw_payload = NULL WHERE raw_payload IS NOT NULL")
                try database.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES(4, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
                appliedSchemaTransformation = true
            }
            let hasStableFTSRowIDMigration = try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 5"
            ) > 0
            if !hasStableFTSRowIDMigration {
                try database.execute(
                    """
                    CREATE TABLE conversation_fts_map (
                        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
                        fts_rowid INTEGER NOT NULL UNIQUE
                    )
                    """
                )
                appliedSchemaTransformation = true
                try database.execute(
                    """
                    INSERT INTO conversation_fts_map(conversation_id, fts_rowid)
                    SELECT id, ROW_NUMBER() OVER (ORDER BY id)
                    FROM conversations
                    """
                )
                try database.execute("DELETE FROM conversation_fts")
                try database.execute(
                    """
                    INSERT INTO conversation_fts(rowid, conversation_id, title, preview, event_text, notes)
                    SELECT m.fts_rowid, c.id, c.title, c.preview,
                      COALESCE((
                        SELECT group_concat(e.text, char(10))
                        FROM events e WHERE e.conversation_id = c.id
                      ), ''),
                      c.notes
                    FROM conversations c
                    JOIN conversation_fts_map m ON m.conversation_id = c.id
                    ORDER BY m.fts_rowid
                    """
                )
                try database.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES(5, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
            let hasAcknowledgedOutboxCompactionMigration = try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 6"
            ) > 0
            if !hasAcknowledgedOutboxCompactionMigration {
                // An acknowledged envelope is never read by the delivery path.
                // Retain its identity, version, hash and acknowledgement time for
                // diagnostics, while releasing the duplicate encrypted snapshot.
                // Republish, if ever required, is derived from the authoritative
                // local conversation rather than this delivery receipt.
                try database.execute(
                    "UPDATE sync_outbox SET encrypted_payload = X'' WHERE acknowledged_at IS NOT NULL AND length(encrypted_payload) > 0"
                )
                appliedSchemaTransformation = true
                try database.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES(6, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
            }
            let hasIncrementalEventFTSMigration = try database.scalarInt(
                "SELECT COUNT(*) FROM schema_migrations WHERE version = 7"
            ) > 0
            if !hasIncrementalEventFTSMigration {
                // Keep the existing aggregate index intact. Rebuilding hundreds
                // of thousands of historical events during launch would create
                // the very CPU and I/O spike this migration is meant to avoid.
                // New append-only events enter this small delta index instead.
                try database.execute(
                    """
                    CREATE TABLE IF NOT EXISTS conversation_fts_event_map (
                        event_id TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
                        fts_rowid INTEGER NOT NULL UNIQUE
                    )
                    """
                )
                try database.execute(
                    """
                    CREATE VIRTUAL TABLE IF NOT EXISTS conversation_fts_delta USING fts5(
                        conversation_id UNINDEXED, title, preview, event_text, notes,
                        tokenize = 'unicode61 remove_diacritics 2'
                    )
                    """
                )
                try database.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES(7, ?)",
                    bindings: [.real(Date().timeIntervalSince1970)]
                )
                appliedSchemaTransformation = true
            }
            try database.execute(
                """
                UPDATE conversations
                SET sync_availability = ?
                WHERE sync_availability != ?
                  AND EXISTS (
                    SELECT 1 FROM sync_outbox o
                    WHERE o.object_type = 'conversation'
                      AND o.object_id = conversations.id
                      AND o.acknowledged_at IS NULL
                  )
                """,
                bindings: [
                    .text(SyncAvailability.queued.rawValue),
                    .text(SyncAvailability.queued.rawValue),
                ]
            )
            if appliedSchemaTransformation {
                // Schema transformations are an explicit integrity-check boundary.
                // The flag is consumed by the next health snapshot, not by every
                // reconciliation cycle.
                try setMetadataText("1", key: Self.integrityCheckRequiredMetadataKey)
            }
        }
        try database.enforceSecurePermissions()

        let ftsAvailable = try database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'conversation_fts'"
        ) == 1
        guard ftsAvailable else {
            throw ThreadlineError.database("This SQLite build does not provide FTS5")
        }
        if queuesForSync {
            try promoteLocalOnlyConversationsToOutbox()
            try retryQuarantinedEnvelopes(limit: 100)
        } else {
            try disableSyncQueue()
        }
    }

    public func loadProviderIngestCursor(provider: ProviderKind) async throws -> Date? {
        let key = Self.providerIngestCursorKey(provider)
        guard let encoded = try metadataText(key: key) else { return nil }
        guard encoded.utf8.count <= Self.maximumStoredCursorJSONBytes else {
            throw ThreadlineError.database("The stored provider ingestion cursor exceeds its safe size limit")
        }
        let stored: StoredProviderIngestCursor = try Self.decodeJSON(encoded)
        guard stored.provider == provider,
              stored.completedThrough.timeIntervalSince1970.isFinite else {
            throw ThreadlineError.database("The stored provider ingestion cursor is invalid")
        }
        return stored.completedThrough
    }

    public func saveProviderIngestCursor(_ cursor: Date, provider: ProviderKind) async throws {
        guard cursor.timeIntervalSince1970.isFinite else {
            throw ThreadlineError.invalidPayload("The provider ingestion cursor contains an invalid date")
        }
        let encoded = try Self.encodeJSONString(StoredProviderIngestCursor(
            provider: provider,
            completedThrough: cursor
        ))
        guard encoded.utf8.count <= Self.maximumStoredCursorJSONBytes else {
            throw ThreadlineError.invalidPayload("The provider ingestion cursor exceeds its safe size limit")
        }
        try setMetadataText(encoded, key: Self.providerIngestCursorKey(provider))
    }

    public func loadSyncCursor(transportIdentifier: String) async throws -> SyncCursor {
        let key = try Self.syncCursorKey(transportIdentifier: transportIdentifier)
        guard let encoded = try metadataText(key: key) else { return SyncCursor() }
        guard encoded.utf8.count <= Self.maximumStoredCursorJSONBytes else {
            throw ThreadlineError.database("The stored synchronization cursor exceeds its safe size limit")
        }
        let stored: StoredSyncCursor = try Self.decodeJSON(encoded)
        guard stored.transportIdentifier == transportIdentifier else {
            throw ThreadlineError.database("The stored synchronization cursor belongs to a different transport")
        }
        try Self.validateSyncCursor(stored.cursor, stored: true)
        return stored.cursor
    }

    public func saveSyncCursor(_ cursor: SyncCursor, transportIdentifier: String) async throws {
        let key = try Self.syncCursorKey(transportIdentifier: transportIdentifier)
        try Self.validateSyncCursor(cursor, stored: false)
        let encoded = try Self.encodeJSONString(StoredSyncCursor(
            transportIdentifier: transportIdentifier,
            cursor: cursor
        ))
        guard encoded.utf8.count <= Self.maximumStoredCursorJSONBytes else {
            throw ThreadlineError.invalidPayload("The synchronization cursor exceeds its safe encoded size limit")
        }
        try setMetadataText(encoded, key: key)
    }

    public func upsert(_ conversation: ProviderConversation) async throws {
        _ = try await upsertIfChanged(conversation)
    }

    public func upsertIfChanged(_ conversation: ProviderConversation) async throws -> Bool {
        let existingSource = try database.rows(
            "SELECT source_fingerprint, source_schema_version FROM conversations WHERE id = ?",
            bindings: [.text(conversation.summary.id)]
        ).first
        guard existingSource?[safe: 0]?.string != conversation.sourceFingerprint
                || existingSource?[safe: 1]?.string != conversation.sourceSchemaVersion
        else { return false }

        if queuesForSync {
            let envelope = try envelopeCodec.seal(
                conversation,
                originDeviceID: deviceID,
                createdAt: Date()
            )
            try database.transaction {
                try write(conversation, syncAvailability: .queued)
                try insertOutbox(envelope, objectID: conversation.summary.id)
                try setMetadataDate(Date(), key: "last_ingest_at")
            }
        } else {
            try database.transaction {
                try write(conversation, syncAvailability: .localOnly)
                try setMetadataDate(Date(), key: "last_ingest_at")
            }
        }
        return true
    }

    public func listConversations(
        query: String?,
        provider: ProviderKind?,
        favoritesOnly: Bool
    ) async throws -> [ConversationSummary] {
        var joins = " LEFT JOIN projects p ON p.id = c.project_id"
        var clauses: [String] = []
        var bindings: [SQLiteValue] = []

        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            joins += """
             JOIN (
               SELECT DISTINCT conversation_id FROM (
                 SELECT conversation_id FROM conversation_fts WHERE conversation_fts MATCH ?
                 UNION ALL
                 SELECT conversation_id FROM conversation_fts_delta WHERE conversation_fts_delta MATCH ?
               )
             ) f ON f.conversation_id = c.id
            """
            let expression = Self.ftsExpression(query)
            bindings.append(.text(expression))
            bindings.append(.text(expression))
        }
        if let provider {
            clauses.append("c.provider = ?")
            bindings.append(.text(provider.rawValue))
        }
        if favoritesOnly { clauses.append("c.is_favorite = 1") }

        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let rows = try database.rows(
            Self.summarySelect + joins + whereClause + " ORDER BY c.updated_at DESC, c.id ASC",
            bindings: bindings
        )
        return try rows.map(Self.decodeSummary)
    }

    public func conversation(id: String) async throws -> ConversationDetail? {
        let rows = try database.rows(
            Self.summarySelect + " LEFT JOIN projects p ON p.id = c.project_id WHERE c.id = ?",
            bindings: [.text(id)]
        )
        guard let row = rows.first else { return nil }
        let summary = try Self.decodeSummary(row)

        let eventRows = try database.rows(
            """
            SELECT id, conversation_id, sequence, timestamp, kind, role, text,
                   metadata_json, raw_payload, content_hash, source_device_id
            FROM events WHERE conversation_id = ? ORDER BY sequence ASC, timestamp ASC, id ASC
            """,
            bindings: [.text(id)]
        )
        let events = try eventRows.map(Self.decodeEvent)
        let detailRow = try database.rows(
            "SELECT notes, branch_id, parent_branch_id FROM conversations WHERE id = ?",
            bindings: [.text(id)]
        ).first ?? []
        return ConversationDetail(
            summary: summary,
            events: events,
            notes: detailRow[safe: 0]?.string ?? "",
            branchID: detailRow[safe: 1]?.string ?? "main",
            parentBranchID: detailRow[safe: 2]?.string
        )
    }

    public func setFavorite(_ favorite: Bool, conversationID: String) async throws {
        try requireConversation(conversationID)
        try database.execute(
            "UPDATE conversations SET is_favorite = ? WHERE id = ?",
            bindings: [.integer(favorite ? 1 : 0), .text(conversationID)]
        )
    }

    public func setNotes(_ notes: String, conversationID: String) async throws {
        try requireConversation(conversationID)
        try database.transaction {
            try database.execute(
                "UPDATE conversations SET notes = ? WHERE id = ?",
                bindings: [.text(notes), .text(conversationID)]
            )
            try refreshFTS(conversationID: conversationID)
        }
    }

    public func pendingEnvelopes(limit: Int) async throws -> [SyncEnvelope] {
        guard queuesForSync, limit > 0 else { return [] }
        let rows = try database.rows(
            """
            SELECT id, object_type, logical_version, origin_device_id, created_at,
                   encrypted_payload, payload_hash
            FROM sync_outbox WHERE acknowledged_at IS NULL
            ORDER BY created_at ASC, id ASC LIMIT ?
            """,
            bindings: [.integer(Int64(limit))]
        )
        return try rows.map(Self.decodeEnvelope)
    }

    public func pendingEnvelopes(
        limit: Int,
        maximumBytes: Int
    ) async throws -> [SyncEnvelope] {
        guard queuesForSync, limit > 0 else { return [] }
        guard maximumBytes > 0 else {
            throw ThreadlineError.invalidPayload(
                "The synchronization batch byte limit must be greater than zero."
            )
        }
        // Select only the oldest contiguous prefix that fits the byte budget.
        // The first row is returned even if a future format raises the
        // per-envelope ceiling above the transport ceiling; the shared batcher
        // then emits the precise single-envelope error without starving the
        // queue or loading every later payload into memory.
        let rows = try database.rows(
            """
            WITH oldest_pending AS (
              SELECT id, object_type, logical_version, origin_device_id, created_at,
                     encrypted_payload, payload_hash
              FROM sync_outbox
              WHERE acknowledged_at IS NULL
              ORDER BY created_at ASC, id ASC
              LIMIT ?
            ), ordered_pending AS (
              SELECT id, object_type, logical_version, origin_device_id, created_at,
                     encrypted_payload, payload_hash,
                     ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS row_position,
                     SUM(length(encrypted_payload)) OVER (
                       ORDER BY created_at ASC, id ASC
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                     ) AS running_bytes
              FROM oldest_pending
            )
            SELECT id, object_type, logical_version, origin_device_id, created_at,
                   encrypted_payload, payload_hash
            FROM ordered_pending
            WHERE running_bytes <= ? OR row_position = 1
            ORDER BY created_at ASC, id ASC
            """,
            bindings: [.integer(Int64(limit)), .integer(Int64(maximumBytes))]
        )
        let candidates = try rows.map(Self.decodeEnvelope)
        return try SyncEnvelopeBatcher.prefix(
            candidates,
            maximumCount: limit,
            maximumBytes: maximumBytes
        )
    }

    public func markEnvelopesAcknowledged(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let uniqueIDs = Array(Set(ids))
        let now = Date().timeIntervalSince1970
        try database.transaction {
            // Stay below SQLite's host-parameter ceiling while still turning a
            // potentially large acknowledgement into two statements per batch.
            for offset in stride(from: 0, to: uniqueIDs.count, by: Self.acknowledgementBatchSize) {
                let batch = Array(uniqueIDs[offset..<min(offset + Self.acknowledgementBatchSize, uniqueIDs.count)])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                try database.execute(
                    "UPDATE sync_outbox SET acknowledged_at = ?, encrypted_payload = X'' WHERE acknowledged_at IS NULL AND id IN (\(placeholders))",
                    bindings: [.real(now)] + batch.map(SQLiteValue.text)
                )
                try database.execute(
                    """
                    UPDATE conversations
                    SET sync_availability = ?
                    WHERE id IN (
                      SELECT object_id FROM sync_outbox WHERE id IN (\(placeholders))
                    )
                    AND NOT EXISTS (
                      SELECT 1 FROM sync_outbox pending
                      WHERE pending.object_type = 'conversation'
                        AND pending.object_id = conversations.id
                        AND pending.acknowledged_at IS NULL
                    )
                    """,
                    bindings: [.text(SyncAvailability.acknowledged.rawValue)] + batch.map(SQLiteValue.text)
                )
            }
            try setMetadataDate(Date(), key: "last_sync_at")
        }
    }

    public func applyRemote(_ envelopes: [SyncEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        for envelope in envelopes {
            let incoming: ProviderConversation
            do {
                try SyncEnvelopeLimits.validate(envelope)
                incoming = try envelopeCodec.open(envelope)
            } catch {
                try database.transaction {
                    try quarantine(envelope, error: error)
                }
                continue
            }

            try database.transaction {
                if envelope.originDeviceID != deviceID,
                   let resolved = try resolveRemoteConflict(incoming, envelope: envelope) {
                    try write(resolved, syncAvailability: .availableOffline)
                }
                try database.execute(
                    "DELETE FROM sync_quarantine WHERE envelope_id = ?",
                    bindings: [.text(envelope.id)]
                )
            }
        }
        try database.transaction {
            try setMetadataDate(Date(), key: "last_sync_at")
        }
    }

    public func healthSnapshot() async throws -> HealthSnapshot {
        let pendingCount = try database.scalarInt(
            "SELECT COUNT(*) FROM sync_outbox WHERE acknowledged_at IS NULL"
        )
        let pendingBytes = try database.scalarInt(
            "SELECT COALESCE(SUM(length(encrypted_payload)), 0) FROM sync_outbox WHERE acknowledged_at IS NULL"
        )
        let conversationCount = try database.scalarInt("SELECT COUNT(*) FROM conversations")
        let quarantineCount = try database.scalarInt("SELECT COUNT(*) FROM sync_quarantine")
        let codexAvailable = try database.scalarInt(
            "SELECT COUNT(*) FROM conversations WHERE provider = 'codex' LIMIT 1"
        ) > 0
        let claudeAvailable = try database.scalarInt(
            "SELECT COUNT(*) FROM conversations WHERE provider = 'claude' LIMIT 1"
        ) > 0
        let integrity = try cachedIntegrityResult()
        var issues: [HealthIssue] = []
        if let integrity, integrity != "ok" {
            issues.append(HealthIssue(
                id: "database-integrity",
                severity: .error,
                title: "Database integrity check failed",
                detail: integrity,
                recoverySuggestion: "Restore the local index from synchronized conversation data."
            ))
        }
        if pendingCount > 10_000 {
            issues.append(HealthIssue(
                id: "large-sync-backlog",
                severity: .warning,
                title: "Large synchronization backlog",
                detail: "\(pendingCount) objects are waiting to be acknowledged.",
                recoverySuggestion: "Check iCloud connectivity and account status."
            ))
        }
        if quarantineCount > 0 {
            issues.append(HealthIssue(
                id: "sync-quarantine",
                severity: .error,
                title: "Some synchronized objects need attention",
                detail: "\(quarantineCount) encrypted object(s) could not be safely applied and were quarantined.",
                recoverySuggestion: "Keep Threadline updated. Quarantined payloads are retried at startup without blocking the rest of the library."
            ))
        }

        return HealthSnapshot(
            lastIngestAt: try metadataDate(key: "last_ingest_at"),
            lastSyncAt: try metadataDate(key: "last_sync_at"),
            pendingObjectCount: Int(pendingCount),
            pendingByteCount: pendingBytes,
            indexedConversationCount: Int(conversationCount),
            codexAvailable: codexAvailable,
            claudeAvailable: claudeAvailable,
            cloudAvailable: false,
            issues: issues
        )
    }

    private func write(_ conversation: ProviderConversation, syncAvailability: SyncAvailability) throws {
        let existingSearchFields = try database.rows(
            "SELECT title, preview FROM conversations WHERE id = ?",
            bindings: [.text(conversation.summary.id)]
        ).first
        if let project = conversation.summary.project {
            try database.execute(
                """
                INSERT INTO projects(id, display_name, canonical_path, git_remote) VALUES(?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name,
                  canonical_path = excluded.canonical_path, git_remote = excluded.git_remote
                """,
                bindings: [
                    .text(project.id), .text(project.displayName), Self.value(project.canonicalPath),
                    Self.value(project.gitRemote),
                ]
            )
        }

        let summary = conversation.summary
        try database.execute(
            """
            INSERT INTO conversations(
              id, provider, provider_session_id, title, preview, project_id, created_at, updated_at,
              status, sync_availability, origin_device_id, active_owner_device_id, is_favorite,
              tags_json, message_count, source_fingerprint, source_schema_version
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              provider = excluded.provider, provider_session_id = excluded.provider_session_id,
              title = excluded.title, preview = excluded.preview, project_id = excluded.project_id,
              created_at = excluded.created_at, updated_at = excluded.updated_at, status = excluded.status,
              sync_availability = excluded.sync_availability, origin_device_id = excluded.origin_device_id,
              active_owner_device_id = excluded.active_owner_device_id, tags_json = excluded.tags_json,
              message_count = excluded.message_count, source_fingerprint = excluded.source_fingerprint,
              source_schema_version = excluded.source_schema_version
            """,
            bindings: [
                .text(summary.id), .text(summary.provider.rawValue), .text(summary.providerSessionID),
                .text(summary.title), .text(summary.preview), Self.value(summary.project?.id),
                .real(summary.createdAt.timeIntervalSince1970), .real(summary.updatedAt.timeIntervalSince1970),
                .text(summary.status.rawValue), .text(syncAvailability.rawValue), .text(summary.originDeviceID),
                Self.value(summary.activeOwnerDeviceID), .integer(summary.isFavorite ? 1 : 0),
                .text(try Self.encodeJSONString(summary.tags)), .integer(Int64(summary.messageCount)),
                .text(conversation.sourceFingerprint), .text(conversation.sourceSchemaVersion),
            ]
        )

        let existingEventIDs = try database.rows(
            "SELECT id FROM events WHERE conversation_id = ? ORDER BY sequence ASC, timestamp ASC, id ASC",
            bindings: [.text(summary.id)]
        ).compactMap { $0.first?.string }
        let incomingEventIDs = try conversation.events.enumerated().map { position, event in
            try Self.persistedEventID(conversationID: summary.id, position: position, event: event)
        }
        let sharedCount = min(existingEventIDs.count, incomingEventIDs.count)
        let isAppendOnly = existingEventIDs.count <= incomingEventIDs.count
            && zip(existingEventIDs.prefix(sharedCount), incomingEventIDs.prefix(sharedCount)).allSatisfy { $0.0 == $0.1 }
        let eventsChanged = existingEventIDs != incomingEventIDs

        // Providers normally append. Preserve the stable prefix in that case,
        // including its FTS source rows and metadata. A corrected, reordered or
        // truncated transcript falls back to the prior replace-all behaviour.
        if !isAppendOnly {
            // The mapping is cascaded when events are deleted, so remove the
            // corresponding virtual-table rows first.
            try database.execute(
                "DELETE FROM conversation_fts_delta WHERE rowid IN (SELECT fts_rowid FROM conversation_fts_event_map WHERE event_id IN (SELECT id FROM events WHERE conversation_id = ?))",
                bindings: [.text(summary.id)]
            )
            try database.execute("DELETE FROM events WHERE conversation_id = ?", bindings: [.text(summary.id)])
        }
        let start = isAppendOnly ? existingEventIDs.count : 0
        for position in start..<conversation.events.count {
            let event = conversation.events[position]
            let persistedID = try Self.persistedEventID(
                conversationID: summary.id,
                position: position,
                event: event
            )
            var metadata = event.metadata
            metadata[Self.sourceEventIDMetadataKey] = event.id
            try database.execute(
                """
                INSERT INTO events(id, conversation_id, sequence, timestamp, kind, role, text,
                  metadata_json, raw_payload, content_hash, source_device_id)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(persistedID), .text(summary.id), .integer(event.sequence),
                    .real(event.timestamp.timeIntervalSince1970), .text(event.kind.rawValue),
                    .text(event.role.rawValue), .text(event.text),
                    .text(try Self.encodeJSONString(metadata)), .null,
                    .text(event.contentHash), .text(event.sourceDeviceID),
                ]
            )
        }
        // Event documents repeat the small shared search fields, preserving
        // queries that combine title, notes and event text. Appends therefore
        // add only their suffix; corrected prefixes still rebuild safely.
        let titleOrPreviewChanged = existingSearchFields?[safe: 0]?.string != summary.title
            || existingSearchFields?[safe: 1]?.string != summary.preview
        if titleOrPreviewChanged || !isAppendOnly {
            try refreshFTS(conversationID: summary.id)
        } else if eventsChanged {
            try appendEventFTS(eventIDs: Array(incomingEventIDs.dropFirst(start)))
        }
    }

    private func refreshFTS(conversationID: String) throws {
        try database.execute(
            """
            INSERT OR IGNORE INTO conversation_fts_map(conversation_id, fts_rowid)
            SELECT ?, COALESCE(MAX(fts_rowid), 0) + 1 FROM (
              SELECT fts_rowid FROM conversation_fts_map
              UNION ALL SELECT fts_rowid FROM conversation_fts_event_map
            )
            """,
            bindings: [.text(conversationID)]
        )
        try database.execute(
            "DELETE FROM conversation_fts_delta WHERE rowid IN (SELECT fts_rowid FROM conversation_fts_event_map WHERE event_id IN (SELECT id FROM events WHERE conversation_id = ?))",
            bindings: [.text(conversationID)]
        )
        try database.execute(
            "DELETE FROM conversation_fts_event_map WHERE event_id IN (SELECT id FROM events WHERE conversation_id = ?)",
            bindings: [.text(conversationID)]
        )
        try database.execute(
            "DELETE FROM conversation_fts WHERE rowid = (SELECT fts_rowid FROM conversation_fts_map WHERE conversation_id = ?)",
            bindings: [.text(conversationID)]
        )
        try database.execute(
            """
            INSERT INTO conversation_fts(rowid, conversation_id, title, preview, event_text, notes)
            SELECT m.fts_rowid, c.id, c.title, c.preview,
              COALESCE((SELECT group_concat(e.text, char(10)) FROM events e WHERE e.conversation_id = c.id), ''),
              c.notes
            FROM conversations c JOIN conversation_fts_map m ON m.conversation_id = c.id
            WHERE c.id = ?
            """,
            bindings: [.text(conversationID)]
        )
    }

    private func appendEventFTS(eventIDs: [String]) throws {
        for offset in stride(from: 0, to: eventIDs.count, by: Self.acknowledgementBatchSize) {
            let batch = Array(eventIDs[offset..<min(offset + Self.acknowledgementBatchSize, eventIDs.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            try database.execute(
                """
                INSERT INTO conversation_fts_event_map(event_id, fts_rowid)
                SELECT e.id, (SELECT COALESCE(MAX(fts_rowid), 0) FROM conversation_fts_event_map)
                  + ROW_NUMBER() OVER (ORDER BY e.id)
                FROM events e
                LEFT JOIN conversation_fts_event_map existing ON existing.event_id = e.id
                WHERE e.id IN (\(placeholders)) AND existing.event_id IS NULL
                """,
                bindings: batch.map(SQLiteValue.text)
            )
            try database.execute(
                """
                INSERT INTO conversation_fts_delta(rowid, conversation_id, title, preview, event_text, notes)
                SELECT m.fts_rowid, c.id, c.title, c.preview, e.text, c.notes
                FROM events e JOIN conversations c ON c.id = e.conversation_id
                JOIN conversation_fts_event_map m ON m.event_id = e.id
                LEFT JOIN conversation_fts_delta existing_document ON existing_document.rowid = m.fts_rowid
                WHERE e.id IN (\(placeholders)) AND existing_document.rowid IS NULL
                """,
                bindings: batch.map(SQLiteValue.text)
            )
        }
    }

    private func disableSyncQueue() throws {
        // Local-only and staging libraries cannot deliver an outbox. Removing
        // both pending snapshots and acknowledged history prevents a disabled
        // transport from retaining a second full copy of every transcript.
        try database.transaction {
            try database.execute("DELETE FROM sync_outbox")
            try database.execute(
                "UPDATE conversations SET sync_availability = ? WHERE sync_availability = ?",
                bindings: [
                    .text(SyncAvailability.localOnly.rawValue),
                    .text(SyncAvailability.queued.rawValue),
                ]
            )
        }
    }

    /// Runs SQLite's full integrity scan only when the persisted 24-hour
    /// schedule, or a migration boundary, says it is due. Call this from a
    /// low-priority maintenance scheduler, never from UI health rendering.
    public func runIntegrityCheckIfDue() async throws -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedIntegrityCheck,
           now >= cachedIntegrityCheck.checkedAtUptime,
           now - cachedIntegrityCheck.checkedAtUptime < Self.integrityCheckCacheInterval {
            return nil
        }
        let wallClockNow = Date()
        let requiresCheck = try metadataText(key: Self.integrityCheckRequiredMetadataKey) == "1"
        if !requiresCheck,
           let checkedAt = try metadataDate(key: Self.integrityCheckDateMetadataKey),
           wallClockNow.timeIntervalSince(checkedAt) < Self.integrityCheckCacheInterval,
           let persisted = try metadataText(key: Self.integrityCheckResultMetadataKey) {
            cachedIntegrityCheck = (persisted, now)
            return nil
        }
        let result = try database.rows("PRAGMA quick_check").first?.first?.string ?? "unknown"
        cachedIntegrityCheck = (result, now)
        integrityCheckExecutionCount += 1
        try database.transaction {
            try setMetadataDate(wallClockNow, key: Self.integrityCheckDateMetadataKey)
            try setMetadataText(result, key: Self.integrityCheckResultMetadataKey)
            try setMetadataText("0", key: Self.integrityCheckRequiredMetadataKey)
        }
        return result
    }

    private func cachedIntegrityResult() throws -> String? {
        if let cachedIntegrityCheck { return cachedIntegrityCheck.result }
        return try metadataText(key: Self.integrityCheckResultMetadataKey)
    }

    private func promoteLocalOnlyConversationsToOutbox() throws {
        let conversationIDs = try database.rows(
            "SELECT id FROM conversations WHERE sync_availability = ? ORDER BY updated_at ASC, id ASC",
            bindings: [.text(SyncAvailability.localOnly.rawValue)]
        ).compactMap { $0.first?.string }

        for conversationID in conversationIDs {
            guard let conversation = try storedProviderConversation(id: conversationID) else { continue }
            let envelope = try envelopeCodec.seal(
                conversation,
                originDeviceID: conversation.summary.originDeviceID,
                createdAt: Date()
            )
            try database.transaction {
                try insertOutbox(envelope, objectID: conversationID)
                try database.execute(
                    "UPDATE conversations SET sync_availability = ? WHERE id = ? AND sync_availability = ?",
                    bindings: [
                        .text(SyncAvailability.queued.rawValue),
                        .text(conversationID),
                        .text(SyncAvailability.localOnly.rawValue),
                    ]
                )
            }
        }
    }

    private func storedProviderConversation(id: String) throws -> ProviderConversation? {
        let summaryRows = try database.rows(
            Self.summarySelect + " LEFT JOIN projects p ON p.id = c.project_id WHERE c.id = ?",
            bindings: [.text(id)]
        )
        guard let summaryRow = summaryRows.first else { return nil }
        let summary = try Self.decodeSummary(summaryRow)
        let sourceRow = try database.rows(
            "SELECT source_fingerprint, source_schema_version FROM conversations WHERE id = ?",
            bindings: [.text(id)]
        ).first
        guard let sourceFingerprint = sourceRow?[safe: 0]?.string,
              let sourceSchemaVersion = sourceRow?[safe: 1]?.string
        else {
            throw ThreadlineError.database("A local conversation is missing its source identity")
        }

        let eventRows = try database.rows(
            """
            SELECT id, conversation_id, sequence, timestamp, kind, role, text,
                   metadata_json, raw_payload, content_hash, source_device_id
            FROM events WHERE conversation_id = ? ORDER BY sequence ASC, timestamp ASC, id ASC
            """,
            bindings: [.text(id)]
        )
        let events = try eventRows.map { row in
            let stored = try Self.decodeEvent(row)
            var metadata = stored.metadata
            let sourceEventID = metadata.removeValue(forKey: Self.sourceEventIDMetadataKey) ?? stored.id
            return ConversationEvent(
                id: sourceEventID,
                conversationID: stored.conversationID,
                sequence: stored.sequence,
                timestamp: stored.timestamp,
                kind: stored.kind,
                role: stored.role,
                text: stored.text,
                metadata: metadata,
                rawPayload: nil,
                contentHash: stored.contentHash,
                sourceDeviceID: stored.sourceDeviceID
            )
        }
        return ProviderConversation(
            summary: summary,
            events: events,
            sourceFingerprint: sourceFingerprint,
            sourceSchemaVersion: sourceSchemaVersion
        )
    }

    private static let sourceEventIDMetadataKey = "_threadlineSourceEventID"

    private struct PersistedEventIdentity: Encodable {
        let conversationID: String
        let position: Int
        let sourceEventID: String
        let sourceSequence: Int64
        let timestamp: TimeInterval
        let kind: EventKind
        let role: MessageRole
        let text: String
        let metadata: [String: String]
        let sourceDeviceID: String
        let contentHash: String
    }

    /// Provider event identifiers are not guaranteed to be globally unique and
    /// may even repeat within one transcript. The database identity therefore
    /// includes the owning conversation and occurrence while retaining the
    /// provider's identifier in metadata for diagnostics and future adapters.
    private static func persistedEventID(
        conversationID: String,
        position: Int,
        event: ConversationEvent
    ) throws -> String {
        let identity = PersistedEventIdentity(
            conversationID: conversationID,
            position: position,
            sourceEventID: event.id,
            sourceSequence: event.sequence,
            timestamp: event.timestamp.timeIntervalSince1970,
            kind: event.kind,
            role: event.role,
            text: event.text,
            metadata: event.metadata,
            sourceDeviceID: event.sourceDeviceID,
            contentHash: event.contentHash
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(identity))
            .map { String(format: "%02x", $0) }
            .joined()
        return "event:\(digest)"
    }

    private func insertOutbox(_ envelope: SyncEnvelope, objectID: String) throws {
        // A pending envelope is a replaceable snapshot, not an append-only
        // delivery log. Acknowledged rows remain as history, while a newer
        // local snapshot atomically supersedes any unacknowledged predecessor.
        try database.execute(
            """
            DELETE FROM sync_outbox
            WHERE object_type = ? AND object_id = ?
              AND acknowledged_at IS NULL AND id != ?
            """,
            bindings: [.text(envelope.objectType), .text(objectID), .text(envelope.id)]
        )
        try database.execute(
            """
            INSERT INTO sync_outbox(id, object_id, object_type, logical_version, origin_device_id,
              created_at, encrypted_payload, payload_hash, acknowledged_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
              object_id = excluded.object_id,
              object_type = excluded.object_type,
              logical_version = excluded.logical_version,
              origin_device_id = excluded.origin_device_id,
              created_at = excluded.created_at,
              encrypted_payload = excluded.encrypted_payload,
              payload_hash = excluded.payload_hash,
              acknowledged_at = NULL
            """,
            bindings: [
                .text(envelope.id), .text(objectID), .text(envelope.objectType),
                .integer(Int64(envelope.logicalVersion)),
                .text(envelope.originDeviceID), .real(envelope.createdAt.timeIntervalSince1970),
                .blob(envelope.encryptedPayload), .text(envelope.payloadHash),
            ]
        )
    }

    private static func compactPendingOutbox(using database: SQLiteConnection) throws {
        // Keep the newest row by creation time. rowid is a deterministic final
        // tie-breaker for legacy rows written in the same timestamp quantum.
        try database.execute(
            """
            DELETE FROM sync_outbox
            WHERE rowid IN (
              SELECT rowid FROM (
                SELECT rowid,
                  ROW_NUMBER() OVER (
                    PARTITION BY object_type, object_id
                    ORDER BY created_at DESC, rowid DESC
                  ) AS pending_rank
                FROM sync_outbox
                WHERE acknowledged_at IS NULL
              )
              WHERE pending_rank > 1
            )
            """
        )
    }

    private func resolveRemoteConflict(
        _ incoming: ProviderConversation,
        envelope: SyncEnvelope
    ) throws -> ProviderConversation? {
        let existing = try database.rows(
            "SELECT source_fingerprint, source_schema_version, updated_at, origin_device_id FROM conversations WHERE id = ?",
            bindings: [.text(incoming.summary.id)]
        ).first
        guard let existing else { return incoming }
        if existing[safe: 0]?.string == incoming.sourceFingerprint,
           existing[safe: 1]?.string == incoming.sourceSchemaVersion {
            return nil
        }
        guard let localUpdated = existing[safe: 2]?.double else { return incoming }

        let localOriginDeviceID = existing[safe: 3]?.string
        if localOriginDeviceID == incoming.summary.originDeviceID {
            return incoming.summary.updatedAt.timeIntervalSince1970 >= localUpdated ? incoming : nil
        }

        try database.execute(
            "UPDATE conversations SET status = ? WHERE id = ?",
            bindings: [.text(ConversationStatus.divergent.rawValue), .text(incoming.summary.id)]
        )
        let suffix = String(envelope.payloadHash.prefix(12))
        let forkID = "\(incoming.summary.id):fork:\(suffix)"
        let old = incoming.summary
        let forkSummary = ConversationSummary(
            id: forkID,
            provider: old.provider,
            providerSessionID: old.providerSessionID,
            title: "\(old.title) — Conflicting continuation",
            preview: old.preview,
            project: old.project,
            createdAt: old.createdAt,
            updatedAt: old.updatedAt,
            status: .divergent,
            syncAvailability: .divergent,
            originDeviceID: old.originDeviceID,
            activeOwnerDeviceID: nil,
            isFavorite: old.isFavorite,
            tags: old.tags,
            messageCount: old.messageCount
        )
        let forkEvents = incoming.events.map { event in
            ConversationEvent(
                id: "\(event.id):\(suffix)",
                conversationID: forkID,
                sequence: event.sequence,
                timestamp: event.timestamp,
                kind: event.kind,
                role: event.role,
                text: event.text,
                metadata: event.metadata,
                rawPayload: event.rawPayload,
                contentHash: event.contentHash,
                sourceDeviceID: event.sourceDeviceID
            )
        }
        return ProviderConversation(
            summary: forkSummary,
            events: forkEvents,
            sourceFingerprint: incoming.sourceFingerprint,
            sourceSchemaVersion: incoming.sourceSchemaVersion
        )
    }

    private func quarantine(_ envelope: SyncEnvelope, error: Error) throws {
        let now = Date().timeIntervalSince1970
        let shouldPreservePayload = envelope.encryptedPayload.count <= SyncEnvelopeLimits.maximumQuarantinedPayloadBytes
        let message = String(error.localizedDescription.prefix(4_096))
        try database.execute(
            """
            INSERT INTO sync_quarantine(
              envelope_id, object_type, logical_version, origin_device_id, created_at,
              encrypted_payload, payload_hash, payload_byte_count, payload_omitted,
              error_message, first_seen_at, last_seen_at, attempt_count
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(envelope_id) DO UPDATE SET
              object_type = excluded.object_type,
              logical_version = excluded.logical_version,
              origin_device_id = excluded.origin_device_id,
              created_at = excluded.created_at,
              encrypted_payload = excluded.encrypted_payload,
              payload_hash = excluded.payload_hash,
              payload_byte_count = excluded.payload_byte_count,
              payload_omitted = excluded.payload_omitted,
              error_message = excluded.error_message,
              last_seen_at = excluded.last_seen_at,
              attempt_count = sync_quarantine.attempt_count + 1
            """,
            bindings: [
                .text(String(envelope.id.prefix(SyncEnvelopeLimits.maximumIdentifierBytes))),
                .text(String(envelope.objectType.prefix(4_096))),
                .integer(Int64(envelope.logicalVersion)),
                .text(String(envelope.originDeviceID.prefix(4_096))),
                .real(envelope.createdAt.timeIntervalSince1970),
                shouldPreservePayload ? .blob(envelope.encryptedPayload) : .null,
                .text(String(envelope.payloadHash.prefix(4_096))),
                .integer(Int64(envelope.encryptedPayload.count)),
                .integer(shouldPreservePayload ? 0 : 1),
                .text(message), .real(now), .real(now),
            ]
        )
    }

    private func retryQuarantinedEnvelopes(limit: Int) throws {
        let rows = try database.rows(
            """
            SELECT envelope_id, object_type, logical_version, origin_device_id, created_at,
                   encrypted_payload, payload_hash
            FROM sync_quarantine
            WHERE encrypted_payload IS NOT NULL
            ORDER BY first_seen_at ASC
            LIMIT ?
            """,
            bindings: [.integer(Int64(max(0, limit)))]
        )
        for row in rows {
            let envelope: SyncEnvelope
            do {
                envelope = try Self.decodeEnvelope(row)
                try SyncEnvelopeLimits.validate(envelope)
                let incoming = try envelopeCodec.open(envelope)
                try database.transaction {
                    if envelope.originDeviceID != deviceID,
                       let resolved = try resolveRemoteConflict(incoming, envelope: envelope) {
                        try write(resolved, syncAvailability: .availableOffline)
                    }
                    try database.execute(
                        "DELETE FROM sync_quarantine WHERE envelope_id = ?",
                        bindings: [.text(envelope.id)]
                    )
                }
            } catch {
                let id = row.first?.string ?? "unknown"
                try database.execute(
                    """
                    UPDATE sync_quarantine
                    SET error_message = ?, last_seen_at = ?, attempt_count = attempt_count + 1
                    WHERE envelope_id = ?
                    """,
                    bindings: [
                        .text(String(error.localizedDescription.prefix(4_096))),
                        .real(Date().timeIntervalSince1970), .text(id),
                    ]
                )
            }
        }
    }

    private func requireConversation(_ id: String) throws {
        guard try database.scalarInt("SELECT COUNT(*) FROM conversations WHERE id = ?", bindings: [.text(id)]) > 0 else {
            throw ThreadlineError.database("Conversation \(id) does not exist")
        }
    }

    private func setMetadataDate(_ date: Date, key: String) throws {
        try database.execute(
            """
            INSERT INTO store_metadata(key, real_value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET real_value = excluded.real_value
            """,
            bindings: [.text(key), .real(date.timeIntervalSince1970)]
        )
    }

    private func setMetadataText(_ value: String, key: String) throws {
        try database.execute(
            """
            INSERT INTO store_metadata(key, text_value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET
              real_value = NULL, text_value = excluded.text_value, blob_value = NULL
            """,
            bindings: [.text(key), .text(value)]
        )
    }

    private func metadataText(key: String) throws -> String? {
        try database.rows(
            "SELECT text_value FROM store_metadata WHERE key = ?",
            bindings: [.text(key)]
        ).first?.first?.string
    }

    private func metadataDate(key: String) throws -> Date? {
        guard let value = try database.rows(
            "SELECT real_value FROM store_metadata WHERE key = ?",
            bindings: [.text(key)]
        ).first?.first?.double else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private static let summarySelect = """
    SELECT c.id, c.provider, c.provider_session_id, c.title, c.preview,
      p.id, p.display_name, p.canonical_path, p.git_remote,
      c.created_at, c.updated_at, c.status, c.sync_availability, c.origin_device_id,
      c.active_owner_device_id, c.is_favorite, c.tags_json, c.message_count
    FROM conversations c
    """

    internal static let preVersion5BackupSuffix = ".pre-v5.backup"

    private static func decodeSummary(_ row: [SQLiteValue]) throws -> ConversationSummary {
        guard row.count >= 18,
              let id = row[0].string,
              let providerRaw = row[1].string, let provider = ProviderKind(rawValue: providerRaw),
              let sessionID = row[2].string, let title = row[3].string, let preview = row[4].string,
              let created = row[9].double, let updated = row[10].double,
              let statusRaw = row[11].string, let status = ConversationStatus(rawValue: statusRaw),
              let syncRaw = row[12].string, let sync = SyncAvailability(rawValue: syncRaw),
              let origin = row[13].string
        else { throw ThreadlineError.database("A conversation row contains invalid data") }

        let project: ProjectIdentity?
        if let projectID = row[5].string, let projectName = row[6].string {
            project = ProjectIdentity(
                id: projectID,
                displayName: projectName,
                canonicalPath: row[7].string,
                gitRemote: row[8].string
            )
        } else { project = nil }
        let tags: [String] = try decodeJSON(row[16].string ?? "[]")
        return ConversationSummary(
            id: id,
            provider: provider,
            providerSessionID: sessionID,
            title: title,
            preview: preview,
            project: project,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated),
            status: status,
            syncAvailability: sync,
            originDeviceID: origin,
            activeOwnerDeviceID: row[14].string,
            isFavorite: row[15].int64 == 1,
            tags: tags,
            messageCount: Int(row[17].int64 ?? 0)
        )
    }

    private static func decodeEvent(_ row: [SQLiteValue]) throws -> ConversationEvent {
        guard row.count >= 11,
              let id = row[0].string, let conversationID = row[1].string,
              let sequence = row[2].int64, let timestamp = row[3].double,
              let kindRaw = row[4].string, let kind = EventKind(rawValue: kindRaw),
              let roleRaw = row[5].string, let role = MessageRole(rawValue: roleRaw),
              let text = row[6].string, let metadataJSON = row[7].string,
              let contentHash = row[9].string, let sourceDeviceID = row[10].string
        else { throw ThreadlineError.database("An event row contains invalid data") }
        let metadata: [String: String] = try decodeJSON(metadataJSON)
        return ConversationEvent(
            id: id,
            conversationID: conversationID,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: timestamp),
            kind: kind,
            role: role,
            text: text,
            metadata: metadata,
            rawPayload: row[8].data,
            contentHash: contentHash,
            sourceDeviceID: sourceDeviceID
        )
    }

    private static func decodeEnvelope(_ row: [SQLiteValue]) throws -> SyncEnvelope {
        guard row.count >= 7,
              let id = row[0].string, let type = row[1].string, let version = row[2].int64,
              let origin = row[3].string, let created = row[4].double,
              let payload = row[5].data, let hash = row[6].string
        else { throw ThreadlineError.database("An outbox row contains invalid data") }
        return SyncEnvelope(
            id: id,
            objectType: type,
            logicalVersion: Int(version),
            originDeviceID: origin,
            createdAt: Date(timeIntervalSince1970: created),
            encryptedPayload: payload,
            payloadHash: hash
        )
    }

    private static func ftsExpression(_ input: String) -> String {
        let tokens = input.split(whereSeparator: { $0.isWhitespace }).map { token in
            "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"*"
        }
        return tokens.isEmpty ? "\"\"" : tokens.joined(separator: " AND ")
    }

    private static func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ThreadlineError.database("Could not encode JSON for SQLite")
        }
        return string
    }

    private static func decodeJSON<T: Decodable>(_ string: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(string.utf8)) }
        catch { throw ThreadlineError.database("Could not decode JSON from SQLite: \(error.localizedDescription)") }
    }

    // Ingestion cursors are versioned independently from transport cursors.
    // Revision 5 forces a complete reconciliation after provider identity and
    // raw-payload minimization changes, including installations that briefly
    // ran the v4 draft and already persisted its cursor.
    private static let providerIngestCursorMetadataNamespace = "threadline.ingest-cursor.v5"
    private static let syncCursorMetadataNamespace = "threadline.cursor.v1"
    private static let integrityCheckCacheInterval: TimeInterval = 24 * 60 * 60
    private static let integrityCheckDateMetadataKey = "database_integrity_checked_at"
    private static let integrityCheckResultMetadataKey = "database_integrity_result"
    private static let integrityCheckRequiredMetadataKey = "database_integrity_check_required"
    private static let acknowledgementBatchSize = 400
    private static let maximumStoredCursorJSONBytes =
        ((SyncEnvelopeLimits.maximumCursorBytes + 2) / 3 * 4)
        + SyncEnvelopeLimits.maximumIdentifierBytes
        + 4_096

    private static func providerIngestCursorKey(_ provider: ProviderKind) -> String {
        "\(providerIngestCursorMetadataNamespace).provider.\(provider.rawValue)"
    }

    private static func syncCursorKey(transportIdentifier: String) throws -> String {
        guard !transportIdentifier.isEmpty,
              transportIdentifier.utf8.count <= SyncEnvelopeLimits.maximumIdentifierBytes else {
            throw ThreadlineError.invalidPayload("The synchronization transport identifier is invalid")
        }
        let encodedIdentifier = Data(transportIdentifier.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(syncCursorMetadataNamespace).transport.\(encodedIdentifier)"
    }

    private static func validateSyncCursor(_ cursor: SyncCursor, stored: Bool) throws {
        let invalid: (String) -> ThreadlineError = { message in
            stored ? .database(message) : .invalidPayload(message)
        }
        guard cursor.updatedAt.timeIntervalSince1970.isFinite else {
            throw invalid("The synchronization cursor contains an invalid date")
        }
        guard (cursor.token?.count ?? 0) <= SyncEnvelopeLimits.maximumCursorBytes else {
            throw invalid("The synchronization cursor exceeds its safe size limit")
        }
    }

    private static func value(_ string: String?) -> SQLiteValue { string.map(SQLiteValue.text) ?? .null }
    private static func value(_ data: Data?) -> SQLiteValue { data.map(SQLiteValue.blob) ?? .null }
}

private struct StoredProviderIngestCursor: Codable {
    let provider: ProviderKind
    let completedThrough: Date
}

private struct StoredSyncCursor: Codable {
    let transportIdentifier: String
    let cursor: SyncCursor
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
