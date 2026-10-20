import Foundation
import ThreadlineRuntime

extension SyncProgressPhase {
    var threadlineTitle: String {
        switch self {
        case .preparing: "Preparing sync"
        case .receiving: "Receiving"
        case .applying: "Applying locally"
        case .sending: "Sending"
        case .finalizing: "Finalizing"
        case .completed: "Sync complete"
        }
    }
}

extension SyncProgress {
    var threadlineDirection: String {
        "\(source) → \(destination)"
    }

    var threadlineItemProgress: String {
        if let totalItemCount {
            return "\(completedItemCount.formatted()) of "
                + "\(totalItemCount.formatted()) items"
        }
        return "\(completedItemCount.formatted()) item\(completedItemCount == 1 ? "" : "s")"
    }

    var threadlineByteProgress: String? {
        guard completedByteCount > 0 || totalByteCount != nil else { return nil }
        let completed = ByteCountFormatter.string(
            fromByteCount: completedByteCount,
            countStyle: .file
        )
        guard let totalByteCount else { return completed }
        let total = ByteCountFormatter.string(
            fromByteCount: totalByteCount,
            countStyle: .file
        )
        return "\(completed) of \(total)"
    }

    var threadlinePercentage: String? {
        fractionCompleted?.formatted(.percent.precision(.fractionLength(0)))
    }

    var threadlineCompactProgress: String {
        threadlinePercentage ?? threadlineItemProgress
    }

    var threadlineCompactDetail: String {
        "\(threadlineDirection) • \(threadlineCompactProgress)"
    }

    var threadlineReceiveSummary: String? {
        guard receivedRecordCount > 0 else { return nil }
        var summary = "\(receivedRecordCount.formatted()) records read"
        if let updatedConversationCount {
            summary += " • \(updatedConversationCount.formatted()) conversations updated"
        }
        if supersededVersionCount > 0 {
            summary += " • \(supersededVersionCount.formatted()) earlier versions consolidated"
        }
        return summary
    }

    var threadlineReceiveTiming: String? {
        guard readingSeconds > 0 || applyingSeconds > 0 else { return nil }
        return "Reading: \(readingSeconds.formatted(.number.precision(.fractionLength(1)))) s"
            + " • Indexing: \(applyingSeconds.formatted(.number.precision(.fractionLength(1)))) s"
    }

    func threadlineTimeSinceAdvance(at date: Date) -> String {
        let interval = max(0, date.timeIntervalSince(lastAdvancedAt))
        if interval < 1 { return "just now" }
        if interval < 60 {
            let seconds = Int(interval)
            return "\(seconds) second\(seconds == 1 ? "" : "s") ago"
        }
        if interval < 3_600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        let hours = Int(interval / 3_600)
        return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    }

    func threadlineAccessibilityValue(at date: Date = Date()) -> String {
        var components = [
            phase.threadlineTitle,
            threadlineDirection,
            threadlineItemProgress,
        ]
        if let byteProgress = threadlineByteProgress { components.append(byteProgress) }
        if let percentage = threadlinePercentage { components.append(percentage) }
        if let summary = threadlineReceiveSummary { components.append(summary) }
        if let timing = threadlineReceiveTiming { components.append(timing) }
        components.append(activity)
        components.append("Last advanced \(threadlineTimeSinceAdvance(at: date))")
        return components.joined(separator: ", ")
    }
}
