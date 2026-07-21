import Foundation

public protocol ProviderAdapter: Sendable {
    var kind: ProviderKind { get }
    func discoverSources() async -> [ProviderSource]
    func fetchConversations(since: Date?) async throws -> [ProviderConversation]
    func scanConversations(
        since: Date?,
        yield: @escaping @Sendable (ProviderConversation) async throws -> Void
    ) async throws
    func fetchConversation(id: String) async throws -> ProviderConversation?
}

public extension ProviderAdapter {
    func scanConversations(
        since: Date?,
        yield: @escaping @Sendable (ProviderConversation) async throws -> Void
    ) async throws {
        for conversation in try await fetchConversations(since: since) {
            try Task.checkCancellation()
            try await yield(conversation)
        }
    }
}

public protocol SyncTransport: Sendable {
    var identifier: String { get }
    func push(_ envelopes: [SyncEnvelope]) async throws
    func pull(since cursor: SyncCursor) async throws -> SyncPullResult
    func pull(
        since cursor: SyncCursor,
        onProgress: @escaping @Sendable (SyncTransportProgress) async -> Void
    ) async throws -> SyncPullResult
    func healthCheck() async -> Bool
}

public extension SyncTransport {
    func pull(
        since cursor: SyncCursor,
        onProgress: @escaping @Sendable (SyncTransportProgress) async -> Void
    ) async throws -> SyncPullResult {
        let result = try await pull(since: cursor)
        await onProgress(SyncTransportProgress(
            activity: .reading,
            completedItemCount: result.envelopes.count,
            totalItemCount: result.remainingItemCount.map {
                result.envelopes.count + $0
            },
            completedByteCount: Int64(result.envelopes.reduce(0) {
                $0 + $1.encryptedPayload.count
            }),
            totalByteCount: result.remainingByteCount.map {
                $0 + Int64(result.envelopes.reduce(0) { $0 + $1.encryptedPayload.count })
            }
        ))
        return result
    }
}

public protocol ConversationStore: Sendable {
    func migrate() async throws
    func loadProviderIngestCursor(provider: ProviderKind) async throws -> Date?
    func saveProviderIngestCursor(_ cursor: Date, provider: ProviderKind) async throws
    func loadSyncCursor(transportIdentifier: String) async throws -> SyncCursor
    func saveSyncCursor(_ cursor: SyncCursor, transportIdentifier: String) async throws
    func upsert(_ conversation: ProviderConversation) async throws
    func listConversations(query: String?, provider: ProviderKind?, favoritesOnly: Bool) async throws -> [ConversationSummary]
    func conversation(id: String) async throws -> ConversationDetail?
    func setFavorite(_ favorite: Bool, conversationID: String) async throws
    func setNotes(_ notes: String, conversationID: String) async throws
    func pendingEnvelopes(limit: Int) async throws -> [SyncEnvelope]
    func pendingEnvelopes(limit: Int, maximumBytes: Int) async throws -> [SyncEnvelope]
    func markEnvelopesAcknowledged(ids: [String]) async throws
    func applyRemote(_ envelopes: [SyncEnvelope]) async throws
    func healthSnapshot() async throws -> HealthSnapshot
}

public extension ConversationStore {
    func loadProviderIngestCursor(provider: ProviderKind) async throws -> Date? { nil }

    func saveProviderIngestCursor(_ cursor: Date, provider: ProviderKind) async throws {}

    func loadSyncCursor(transportIdentifier: String) async throws -> SyncCursor { SyncCursor() }

    func saveSyncCursor(_ cursor: SyncCursor, transportIdentifier: String) async throws {}

    func pendingEnvelopes(
        limit: Int,
        maximumBytes: Int
    ) async throws -> [SyncEnvelope] {
        let candidates = try await pendingEnvelopes(limit: limit)
        return try SyncEnvelopeBatcher.prefix(
            candidates,
            maximumCount: limit,
            maximumBytes: maximumBytes
        )
    }
}

public enum ThreadlineError: LocalizedError, Sendable {
    case unavailable(String)
    case incompatibleProvider(String)
    case invalidPayload(String)
    case database(String)
    case encryption(String)
    case cloud(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message),
             .incompatibleProvider(let message),
             .invalidPayload(let message),
             .database(let message),
             .encryption(let message),
             .cloud(let message): message
        }
    }
}
