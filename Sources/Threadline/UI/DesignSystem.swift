import AppKit
import ConversationCore
import SwiftUI

enum ThreadlineTheme {
    static let sidebarWidth: CGFloat = 220
    static let listWidth: CGFloat = 320
    static let transcriptWidth: CGFloat = 680
    static let cornerRadius: CGFloat = 12

    static let accent = Color(red: 0.26, green: 0.45, blue: 0.96)
    static let codex = Color(red: 0.16, green: 0.60, blue: 0.46)
    static let claude = Color(red: 0.82, green: 0.43, blue: 0.25)
}

extension ProviderKind {
    var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .codex: ThreadlineTheme.codex
        case .claude: ThreadlineTheme.claude
        }
    }

    fileprivate var iconResources: [(name: String, fileExtension: String)] {
        switch self {
        case .codex: [("codex", "svg")]
        case .claude: [("claude-code", "svg")]
        }
    }
}

extension HealthSnapshot {
    /// Only diagnostics that require a user decision or recovery step belong
    /// in Needs Attention. Background transfer backlog is intentionally not
    /// part of this collection.
    var actionableIssues: [HealthIssue] {
        issues.filter(\.isActionable)
    }

    var hasActionableIssues: Bool {
        !actionableIssues.isEmpty
    }
}

extension HealthIssue {
    var isActionable: Bool {
        severity != .info || normalizedRecoverySuggestion != nil
    }

    var normalizedRecoverySuggestion: String? {
        guard let recoverySuggestion else { return nil }
        let normalized = recoverySuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    var fallbackRecoverySuggestion: String {
        normalizedRecoverySuggestion ?? "Refresh the library. If the problem remains, try syncing again."
    }
}

extension ConversationStatus {
    var label: String {
        switch self {
        case .active: "Active"
        case .idle: "Idle"
        case .archived: "Archived"
        case .divergent: "Divergent"
        case .unavailable: "Unavailable"
        }
    }

    var tint: Color {
        switch self {
        case .active: .green
        case .idle: .secondary
        case .archived: .secondary
        case .divergent: .orange
        case .unavailable: .red
        }
    }
}

extension SyncAvailability {
    var label: String {
        switch self {
        case .localOnly: "On this Mac"
        case .queued: "Waiting to sync"
        case .uploaded: "Sent to sync space"
        case .availableOffline: "Available offline"
        case .acknowledged: "Stored in sync space"
        case .blocked: "Sync blocked"
        case .divergent: "Has branches"
        }
    }

    var symbolName: String {
        switch self {
        case .localOnly: "macbook"
        case .queued: "clock.arrow.circlepath"
        case .uploaded: "icloud.and.arrow.up"
        case .availableOffline: "checkmark.icloud"
        case .acknowledged: "checkmark.circle.fill"
        case .blocked: "exclamationmark.icloud"
        case .divergent: "arrow.triangle.branch"
        }
    }

    var tint: Color {
        switch self {
        case .acknowledged, .availableOffline: .green
        case .queued, .uploaded: ThreadlineTheme.accent
        case .blocked: .red
        case .divergent: .orange
        case .localOnly: .secondary
        }
    }

    var explanation: String {
        switch self {
        case .localOnly: "This conversation is stored only on this Mac."
        case .queued: "This conversation is waiting to be uploaded."
        case .uploaded: "The encrypted conversation was sent to the configured sync space."
        case .availableOffline: "A local copy is available without a network connection."
        case .acknowledged: "The encrypted conversation is stored in the configured sync space. This does not confirm that another Mac has downloaded it."
        case .blocked: "Threadline could not continue synchronizing this conversation."
        case .divergent: "More than one continuation of this conversation was detected."
        }
    }
}

extension EventKind {
    var title: String {
        switch self {
        case .userMessage: "You"
        case .assistantMessage: "Assistant"
        case .systemMessage: "System"
        case .command: "Command"
        case .toolCall: "Tool call"
        case .toolResult: "Tool result"
        case .fileChange: "File change"
        case .diff: "Diff"
        case .attachment: "Attachment"
        case .subagent: "Subagent"
        case .compaction: "Context compacted"
        case .lifecycle: "Session event"
        case .error: "Error"
        case .unknown: "Event"
        }
    }

    var symbolName: String {
        switch self {
        case .userMessage: "person.fill"
        case .assistantMessage: "sparkles"
        case .systemMessage: "gearshape.fill"
        case .command: "terminal.fill"
        case .toolCall: "wrench.and.screwdriver.fill"
        case .toolResult: "checkmark.square.fill"
        case .fileChange: "doc.badge.gearshape"
        case .diff: "plus.forwardslash.minus"
        case .attachment: "paperclip"
        case .subagent: "person.2.fill"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .lifecycle: "waveform.path.ecg"
        case .error: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct ProviderBadge: View {
    let provider: ProviderKind
    var showName = true

    var body: some View {
        Label {
            if showName {
                Text(provider.displayName)
            }
        } icon: {
            ProviderIcon(provider: provider, size: 11)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(provider.tint)
        .padding(.horizontal, showName ? 8 : 6)
        .padding(.vertical, 4)
        .background(provider.tint.opacity(0.12), in: Capsule())
        .accessibilityLabel(provider.displayName)
    }
}

/// Brand-aware provider mark. Production bundles keep the supplied SVG glyphs
/// in `ProviderIcons/`. Debug builds may also resolve assets relative to their
/// runtime working directory; no compile-time workstation path is embedded in
/// production binaries. SF Symbols remain the deliberate final fallback.
struct ProviderIcon: View {
    let provider: ProviderKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = ProviderIconLoader.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: provider.symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(provider.tint)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(provider.tint)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum ProviderIconLoader {
    static func image(for provider: ProviderKind) -> NSImage? {
        for resource in provider.iconResources {
            let name = resource.name
            let fileExtension = resource.fileExtension
            if let image = NSImage(named: name) {
                return templateCopy(of: image)
            }

            for directory in ["ProviderIcons", "Resources/ProviderIcons"] {
                if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: directory),
                   let image = NSImage(contentsOf: url) {
                    return templateCopy(of: image)
                }
            }

            #if DEBUG
            let sourceURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(
                "Sources/Threadline/Resources/ProviderIcons/\(name).\(fileExtension)"
            )
            if let image = NSImage(contentsOf: sourceURL) { return templateCopy(of: image) }
            #endif
        }
        return nil
    }

    private static func templateCopy(of image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = true
        return copy
    }
}

struct DiagnosticIssueCard: View {
    let issue: HealthIssue
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(issue.title)
                    .font(.subheadline.weight(.semibold))
                Text(issue.detail)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text(issue.fallbackRecoverySuggestion)
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 11 : 13)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.1))
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch issue.severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch issue.severity {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

struct StatusPill: View {
    let availability: SyncAvailability

    var body: some View {
        Label(availability.label, systemImage: availability.symbolName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(availability.tint)
            .lineLimit(1)
            .help(availability.explanation)
            .accessibilityLabel("Sync status: \(availability.label). \(availability.explanation)")
    }
}

struct KeyValuePill: View {
    let icon: String
    let value: String

    var body: some View {
        Label(value, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }
}

extension Date {
    var threadlineRelative: String {
        formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}
