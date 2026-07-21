import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}

public enum ConversationStatus: String, Codable, Sendable, CaseIterable {
    case active
    case idle
    case archived
    case divergent
    case unavailable
}

public enum SyncAvailability: String, Codable, Sendable, CaseIterable {
    case localOnly
    case queued
    case uploaded
    case availableOffline
    case acknowledged
    case blocked
    case divergent
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case userMessage
    case assistantMessage
    case systemMessage
    case command
    case toolCall
    case toolResult
    case fileChange
    case diff
    case attachment
    case subagent
    case compaction
    case lifecycle
    case error
    case unknown
}

public struct ProjectIdentity: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var displayName: String
    public var canonicalPath: String?
    public var gitRemote: String?

    public init(id: String, displayName: String, canonicalPath: String? = nil, gitRemote: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.gitRemote = gitRemote
    }
}

public struct ConversationSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let provider: ProviderKind
    public let providerSessionID: String
    public var title: String
    public var preview: String
    public var project: ProjectIdentity?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: ConversationStatus
    public var syncAvailability: SyncAvailability
    public var originDeviceID: String
    public var activeOwnerDeviceID: String?
    public var isFavorite: Bool
    public var tags: [String]
    public var messageCount: Int

    public init(
        id: String,
        provider: ProviderKind,
        providerSessionID: String,
        title: String,
        preview: String = "",
        project: ProjectIdentity? = nil,
        createdAt: Date,
        updatedAt: Date,
        status: ConversationStatus = .idle,
        syncAvailability: SyncAvailability = .localOnly,
        originDeviceID: String,
        activeOwnerDeviceID: String? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        messageCount: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.title = title
        self.preview = preview
        self.project = project
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.syncAvailability = syncAvailability
        self.originDeviceID = originDeviceID
        self.activeOwnerDeviceID = activeOwnerDeviceID
        self.isFavorite = isFavorite
        self.tags = tags
        self.messageCount = messageCount
    }
}

public struct ConversationEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationID: String
    public var sequence: Int64
    public var timestamp: Date
    public var kind: EventKind
    public var role: MessageRole
    public var text: String
    public var metadata: [String: String]
    public var rawPayload: Data?
    public var contentHash: String
    public var sourceDeviceID: String

    public init(
        id: String,
        conversationID: String,
        sequence: Int64,
        timestamp: Date,
        kind: EventKind,
        role: MessageRole,
        text: String,
        metadata: [String: String] = [:],
        rawPayload: Data? = nil,
        contentHash: String,
        sourceDeviceID: String
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.role = role
        self.text = text
        self.metadata = metadata
        self.rawPayload = rawPayload
        self.contentHash = contentHash
        self.sourceDeviceID = sourceDeviceID
    }
}

public struct ConversationDetail: Codable, Sendable, Hashable, Identifiable {
    public var id: String { summary.id }
    public var summary: ConversationSummary
    public var events: [ConversationEvent]
    public var notes: String
    public var branchID: String
    public var parentBranchID: String?

    public init(
        summary: ConversationSummary,
        events: [ConversationEvent],
        notes: String = "",
        branchID: String = "main",
        parentBranchID: String? = nil
    ) {
        self.summary = summary
        self.events = events
        self.notes = notes
        self.branchID = branchID
        self.parentBranchID = parentBranchID
    }
}

public struct ProviderSource: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let provider: ProviderKind
    public let rootPath: String
    public let displayName: String
    public let version: String?
    public let isAvailable: Bool

    public init(id: String, provider: ProviderKind, rootPath: String, displayName: String, version: String?, isAvailable: Bool) {
        self.id = id
        self.provider = provider
        self.rootPath = rootPath
        self.displayName = displayName
        self.version = version
        self.isAvailable = isAvailable
    }
}

public struct ProviderConversation: Codable, Sendable, Hashable {
    public let summary: ConversationSummary
    public let events: [ConversationEvent]
    public let sourceFingerprint: String
    public let sourceSchemaVersion: String

    public init(summary: ConversationSummary, events: [ConversationEvent], sourceFingerprint: String, sourceSchemaVersion: String) {
        self.summary = summary
        self.events = events
        self.sourceFingerprint = sourceFingerprint
        self.sourceSchemaVersion = sourceSchemaVersion
    }
}

public struct SyncEnvelope: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let objectType: String
    public let logicalVersion: Int
    public let originDeviceID: String
    public let createdAt: Date
    public let encryptedPayload: Data
    public let payloadHash: String

    public init(id: String, objectType: String, logicalVersion: Int, originDeviceID: String, createdAt: Date, encryptedPayload: Data, payloadHash: String) {
        self.id = id
        self.objectType = objectType
        self.logicalVersion = logicalVersion
        self.originDeviceID = originDeviceID
        self.createdAt = createdAt
        self.encryptedPayload = encryptedPayload
        self.payloadHash = payloadHash
    }
}

/// Hard safety boundaries for payloads received from providers or sync transports.
/// Large transcript support is implemented through chunking/blob records rather
/// than by allowing a single allocation to grow without bound.
public enum SyncEnvelopeLimits {
    public static let maximumPayloadBytes = 64 * 1_024 * 1_024
    public static let maximumTransportBatchBytes = 64 * 1_024 * 1_024
    public static let maximumPullBatchBytes = 128 * 1_024 * 1_024
    public static let maximumQuarantinedPayloadBytes = 8 * 1_024 * 1_024
    public static let maximumCursorBytes = 1 * 1_024 * 1_024
    public static let maximumIdentifierBytes = 8 * 1_024
    public static let maximumMetadataStringBytes = 16 * 1_024
    public static let authenticatedFormatVersion = 2
    public static let legacyFormatVersion = 1

    public static func validate(_ envelope: SyncEnvelope) throws {
        guard envelope.logicalVersion == legacyFormatVersion
                || envelope.logicalVersion == authenticatedFormatVersion else {
            throw ThreadlineError.invalidPayload(
                "Unsupported sync envelope version: \(envelope.logicalVersion)"
            )
        }
        guard envelope.encryptedPayload.count <= maximumPayloadBytes else {
            throw ThreadlineError.invalidPayload(
                "Sync envelope exceeds the safe \(maximumPayloadBytes)-byte limit"
            )
        }
        for value in [envelope.id, envelope.objectType, envelope.originDeviceID, envelope.payloadHash] {
            guard value.utf8.count <= maximumMetadataStringBytes else {
                throw ThreadlineError.invalidPayload("Sync envelope metadata exceeds the safe size limit")
            }
        }
        guard envelope.id.utf8.count <= maximumIdentifierBytes else {
            throw ThreadlineError.invalidPayload("Sync envelope identifier exceeds the safe size limit")
        }
        guard envelope.createdAt.timeIntervalSince1970.isFinite else {
            throw ThreadlineError.invalidPayload("Sync envelope contains an invalid creation date")
        }
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard envelope.payloadHash.utf8.count == 64,
              envelope.payloadHash.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw ThreadlineError.invalidPayload("Sync envelope contains an invalid payload hash")
        }
    }
}

public struct SyncCursor: Codable, Sendable, Hashable {
    public var token: Data?
    public var updatedAt: Date

    public init(token: Data? = nil, updatedAt: Date = .distantPast) {
        self.token = token
        self.updatedAt = updatedAt
    }
}

public struct SyncTransportProgress: Sendable, Hashable {
    public enum Activity: String, Sendable, Hashable {
        case enumerating
        case reading
    }

    public let activity: Activity
    public let completedItemCount: Int
    public let totalItemCount: Int?
    public let completedByteCount: Int64
    public let totalByteCount: Int64?

    public init(
        activity: Activity,
        completedItemCount: Int,
        totalItemCount: Int? = nil,
        completedByteCount: Int64 = 0,
        totalByteCount: Int64? = nil
    ) {
        self.activity = activity
        self.completedItemCount = completedItemCount
        self.totalItemCount = totalItemCount
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
    }
}

public struct SyncPullResult: Sendable {
    public let envelopes: [SyncEnvelope]
    public let cursor: SyncCursor
    public let remainingItemCount: Int?
    public let remainingByteCount: Int64?

    public init(
        envelopes: [SyncEnvelope],
        cursor: SyncCursor,
        remainingItemCount: Int? = nil,
        remainingByteCount: Int64? = nil
    ) {
        self.envelopes = envelopes
        self.cursor = cursor
        self.remainingItemCount = remainingItemCount
        self.remainingByteCount = remainingByteCount
    }
}

public struct HealthIssue: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable { case info, warning, error }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let recoverySuggestion: String?

    public init(id: String, severity: Severity, title: String, detail: String, recoverySuggestion: String? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recoverySuggestion = recoverySuggestion
    }
}

public struct HealthSnapshot: Codable, Sendable, Hashable {
    public var lastIngestAt: Date?
    public var lastSyncAt: Date?
    public var pendingObjectCount: Int
    public var pendingByteCount: Int64
    public var indexedConversationCount: Int
    public var codexAvailable: Bool
    public var claudeAvailable: Bool
    public var cloudAvailable: Bool
    public var issues: [HealthIssue]

    public init(
        lastIngestAt: Date? = nil,
        lastSyncAt: Date? = nil,
        pendingObjectCount: Int = 0,
        pendingByteCount: Int64 = 0,
        indexedConversationCount: Int = 0,
        codexAvailable: Bool = false,
        claudeAvailable: Bool = false,
        cloudAvailable: Bool = false,
        issues: [HealthIssue] = []
    ) {
        self.lastIngestAt = lastIngestAt
        self.lastSyncAt = lastSyncAt
        self.pendingObjectCount = pendingObjectCount
        self.pendingByteCount = pendingByteCount
        self.indexedConversationCount = indexedConversationCount
        self.codexAvailable = codexAvailable
        self.claudeAvailable = claudeAvailable
        self.cloudAvailable = cloudAvailable
        self.issues = issues
    }
}
