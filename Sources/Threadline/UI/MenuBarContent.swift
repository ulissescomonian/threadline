import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    let openMainWindow: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if model.health.pendingObjectCount > 0 {
                Label(pendingItemsLabel, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let automaticError = model.automaticReconciliationError {
                VStack(alignment: .leading, spacing: 2) {
                    Label(automaticError, systemImage: "exclamationmark.triangle.fill")
                        .lineLimit(3)
                    Text("Threadline will retry automatically.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.syncNow() }
            }
            .disabled(model.isReconciliationBusy)
            .help("Sync Now runs as soon as possible")

            Button("Refresh Library", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .disabled(model.isLoading || model.isReconciliationBusy)

            Divider()

            Button("Open Threadline", systemImage: "rectangle.on.rectangle") {
                openMainWindow()
            }
            .keyboardShortcut("o")

            Button("Settings…", systemImage: "gearshape") {
                openSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit Threadline", systemImage: "power") {
                quit()
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
        .task { await model.start() }
        .onAppear {
            // The login helper may have imported or synchronized while the UI
            // was closed. Refresh only its durable status when the popover is
            // presented; provider scanning remains an explicit action.
            Task { await model.refreshStatus() }
        }
    }

    private var statusColor: Color {
        if model.automaticReconciliationError != nil
            || model.health.hasActionableIssues
            || model.health.pendingObjectCount > 0 { return .orange }
        return model.health.cloudAvailable ? .green : .secondary
    }

    private var statusSymbol: String {
        if model.automaticReconciliationError != nil { return "exclamationmark.triangle.fill" }
        if model.health.hasActionableIssues { return "exclamationmark.triangle.fill" }
        if model.health.pendingObjectCount > 0 { return "clock.arrow.circlepath" }
        return model.health.cloudAvailable ? "checkmark.circle.fill" : "icloud.slash"
    }

    private var statusTitle: String {
        if model.isSyncing { return model.syncProgress?.phase.threadlineTitle ?? "Preparing sync" }
        if model.automaticReconciliationError != nil { return "Needs attention" }
        if model.health.hasActionableIssues { return "Needs attention" }
        if model.health.pendingObjectCount > 0 { return "Waiting to sync" }
        return model.health.cloudAvailable ? "Up to date" : "Local library"
    }

    private var statusDetail: String {
        if model.isSyncing {
            return model.syncProgress?.threadlineCompactDetail ?? "Waiting for progress details"
        }
        if model.automaticReconciliationError != nil {
            return "Will retry automatically"
        }
        if model.health.pendingObjectCount > 0 {
            return "Automatic sync enabled"
        }
        if let lastSync = model.lastSuccessfulSyncAt { return "Last sync \(lastSync.threadlineRelative)" }
        return "No completed sync yet"
    }

    private var pendingItemsLabel: String {
        let count = model.health.pendingObjectCount
        return "\(count) item\(count == 1 ? "" : "s") safely queued"
    }
}
