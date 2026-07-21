import ConversationCore
import SwiftUI
import ThreadlineRuntime

struct HealthCenterView: View {
    let snapshot: HealthSnapshot
    let isSyncing: Bool
    let syncProgress: SyncProgress?
    let lastSuccessfulSyncAt: Date?
    let isReconciliationBusy: Bool
    let automaticReconciliationError: String?
    let onRefresh: () -> Void
    let onSync: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Health Center")
                        .font(.title2.bold())
                    Text(overallSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        MetricCard(
                            title: "Conversations",
                            value: snapshot.indexedConversationCount.formatted(),
                            detail: "Indexed locally",
                            symbol: "bubble.left.and.bubble.right.fill",
                            tint: ThreadlineTheme.accent
                        )
                        MetricCard(
                            title: "Waiting to Sync",
                            value: snapshot.pendingObjectCount.formatted(),
                            detail: pendingSyncDetail,
                            symbol: "clock.arrow.circlepath",
                            tint: snapshot.pendingObjectCount > 0 ? ThreadlineTheme.accent : .green
                        )
                        MetricCard(
                            title: "Last Import",
                            value: snapshot.lastIngestAt?.threadlineRelative ?? "Not yet",
                            detail: snapshot.lastIngestAt?.formatted(date: .abbreviated, time: .shortened) ?? "Waiting for first scan",
                            symbol: "tray.and.arrow.down.fill",
                            tint: snapshot.lastIngestAt == nil ? .secondary : .green
                        )
                        MetricCard(
                            title: "Last Sync",
                            value: lastSuccessfulSyncAt?.threadlineRelative ?? "Not yet",
                            detail: lastSuccessfulSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "No completed sync yet",
                            symbol: "icloud.fill",
                            tint: snapshot.cloudAvailable ? .blue : .secondary
                        )
                    }

                    if let syncProgress {
                        SyncProgressCard(progress: syncProgress, isActive: isSyncing)
                    } else if isSyncing {
                        SyncProgressPlaceholder()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connections")
                            .font(.headline)
                        HStack(spacing: 10) {
                            ConnectionStatus(title: "Codex", provider: .codex, isAvailable: snapshot.codexAvailable)
                            ConnectionStatus(title: "Claude Code", provider: .claude, isAvailable: snapshot.claudeAvailable)
                            ConnectionStatus(title: "Sync Space", systemSymbol: "arrow.triangle.2.circlepath", isAvailable: snapshot.cloudAvailable)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Diagnostics")
                            .font(.headline)
                        if let automaticReconciliationError {
                            AutomaticReconciliationIssueCard(message: automaticReconciliationError)
                        }
                        if snapshot.actionableIssues.isEmpty && automaticReconciliationError == nil {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("No action needed", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                if snapshot.pendingObjectCount > 0 {
                                    Text("Items are safely queued. Automatic sync is enabled.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                                .foregroundStyle(.green)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        } else if !snapshot.actionableIssues.isEmpty {
                            ForEach(snapshot.actionableIssues) { issue in
                                DiagnosticIssueCard(issue: issue)
                            }
                        }
                    }
                }
                .padding(22)
            }

            Divider()

            HStack {
                Button("Refresh Library", systemImage: "arrow.clockwise", action: onRefresh)
                    .disabled(isReconciliationBusy)
                Spacer()
                Button(isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath", action: onSync)
                    .buttonStyle(.borderedProminent)
                    .disabled(isReconciliationBusy)
                    .help("Sync Now runs as soon as possible")
            }
            .padding(16)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 580, idealHeight: 680)
    }

    private var overallSubtitle: String {
        let count = snapshot.actionableIssues.count + (automaticReconciliationError == nil ? 0 : 1)
        if count > 0 { return "\(count) diagnostic\(count == 1 ? "" : "s") requiring attention" }
        return "Your conversation library is healthy"
    }

    private var pendingSyncDetail: String {
        guard snapshot.pendingObjectCount > 0 else { return "Queue is clear" }
        let bytes = ByteCountFormatter.string(fromByteCount: snapshot.pendingByteCount, countStyle: .file)
        return "\(bytes) • automatic sync enabled"
    }
}

private struct AutomaticReconciliationIssueCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Automatic reconciliation needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Threadline will retry automatically. Sync Now runs as soon as possible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SyncProgressPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Preparing sync").font(.headline)
                Text("Waiting for progress details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.06),
            in: RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Synchronization progress")
        .accessibilityValue("Preparing sync")
    }
}

private struct SyncProgressCard: View {
    let progress: SyncProgress
    let isActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(progress.phase.threadlineTitle, systemImage: phaseSymbol)
                        .font(.headline)
                    Spacer()
                    if let percentage = progress.threadlinePercentage {
                        Text(percentage)
                            .font(.headline.monospacedDigit())
                    }
                }

                Text(progress.threadlineDirection)
                    .font(.subheadline.weight(.medium))

                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Synchronization progress")
                        .accessibilityValue(
                            progress.threadlinePercentage
                                ?? progress.threadlineItemProgress
                        )
                } else if isActive {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Synchronization progress")
                        .accessibilityValue("Total not known")
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(progress.threadlineItemProgress)
                        .monospacedDigit()
                    if let byteProgress = progress.threadlineByteProgress {
                        Text("•")
                        Text(byteProgress).monospacedDigit()
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text(progress.activity)
                        .lineLimit(2)
                    Spacer()
                    Text("Last advanced \(progress.threadlineTimeSinceAdvance(at: context.date))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                Color.accentColor.opacity(0.06),
                in: RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
                    .strokeBorder(Color.accentColor.opacity(0.16))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Synchronization progress")
            .accessibilityValue(progress.threadlineAccessibilityValue(at: context.date))
        }
    }

    private var phaseSymbol: String {
        switch progress.phase {
        case .preparing: "arrow.triangle.2.circlepath"
        case .receiving: "arrow.down.circle"
        case .applying: "internaldrive"
        case .sending: "arrow.up.circle"
        case .finalizing: "checkmark.circle"
        case .completed: "checkmark.circle.fill"
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionStatus: View {
    let title: String
    var provider: ProviderKind?
    var systemSymbol: String?
    let isAvailable: Bool

    init(title: String, provider: ProviderKind? = nil, systemSymbol: String? = nil, isAvailable: Bool) {
        self.title = title
        self.provider = provider
        self.systemSymbol = systemSymbol
        self.isAvailable = isAvailable
    }

    var body: some View {
        HStack(spacing: 8) {
            if let provider {
                ProviderIcon(provider: provider, size: 12)
            } else if let systemSymbol {
                Image(systemName: systemSymbol)
            }
            Text(title)
            Spacer()
            Circle()
                .fill(isAvailable ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(isAvailable ? "Connected" : "Unavailable")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(11)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}
