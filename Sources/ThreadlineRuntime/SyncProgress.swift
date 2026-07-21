import Foundation

public enum SyncProgressPhase: String, Sendable, Hashable {
    case preparing
    case receiving
    case applying
    case sending
    case finalizing
    case completed
}

public struct SyncProgress: Sendable, Hashable {
    public let runID: UUID
    public let phase: SyncProgressPhase
    public let source: String
    public let destination: String
    public let completedItemCount: Int
    public let totalItemCount: Int?
    public let completedByteCount: Int64
    public let totalByteCount: Int64?
    public let activity: String
    public let startedAt: Date
    public let updatedAt: Date
    public let lastAdvancedAt: Date

    public init(
        runID: UUID,
        phase: SyncProgressPhase,
        source: String,
        destination: String,
        completedItemCount: Int = 0,
        totalItemCount: Int? = nil,
        completedByteCount: Int64 = 0,
        totalByteCount: Int64? = nil,
        activity: String,
        startedAt: Date,
        updatedAt: Date = Date(),
        lastAdvancedAt: Date? = nil
    ) {
        self.runID = runID
        self.phase = phase
        self.source = source
        self.destination = destination
        self.completedItemCount = completedItemCount
        self.totalItemCount = totalItemCount
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
        self.activity = activity
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastAdvancedAt = lastAdvancedAt ?? updatedAt
    }

    public var fractionCompleted: Double? {
        guard let totalItemCount, totalItemCount > 0 else { return nil }
        return min(1, max(0, Double(completedItemCount) / Double(totalItemCount)))
    }
}
