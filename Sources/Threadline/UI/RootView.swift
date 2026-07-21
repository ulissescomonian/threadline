import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsHealthCenter = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
        } content: {
            ConversationListView(model: model)
        } detail: {
            TranscriptView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_080, minHeight: 640)
        .tint(ThreadlineTheme.accent)
        .task(priority: .utility) { await model.start() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isLoading || model.isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Library", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoading || model.isReconciliationBusy)
                .keyboardShortcut("r", modifiers: [.command])
                .help("Refresh Library (⌘R)")

                Button {
                    Task { await model.syncNow() }
                } label: {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.isReconciliationBusy)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help(syncButtonHelp)
                .accessibilityLabel(model.isSyncing ? "Synchronization in progress" : "Sync Now")
                .accessibilityValue(model.isSyncing ? (model.syncProgress?.threadlineAccessibilityValue() ?? "Preparing sync") : "")

                Button {
                    showsHealthCenter = true
                } label: {
                    Label("Health Center", systemImage: hasAttention ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(hasAttention ? Color.orange : Color.primary)
                }
                .help("Open Health Center")

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showsHealthCenter) {
            HealthCenterView(
                snapshot: model.health,
                isSyncing: model.isSyncing,
                syncProgress: model.syncProgress,
                lastSuccessfulSyncAt: model.lastSuccessfulSyncAt,
                isReconciliationBusy: model.isReconciliationBusy,
                automaticReconciliationError: model.automaticReconciliationError,
                onRefresh: { Task { await model.refresh() } },
                onSync: { Task { await model.syncNow() } }
            )
        }
        .alert("Threadline Couldn’t Complete That Action", isPresented: errorBinding) {
            Button("Try Again") {
                Task { await model.retryLastAction() }
            }
            .disabled(model.isReconciliationBusy)
            Button("Dismiss", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "An unexpected error occurred.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented { model.errorMessage = nil }
            }
        )
    }

    private var syncButtonHelp: String {
        guard model.isSyncing else {
            return "Sync Now runs as soon as possible (⇧⌘R)"
        }
        guard let progress = model.syncProgress else { return "Preparing sync" }
        return "\(progress.phase.threadlineTitle): \(progress.threadlineCompactDetail)"
    }

    private var hasAttention: Bool {
        model.health.hasActionableIssues || model.automaticReconciliationError != nil
    }
}
