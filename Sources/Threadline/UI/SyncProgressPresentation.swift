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
        components.append(activity)
        components.append("Last advanced \(threadlineTimeSinceAdvance(at: date))")
        return components.joined(separator: ", ")
    }
}
