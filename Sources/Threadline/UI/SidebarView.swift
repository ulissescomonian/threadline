import ConversationCore
import SwiftUI
import ThreadlineRuntime

struct SidebarView: View {
    @Bindable var model: AppModel

    private struct Destination: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let selection: AppModel.SidebarSelection
        var badge: Int?
        var tint: Color = .accentColor
        var provider: ProviderKind?
    }

    private var library: [Destination] {
        [
            Destination(id: "all", title: "All Conversations", symbol: "bubble.left.and.bubble.right", selection: .all, badge: model.totalConversationCount),
            Destination(id: "favorites", title: "Favorites", symbol: "star", selection: .favorites),
        ]
    }

    private var providers: [Destination] {
        [
            Destination(id: "codex", title: "Codex", symbol: ProviderKind.codex.symbolName, selection: .codex, tint: ProviderKind.codex.tint, provider: .codex),
            Destination(id: "claude", title: "Claude Code", symbol: ProviderKind.claude.symbolName, selection: .claude, tint: ProviderKind.claude.tint, provider: .claude),
        ]
    }

    private var system: [Destination] {
        let attentionCount = model.health.actionableIssues.count
            + (model.automaticReconciliationError == nil ? 0 : 1)
        return [
            Destination(
                id: "attention",
                title: "Needs Attention",
                symbol: "exclamationmark.triangle",
                selection: .attention,
                badge: attentionCount == 0 ? nil : attentionCount,
                tint: attentionCount > 0 ? .orange : .secondary
            ),
        ]
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                ForEach(library) { destinationRow($0) }
            }

            Section("Providers") {
                ForEach(providers) { destinationRow($0) }
            }

            Section("Continuity") {
                ForEach(system) { destinationRow($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Threadline")
        .navigationSplitViewColumnWidth(min: 190, ideal: ThreadlineTheme.sidebarWidth, max: 280)
        .onChange(of: model.sidebarSelection) {
            Task { await model.reloadCurrentView() }
        }
        .safeAreaInset(edge: .bottom) {
            SyncSummaryView(
                health: model.health,
                isSyncing: model.isSyncing,
                progress: model.syncProgress,
                lastSuccessfulSyncAt: model.lastSuccessfulSyncAt,
                automaticReconciliationError: model.automaticReconciliationError
            )
                .padding(10)
        }
    }

    private var selectionBinding: Binding<AppModel.SidebarSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { selection in
                if let selection { model.sidebarSelection = selection }
            }
        )
    }

    private func destinationRow(_ destination: Destination) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(destination.title)
                Spacer(minLength: 4)
                if let badge = destination.badge, badge > 0 {
                    Text(badge, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            if let provider = destination.provider {
                ProviderIcon(provider: provider, size: 14)
            } else {
                Image(systemName: destination.symbol)
                    .foregroundStyle(destination.tint)
            }
        }
        .tag(destination.selection)
        .accessibilityLabel(destination.title)
    }
}

private struct SyncSummaryView: View {
    let health: HealthSnapshot
    let isSyncing: Bool
    let progress: SyncProgress?
    let lastSuccessfulSyncAt: Date?
    let automaticReconciliationError: String?

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(syncTitle)
                    .font(.caption.weight(.semibold))
                Text(statusSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if automaticReconciliationError != nil { return .orange }
        if health.hasActionableIssues { return .orange }
        if health.pendingObjectCount > 0 { return .orange }
        return health.cloudAvailable ? .green : .secondary
    }

    private var statusSymbol: String {
        if automaticReconciliationError != nil { return "exclamationmark" }
        if health.hasActionableIssues { return "exclamationmark" }
        if health.pendingObjectCount > 0 { return "clock.arrow.circlepath" }
        return health.cloudAvailable ? "checkmark" : "icloud.slash"
    }

    private var statusTitle: String {
        if automaticReconciliationError != nil { return "Needs attention" }
        if health.hasActionableIssues { return "Needs attention" }
        if health.pendingObjectCount > 0 { return "Waiting to sync" }
        return health.cloudAvailable ? "Up to date" : "Local library"
    }

    private var statusSubtitle: String {
        if isSyncing {
            return progress?.threadlineCompactDetail ?? "Preparing sync"
        }
        if automaticReconciliationError != nil {
            return "Will retry automatically"
        }
        if health.pendingObjectCount > 0 {
            return "\(health.pendingObjectCount) item\(health.pendingObjectCount == 1 ? "" : "s") • Automatic sync enabled"
        }
        if let date = lastSuccessfulSyncAt { return "Synced \(date.threadlineRelative)" }
        return "Not synced yet"
    }

    private var syncTitle: String {
        guard isSyncing else { return statusTitle }
        return progress?.phase.threadlineTitle ?? "Preparing sync"
    }
}
