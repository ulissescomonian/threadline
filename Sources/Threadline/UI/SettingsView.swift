import ConversationCore
import SwiftUI
import ThreadlineRuntime

struct ThreadlineSettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @State private var selectedTab: SettingsTab = .general
    @State private var loginItemController = LoginItemController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsPane(
                title: "General",
                subtitle: "Choose how Threadline keeps your library available."
            ) {
                LoginItemSettingsRow(controller: loginItemController)

                SettingsDivider()

                SettingsToggleRow(
                    symbol: "menubar.rectangle",
                    title: "Show in menu bar",
                    detail: "See sync status and run a refresh without opening the app.",
                    isOn: $showMenuBarItem
                )

                SettingsDivider()

                Label {
                    Text("Threadline monitors Codex and Claude Code histories without changing their original files.")
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .accessibilityElement(children: .combine)
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general)

            SyncSettingsView(model: model, isVisible: selectedTab == .sync)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.sync)

            DevicesSettingsPane(model: model, isVisible: selectedTab == .devices)
                .tabItem { Label("Devices", systemImage: "desktopcomputer") }
                .tag(SettingsTab.devices)

            SettingsPane(
                title: "Privacy",
                subtitle: "Local indexing and remote storage use distinct protections."
            ) {
                SettingsExplanation(
                    symbol: "internaldrive",
                    title: "Index stored on this Mac",
                    detail: "The searchable conversation index is stored locally on each Mac."
                )

                SettingsDivider()

                SettingsExplanation(
                    symbol: "lock.shield",
                    title: "Sync content encrypted before it leaves this Mac",
                    detail: "Conversation content is encrypted locally before Threadline writes it to the selected sync location."
                )

                SettingsDivider()

                SettingsExplanation(
                    symbol: "doc.badge.ellipsis",
                    title: "Original histories are read-only",
                    detail: "Threadline reads Codex and Claude Code histories without modifying their source files."
                )
            }
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
            .tag(SettingsTab.privacy)
        }
        .frame(width: 700, height: 570)
        .task {
            loginItemController.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                loginItemController.refresh()
            }
        }
    }
}

private enum SettingsTab: Hashable {
    case general
    case sync
    case devices
    case privacy
}

private struct DevicesSettingsPane: View {
    @Bindable var model: AppModel
    let isVisible: Bool
    @State private var showsAddMac = false
    @State private var renameTarget: RegisteredDevice?
    @State private var forgetTarget: RegisteredDevice?

    private var currentDevice: RegisteredDevice? {
        guard let snapshot = model.deviceSnapshot else { return nil }
        return snapshot.devices.first { $0.id == snapshot.currentDeviceID }
    }

    private var otherDevices: [RegisteredDevice] {
        guard let snapshot = model.deviceSnapshot else { return [] }
        return snapshot.devices
            .filter { $0.id != snapshot.currentDeviceID }
            .sorted { lhs, rhs in
                if lhs.isRetired != rhs.isRetired { return !lhs.isRetired }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Devices")
                        .font(.title2.weight(.semibold))
                    Text("Macs connected to your private Threadline sync space.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await model.loadDevices(refreshRemote: true) }
                } label: {
                    if model.isLoadingDevices {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoadingDevices)
                .help("Refresh device list")

                Button("Add Mac…", systemImage: "plus") {
                    showsAddMac = true
                }
            }
            .padding(.bottom, 14)

            if let snapshot = model.deviceSnapshot {
                DeviceReadinessView(
                    readiness: snapshot.readiness,
                    syncLocation: model.syncConfiguration?.location ?? .local,
                    isRefreshing: model.isLoadingDevices,
                    onRetry: { Task { await model.loadDevices() } }
                )
                .padding(.bottom, 12)
            }

            if let error = model.deviceError {
                InlineDeviceError(message: error) {
                    Task { await model.loadDevices() }
                }
                .padding(.bottom, 12)
            }

            Group {
                if model.deviceSnapshot == nil {
                    deviceLoadingState
                } else {
                    devicesList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .task(id: isVisible) {
            guard isVisible else { return }
            await model.loadDevices(refreshRemote: true)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await model.loadDevices(refreshRemote: true)
            }
        }
        .sheet(isPresented: $showsAddMac) {
            AddMacInstructionsView(
                readiness: model.deviceSnapshot?.readiness,
                configuration: model.syncConfiguration,
                recoveryKey: model.latestRecoveryKey
            )
        }
        .sheet(item: $renameTarget) { device in
            RenameDeviceView(device: device) { name in
                Task { await model.renameDevice(device, displayName: name) }
            }
        }
        .alert(
            forgetTarget.map { "Forget “\($0.displayName)”?" } ?? "Forget This Mac?",
            isPresented: forgetBinding,
            presenting: forgetTarget
        ) { device in
            Button("Forget This Mac", role: .destructive) {
                Task { await model.forgetDevice(device) }
                forgetTarget = nil
            }
            Button("Cancel", role: .cancel) {
                forgetTarget = nil
            }
        } message: { _ in
            Text("Threadline will remove this Mac from cooperative sync. This does not delete data on that Mac or revoke encryption keys already copied to it.")
        }
    }

    private var forgetBinding: Binding<Bool> {
        Binding(
            get: { forgetTarget != nil },
            set: { if !$0 { forgetTarget = nil } }
        )
    }

    @ViewBuilder
    private var deviceLoadingState: some View {
        if model.isLoadingDevices {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading devices…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Device List Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } description: {
                Text("Threadline has not loaded the local device registry yet.")
            } actions: {
                Button("Try Again") {
                    Task { await model.loadDevices() }
                }
            }
        }
    }

    private var devicesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                Text("THIS MAC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let currentDevice {
                    DeviceRow(
                        device: currentDevice,
                        isCurrent: true,
                        isBusy: model.isLoadingDevices,
                        actionsEnabled: true,
                        onRename: { renameTarget = currentDevice },
                        onForget: nil,
                        onReconnect: currentDevice.isRetired && canReconnectCurrentDevice
                            ? { Task { await model.reconnectCurrentDevice() } }
                            : nil
                    )
                } else {
                    Text("This Mac has not been registered yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }

                Text("OTHER MACS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                if otherDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No other Macs yet")
                            .font(.callout.weight(.medium))
                        Text(otherMacsEmptyDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(otherDevices) { device in
                        DeviceRow(
                            device: device,
                            isCurrent: false,
                            isBusy: model.isLoadingDevices,
                            actionsEnabled: otherDeviceActionsEnabled,
                            onRename: { renameTarget = device },
                            onForget: device.isRetired ? nil : { forgetTarget = device },
                            onReconnect: nil
                        )
                    }
                }
            }
            .padding(.trailing, 4)
        }
    }

    private var otherDeviceActionsEnabled: Bool {
        guard let readiness = model.deviceSnapshot?.readiness else { return false }
        if case .ready = readiness { return true }
        return false
    }

    private var otherMacsEmptyDetail: String {
        let location = model.syncConfiguration?.location ?? .local
        if location == .local {
            return "Choose a sync location in Settings → Sync before adding another Mac."
        }
        guard let readiness = model.deviceSnapshot?.readiness else {
            return "Device discovery status is still loading."
        }
        return switch readiness {
        case .ready:
            "On another Mac, join the same Threadline space in \(location.displayName)."
        case .localOnly:
            "This Mac is not connected to the selected Threadline sync space yet."
        case .unavailable:
            "Device discovery is temporarily unavailable. Check \(location.displayName), then retry."
        case .keyMismatch:
            "Enter the recovery key from the Mac that created this sync space."
        }
    }

    private var canReconnectCurrentDevice: Bool {
        guard let readiness = model.deviceSnapshot?.readiness else { return false }
        return switch readiness {
        case .ready, .unavailable:
            true
        case .localOnly, .keyMismatch:
            false
        }
    }
}

private struct DeviceReadinessView: View {
    let readiness: DeviceRegistryReadiness
    let syncLocation: SyncLocationKind
    let isRefreshing: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if shouldOfferRetry {
                Button(isRefreshing ? "Checking…" : "Retry", action: onRetry)
                    .controlSize(.small)
                    .disabled(isRefreshing)
            } else if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch readiness {
        case .ready: "\(syncLocation.displayName) device discovery is ready"
        case .localOnly: "Threadline is working locally"
        case .unavailable: "Device discovery is unavailable"
        case .keyMismatch: "Encryption keys do not match"
        }
    }

    private var detail: String? {
        switch readiness {
        case .ready: "Other Macs connected to this Threadline sync space appear automatically."
        case .localOnly(let reason), .unavailable(let reason): reason
        case .keyMismatch: "This Mac has a different encryption key, so Threadline blocked synchronization to protect the shared library."
        }
    }

    private var symbol: String {
        switch readiness {
        case .ready: "checkmark.icloud"
        case .localOnly: "macbook"
        case .unavailable: "exclamationmark.icloud"
        case .keyMismatch: "key.slash"
        }
    }

    private var tint: Color {
        switch readiness {
        case .ready: .green
        case .localOnly: .secondary
        case .unavailable, .keyMismatch: .orange
        }
    }

    private var shouldOfferRetry: Bool {
        switch readiness {
        case .ready: false
        case .localOnly: false
        case .unavailable, .keyMismatch: true
        }
    }
}

private struct DeviceRow: View {
    let device: RegisteredDevice
    let isCurrent: Bool
    let isBusy: Bool
    let actionsEnabled: Bool
    let onRename: () -> Void
    let onForget: (() -> Void)?
    let onReconnect: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceSymbol)
                .font(.title3)
                .foregroundStyle(device.isRetired ? .secondary : ThreadlineTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.callout.weight(.medium))
                    if isCurrent, device.displayName.caseInsensitiveCompare("This Mac") != .orderedSame {
                        Text("This Mac")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ThreadlineTheme.accent)
                    }
                    if device.isRetired {
                        Text("Removed from sync")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(deviceDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Last seen \(device.lastSeenAt.threadlineRelative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if let onReconnect {
                Button("Reconnect", action: onReconnect)
                    .controlSize(.small)
                    .disabled(isBusy || !actionsEnabled)
            }

            Menu {
                Button("Rename…", systemImage: "pencil", action: onRename)
                if let onForget {
                    Divider()
                    Button("Forget This Mac…", systemImage: "minus.circle", role: .destructive, action: onForget)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy || !actionsEnabled)
            .accessibilityLabel("Actions for \(device.displayName)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private var deviceSymbol: String {
        let model = device.modelIdentifier?.lowercased() ?? ""
        return model.contains("book") ? "laptopcomputer" : "desktopcomputer"
    }

    private var deviceDetail: String {
        var parts: [String] = []
        if let model = device.modelIdentifier, !model.isEmpty { parts.append(model) }
        if !device.systemVersion.isEmpty { parts.append(device.systemVersion) }
        if !device.appVersion.isEmpty { parts.append("Threadline \(device.appVersion)") }
        return parts.joined(separator: " · ")
    }
}

private struct AddMacInstructionsView: View {
    let readiness: DeviceRegistryReadiness?
    let configuration: SyncConfigurationSnapshot?
    let recoveryKey: String?
    @Environment(\.dismiss) private var dismiss

    private var location: SyncLocationKind { configuration?.location ?? .local }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a Mac")
                        .font(.title2.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 15) {
                ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                    InstructionRow(number: index + 1, text: instruction)
                }
            }

            if location != .local,
               let key = recoveryKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RECOVERY KEY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(key)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let discoveryNote {
                Label(discoveryNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var subtitle: String {
        location == .local
            ? "Set up a sync space before connecting another Mac."
            : "Join the same encrypted space in \(location.displayName)."
    }

    private var instructions: [String] {
        guard location != .local else {
            return [
                "Open Settings → Sync on this Mac.",
                "Choose iCloud Drive, OneDrive, or Google Drive and create a sync space.",
                "Save the recovery key, then use Join Existing on the new Mac.",
            ]
        }
        return [
            "Install Threadline on the new Mac.",
            "Open Settings → Sync, choose \(location.displayName), and select Join Existing.",
            "Select the same Threadline sync folder and enter the recovery key from this Mac.",
        ]
    }

    private var discoveryNote: String? {
        guard let readiness else { return nil }
        return switch readiness {
        case .ready:
            nil
        case .localOnly:
            "Finish connecting this Mac to the selected sync space before adding another Mac."
        case .unavailable:
            "Check that the selected folder is available in \(location.displayName), then retry."
        case .keyMismatch:
            "The recovery key must match the key used to create this Threadline sync space."
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(ThreadlineTheme.accent, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RenameDeviceView: View {
    let device: RegisteredDevice
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(device: RegisteredDevice, onSave: @escaping (String) -> Void) {
        self.device = device
        self.onSave = onSave
        _name = State(initialValue: device.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Mac")
                .font(.title3.bold())
            TextField("Mac name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420, height: 160)
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

private struct InlineDeviceError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Try Again", action: onRetry)
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)

            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }
}

private struct LoginItemSettingsRow: View {
    @Bindable var controller: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 14) {
                SettingsIcon(symbol: "arrow.triangle.2.circlepath")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Start Threadline at login")
                        .font(.body.weight(.medium))
                    Text("Threadline opens in menu bar mode when you sign in and refreshes your conversation library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Toggle("Start Threadline at login", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(controller.isChanging || isUnavailable)
            }

            stateDetail
                .padding(.leading, 38)

            if let error = controller.operationError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") {
                        controller.dismissOperationError()
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 9)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.isRequestedEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var isUnavailable: Bool {
        if case .unavailable = controller.state { return true }
        return false
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch controller.state {
        case .enabled:
            LoginItemStatusLabel(
                title: "Starts at login",
                detail: "macOS will open Threadline in menu bar mode when you sign in so it can refresh your library.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .requiresApproval:
            HStack(alignment: .top, spacing: 10) {
                LoginItemStatusLabel(
                    title: "Approval required",
                    detail: "Allow Threadline in System Settings → General → Login Items to open automatically when you sign in.",
                    symbol: "exclamationmark.circle.fill",
                    tint: .orange
                )
                Spacer(minLength: 8)
                Button("Open Login Items") {
                    controller.openSystemSettings()
                }
                .controlSize(.small)
            }
        case .disabled:
            LoginItemStatusLabel(
                title: "Doesn’t start at login",
                detail: "Open Threadline manually to refresh your conversation library.",
                symbol: "pause.circle",
                tint: .secondary
            )
        case .unavailable(let reason):
            HStack(alignment: .top, spacing: 10) {
                LoginItemStatusLabel(
                    title: "Start at login unavailable",
                    detail: reason,
                    symbol: "xmark.circle.fill",
                    tint: .red
                )
                Spacer(minLength: 8)
                Button("Open Login Items") {
                    controller.openSystemSettings()
                }
                .controlSize(.small)
            }
        }
    }
}

private struct LoginItemStatusLabel: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(symbol: symbol)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsExplanation: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(symbol: symbol)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(ThreadlineTheme.accent)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 38)
    }
}
