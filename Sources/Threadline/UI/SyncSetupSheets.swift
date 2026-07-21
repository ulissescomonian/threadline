import AppKit
import SwiftUI
import ThreadlineRuntime

struct SyncSetupRequest: Identifiable {
    let id = UUID()
    let location: SyncLocationKind
    let intent: SyncSetupIntent
    let folderURL: URL
}

struct SyncMigrationRequest: Identifiable {
    let id = UUID()
    let source: SyncLocationKind
    let destination: SyncLocationKind
    let folderURL: URL
}

struct SyncFollowMigrationRequest: Identifiable {
    let id = UUID()
    let source: SyncLocationKind
    let destination: SyncLocationKind
    let folderURL: URL
}

struct RecoveryKeyPresentation: Identifiable {
    let id = UUID()
    let key: String
}

@MainActor
enum SyncFolderPicker {
    static func chooseFolder(
        for location: SyncLocationKind,
        intent: SyncSetupIntent
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = intent == .create
        panel.prompt = intent == .create ? "Choose Folder" : "Join This Space"
        panel.title = intent == .create
            ? "Create a Threadline sync space in \(location.displayName)"
            : "Choose an existing Threadline sync space"
        panel.message = intent == .create
            ? "Choose where Threadline should create its encrypted sync space. The selected folder itself is never replaced."
            : "Select the existing Threadline sync folder shared by your other Mac."
        panel.directoryURL = suggestedDirectory(for: location)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func suggestedDirectory(for location: SyncLocationKind) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        switch location {
        case .local:
            return home
        case .iCloudDrive:
            let iCloudDrive = home.appending(
                path: "Library/Mobile Documents/com~apple~CloudDocs",
                directoryHint: .isDirectory
            )
            return fileManager.fileExists(atPath: iCloudDrive.path) ? iCloudDrive : home
        case .oneDrive, .googleDrive:
            let cloudStorage = home.appending(
                path: "Library/CloudStorage",
                directoryHint: .isDirectory
            )
            guard let children = try? fileManager.contentsOfDirectory(
                at: cloudStorage,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return cloudStorage }
            let needle = location == .oneDrive ? "onedrive" : "google"
            return children.first {
                $0.lastPathComponent.lowercased().contains(needle)
            } ?? cloudStorage
        }
    }
}

struct SyncFolderSetupSheet: View {
    let request: SyncSetupRequest
    let isWorking: Bool
    let onConfirm: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.location.systemImage)
                    .font(.title2)
                    .foregroundStyle(ThreadlineTheme.accent)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.bold())
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LabeledContent("Location") {
                Text(request.folderURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)

            if request.intent == .join {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Recovery key")
                        .font(.callout.weight(.medium))
                    SecureField("Enter the key saved on the first Mac", text: $recoveryKey)
                        .textFieldStyle(.roundedBorder)
                    Text("The key unlocks encrypted conversations locally. It is never stored in the shared folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Threadline will generate a recovery key after creating the space. Save it before adding another Mac.",
                        systemImage: "key.horizontal"
                    )
                    Label(
                        "The encrypted library is stored in this provider and uses its storage quota.",
                        systemImage: "externaldrive.badge.icloud"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                Button(confirmTitle) {
                    onConfirm(request.intent == .join ? normalizedRecoveryKey : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || (request.intent == .join && normalizedRecoveryKey.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var normalizedRecoveryKey: String {
        recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var title: String {
        request.intent == .create ? "Create Sync Space" : "Join Sync Space"
    }

    private var subtitle: String {
        request.intent == .create
            ? "Start a new encrypted Threadline space in \(request.location.displayName)."
            : "Connect this Mac to the selected encrypted Threadline space."
    }

    private var confirmTitle: String {
        if isWorking { return request.intent == .create ? "Creating…" : "Joining…" }
        return request.intent == .create ? "Create Space" : "Join Space"
    }
}

struct SyncMigrationConfirmationSheet: View {
    let request: SyncMigrationRequest
    let isWorking: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move Sync Location?")
                .font(.title3.bold())
            Text("Threadline will copy the complete encrypted sync space to the new location. It uses storage quota there just like the current location.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                migrationRow(label: "FROM", location: request.source, detail: nil)
                Divider().padding(.leading, 44)
                migrationRow(
                    label: "TO",
                    location: request.destination,
                    detail: request.folderURL.lastPathComponent
                )
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Text("Before moving")
                    .font(.callout.weight(.semibold))
                migrationGuidance(
                    "Sync every other Mac, then close Threadline on those Macs before continuing.",
                    symbol: "desktopcomputer.trianglebadge.exclamationmark"
                )
                migrationGuidance(
                    "The destination folder must be empty so it cannot be confused with another library.",
                    symbol: "folder.badge.plus"
                )
                migrationGuidance(
                    "Keep this Mac awake and Threadline open until the copy finishes, then wait for the storage provider to finish uploading before reconnecting other Macs.",
                    symbol: "arrow.up.circle"
                )
                migrationGuidance(
                    "The source is not deleted. Both copies use storage quota until you verify every Mac and remove the old copy yourself.",
                    symbol: "externaldrive.badge.icloud"
                )
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                Button(isWorking ? "Moving…" : "Move Library", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func migrationGuidance(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func migrationRow(
        label: String,
        location: SyncLocationKind,
        detail: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: location.systemImage)
                .foregroundStyle(ThreadlineTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(location.displayName)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(11)
    }
}

struct SyncFollowMigrationConfirmationSheet: View {
    let request: SyncFollowMigrationRequest
    let isWorking: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Follow Existing Move?", systemImage: "arrow.triangle.branch")
                .font(.title3.bold())
                .foregroundStyle(ThreadlineTheme.accent)
            Text("Use this only when another Mac has already moved this same Threadline sync space to the selected folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                followRow(label: "CURRENT LOCATION", location: request.source, detail: nil)
                Divider().padding(.leading, 44)
                followRow(
                    label: "MOVED COPY",
                    location: request.destination,
                    detail: request.folderURL.lastPathComponent
                )
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "This Mac will switch to the already migrated copy. It will not create a new sync space or merge two libraries.",
                    systemImage: "arrow.right.circle"
                )
                Label(
                    "No recovery key is required. Threadline verifies that the selected folder is the same encrypted sync space before switching.",
                    systemImage: "checkmark.shield"
                )
                Label(
                    "Wait until the storage provider has completely downloaded the moved folder on this Mac.",
                    systemImage: "icloud.and.arrow.down"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                Button(isWorking ? "Following…" : "Follow Move", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func followRow(
        label: String,
        location: SyncLocationKind,
        detail: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: location.systemImage)
                .foregroundStyle(ThreadlineTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(location.displayName)
                    .font(.callout.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(11)
    }
}

struct RecoveryKeySheet: View {
    let presentation: RecoveryKeyPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Save Your Recovery Key", systemImage: "key.fill")
                .font(.title3.bold())
                .foregroundStyle(ThreadlineTheme.accent)
            Text("You need this key to join the sync space from another Mac. Threadline cannot recover it for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(presentation.key)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))

            HStack {
                Button(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(presentation.key, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }
}
