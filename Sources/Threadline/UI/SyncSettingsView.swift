import SwiftUI
import ThreadlineRuntime

struct SyncSettingsView: View {
    @Bindable var model: AppModel
    let isVisible: Bool

    @State private var selectedLocation: SyncLocationKind = .iCloudDrive
    @State private var setupRequest: SyncSetupRequest?
    @State private var migrationRequest: SyncMigrationRequest?
    @State private var followMigrationRequest: SyncFollowMigrationRequest?
    @State private var recoveryKeyPresentation: RecoveryKeyPresentation?
    @State private var showsLocalOnlyConfirmation = false
    @State private var hasSelectedLocation = false

    private let locations: [SyncLocationKind] = [
        .local, .iCloudDrive, .oneDrive, .googleDrive,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync")
                        .font(.title2.weight(.semibold))
                    Text("Choose where Threadline stores its encrypted sync space.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoadingSyncConfiguration || model.isChangingSyncConfiguration {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(locations, id: \.rawValue) { location in
                    SyncLocationCard(
                        location: location,
                        isSelected: selectedLocation == location,
                        isActive: model.syncConfiguration?.location == location,
                        isRecommended: location == .iCloudDrive
                    ) {
                        hasSelectedLocation = true
                        selectedLocation = location
                    }
                    .disabled(model.isConfigurationBusy)
                }
            }

            SyncSelectionDetail(
                location: selectedLocation,
                configuration: model.syncConfiguration,
                isWorking: model.isConfigurationBusy,
                onCreate: { beginSetup(.create) },
                onJoin: { beginSetup(.join) },
                onReconnect: reconnect,
                onMove: beginMigration,
                onFollowExistingMove: beginFollowingMigration,
                onUseLocalOnly: { showsLocalOnlyConfirmation = true }
            )

            if let error = model.syncConfigurationError {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync configuration needs attention")
                            .font(.caption.weight(.semibold))
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Button("Dismiss") { model.dismissSyncConfigurationError() }
                        Button("Retry") {
                            model.dismissSyncConfigurationError()
                            Task { await model.loadSyncConfiguration() }
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isConfigurationBusy)
                }
                .padding(10)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .task(id: isVisible) {
            guard isVisible else { return }
            await model.loadSyncConfiguration()
            alignSelectionWithConfiguration()
        }
        .onChange(of: model.syncConfiguration?.location) { _, _ in
            alignSelectionWithConfiguration()
        }
        .sheet(item: $setupRequest) { request in
            SyncFolderSetupSheet(
                request: request,
                isWorking: model.isConfigurationBusy
            ) { recoveryKey in
                guard !model.isConfigurationBusy else { return }
                Task {
                    guard !model.isConfigurationBusy else { return }
                    await model.configureFolderSync(
                        location: request.location,
                        intent: request.intent,
                        folderURL: request.folderURL,
                        recoveryKey: recoveryKey
                    )
                    setupRequest = nil
                    await model.loadSyncConfiguration()
                    presentLatestRecoveryKeyIfNeeded(for: request.intent)
                }
            }
        }
        .sheet(item: $migrationRequest) { request in
            SyncMigrationConfirmationSheet(
                request: request,
                isWorking: model.isConfigurationBusy
            ) {
                guard !model.isConfigurationBusy else { return }
                Task {
                    guard !model.isConfigurationBusy else { return }
                    await model.migrateSync(to: request.destination, folderURL: request.folderURL)
                    migrationRequest = nil
                    await model.loadSyncConfiguration()
                }
            }
        }
        .sheet(item: $followMigrationRequest) { request in
            SyncFollowMigrationConfirmationSheet(
                request: request,
                isWorking: model.isConfigurationBusy
            ) {
                guard !model.isConfigurationBusy else { return }
                Task {
                    guard !model.isConfigurationBusy else { return }
                    await model.followExistingMigration(
                        to: request.destination,
                        folderURL: request.folderURL
                    )
                    followMigrationRequest = nil
                    await model.loadSyncConfiguration()
                }
            }
        }
        .sheet(item: $recoveryKeyPresentation) { presentation in
            RecoveryKeySheet(presentation: presentation)
        }
        .alert("Use Local Only?", isPresented: $showsLocalOnlyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Use Local Only") {
                guard !model.isConfigurationBusy else { return }
                Task {
                    guard !model.isConfigurationBusy else { return }
                    await model.switchToLocalOnly()
                    await model.loadSyncConfiguration()
                    selectedLocation = .iCloudDrive
                    hasSelectedLocation = false
                }
            }
            .disabled(model.isConfigurationBusy)
        } message: {
            Text("Threadline will keep the complete library on this Mac and stop using the current sync location. Existing remote files are not deleted.")
        }
    }

    private func alignSelectionWithConfiguration() {
        guard !hasSelectedLocation, let active = model.syncConfiguration?.location else { return }
        // iCloud Drive remains the recommended first selection for a local
        // library, but choosing it never activates sync by itself.
        selectedLocation = active == .local ? .iCloudDrive : active
    }

    private func beginSetup(_ intent: SyncSetupIntent) {
        guard !model.isConfigurationBusy,
              selectedLocation != .local,
              let folder = SyncFolderPicker.chooseFolder(for: selectedLocation, intent: intent)
        else { return }
        setupRequest = SyncSetupRequest(
            location: selectedLocation,
            intent: intent,
            folderURL: folder
        )
    }

    private func reconnect() {
        guard !model.isConfigurationBusy,
              selectedLocation != .local,
              let folder = SyncFolderPicker.chooseFolder(for: selectedLocation, intent: .join)
        else { return }
        Task {
            guard !model.isConfigurationBusy else { return }
            await model.reconnectSyncFolder(folder)
            await model.loadSyncConfiguration()
        }
    }

    private func beginMigration() {
        guard !model.isConfigurationBusy,
              selectedLocation != .local,
              let source = model.syncConfiguration?.location,
              let folder = SyncFolderPicker.chooseFolder(for: selectedLocation, intent: .create)
        else { return }
        migrationRequest = SyncMigrationRequest(
            source: source,
            destination: selectedLocation,
            folderURL: folder
        )
    }

    private func beginFollowingMigration() {
        guard !model.isConfigurationBusy,
              selectedLocation != .local,
              let source = model.syncConfiguration?.location,
              source != .local,
              let folder = SyncFolderPicker.chooseFolder(for: selectedLocation, intent: .join)
        else { return }
        followMigrationRequest = SyncFollowMigrationRequest(
            source: source,
            destination: selectedLocation,
            folderURL: folder
        )
    }

    private func presentLatestRecoveryKeyIfNeeded(for intent: SyncSetupIntent) {
        guard intent == .create,
              let key = model.latestRecoveryKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return }
        recoveryKeyPresentation = RecoveryKeyPresentation(key: key)
    }
}

private struct SyncLocationCard: View {
    let location: SyncLocationKind
    let isSelected: Bool
    let isActive: Bool
    let isRecommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: location.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? ThreadlineTheme.accent : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        if isRecommended {
                            Text("RECOMMENDED")
                                .foregroundStyle(ThreadlineTheme.accent)
                        }
                        if isActive {
                            Text("ACTIVE")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.system(size: 8, weight: .bold))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ThreadlineTheme.accent)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                isSelected ? ThreadlineTheme.accent.opacity(0.09) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? ThreadlineTheme.accent.opacity(0.8) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(location.displayName)\(isRecommended ? ", recommended" : "")\(isActive ? ", active" : "")")
    }
}

private struct SyncSelectionDetail: View {
    let location: SyncLocationKind
    let configuration: SyncConfigurationSnapshot?
    let isWorking: Bool
    let onCreate: () -> Void
    let onJoin: () -> Void
    let onReconnect: () -> Void
    let onMove: () -> Void
    let onFollowExistingMove: () -> Void
    let onUseLocalOnly: () -> Void

    private var isActive: Bool { configuration?.location == location }
    private var hasRemoteLocation: Bool {
        guard let active = configuration?.location else { return false }
        return active != .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.callout.weight(.semibold))
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actions
            }

            if isActive, let folder = configuration?.folderDisplayName, !folder.isEmpty {
                Label(folder, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 33)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var actions: some View {
        if location == .local {
            if !isActive {
                Button("Use Local Only", action: onUseLocalOnly)
                    .controlSize(.small)
                    .disabled(isWorking)
            }
        } else if isActive {
            switch configuration?.connectionState {
            case .requiresReconnect:
                Button("Reconnect…", action: onReconnect)
                    .controlSize(.small)
                    .disabled(isWorking)
            case .migrating:
                EmptyView()
            default:
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Move to Another Folder…", action: onMove)
                        .controlSize(.small)
                        .disabled(isWorking)
                    Button("Follow Existing Move…", action: onFollowExistingMove)
                        .controlSize(.small)
                        .disabled(isWorking)
                }
            }
        } else if hasRemoteLocation {
            VStack(alignment: .trailing, spacing: 6) {
                Button("Move Library…", action: onMove)
                    .controlSize(.small)
                    .disabled(isWorking)
                Button("Follow Existing Move…", action: onFollowExistingMove)
                    .controlSize(.small)
                    .disabled(isWorking)
            }
        } else {
            HStack(spacing: 7) {
                Button("Join Existing…", action: onJoin)
                    .controlSize(.small)
                    .disabled(isWorking)
                Button("Create New…", action: onCreate)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
    }

    private var statusTitle: String {
        if location == .local { return isActive ? "Stored only on this Mac" : "Local only" }
        if !isActive {
            return hasRemoteLocation ? "Move to \(location.displayName)" : "Use \(location.displayName)"
        }
        switch configuration?.connectionState {
        case .ready: return "Connected to \(location.displayName)"
        case .requiresReconnect: return "Folder access required"
        case .unavailable: return "Sync location unavailable"
        case .migrating: return "Moving encrypted library…"
        case .localOnly, nil: return "Not connected"
        }
    }

    private var statusDetail: String {
        if location == .local {
            return "The searchable library remains private on this Mac and no sync folder is used."
        }
        if !isActive {
            return hasRemoteLocation
                ? "Move the encrypted library here from this Mac, or follow a move already completed on another Mac. The current remote copy is not deleted."
                : "Create a new encrypted space or join one that already exists on another Mac."
        }
        switch configuration?.connectionState {
        case .ready:
            return "Threadline writes encrypted data to this folder. It uses the provider’s storage quota, and the provider’s Mac app manages its upload."
        case .requiresReconnect(let reason), .unavailable(let reason):
            return reason
        case .migrating:
            return "Keep Threadline open until the new sync location is ready."
        case .localOnly, nil:
            return "Choose an action to connect this Mac."
        }
    }

    private var statusSymbol: String {
        if !isActive { return location.systemImage }
        return switch configuration?.connectionState {
        case .ready: "checkmark.circle.fill"
        case .requiresReconnect: "folder.badge.questionmark"
        case .unavailable: "exclamationmark.triangle.fill"
        case .migrating: "arrow.triangle.2.circlepath"
        case .localOnly, nil: "internaldrive"
        }
    }

    private var statusTint: Color {
        if !isActive { return ThreadlineTheme.accent }
        return switch configuration?.connectionState {
        case .ready: .green
        case .requiresReconnect, .unavailable: .orange
        case .migrating: ThreadlineTheme.accent
        case .localOnly, nil: .secondary
        }
    }
}
