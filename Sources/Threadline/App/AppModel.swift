import AppKit
import ConversationCore
import Foundation
import Observation
import OSLog
import ThreadlineRuntime

private actor LatestIngestionProgressBuffer {
    private var latest: IngestionProgress?

    func submit(_ progress: IngestionProgress) {
        latest = progress
    }

    func takeLatest() -> IngestionProgress? {
        defer { latest = nil }
        return latest
    }

    func reset() {
        latest = nil
    }
}

private final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

/// A deliberately separate observation domain for high-frequency ingestion
/// telemetry. Updating this object invalidates only the small progress view
/// that reads it, instead of the navigation split view and transcript.
@MainActor
@Observable
final class IngestionPresentation {
    private(set) var provider: ProviderKind?
    private(set) var processedConversationCount = 0

    fileprivate func reset() {
        provider = nil
        processedConversationCount = 0
    }

    fileprivate func publish(_ progress: IngestionProgress) {
        provider = progress.provider
        processedConversationCount = progress.committedConversationCount
    }
}

@MainActor
@Observable
final class AppModel {
    enum RecoverableAction { case start, reload, refresh, sync }
    enum SidebarSelection: Hashable {
        case all
        case codex
        case claude
        case favorites
        case attention
    }

    var conversations: [ConversationSummary] = []
    var selectedConversationID: String?
    var selectedDetail: ConversationDetail?
    var sidebarSelection: SidebarSelection = .all
    var searchText = ""
    var health = HealthSnapshot()
    var isLoading = false
    var isImporting = false
    var isSyncing = false
    private(set) var syncProgress: SyncProgress?
    var errorMessage: String?
    var deviceSnapshot: DeviceRegistrySnapshot?
    var isLoadingDevices = false
    var deviceError: String?
    var syncConfiguration: SyncConfigurationSnapshot?
    var isLoadingSyncConfiguration = false
    var isChangingSyncConfiguration = false
    var syncConfigurationError: String?
    private(set) var automaticReconciliationError: String?
    var latestRecoveryKey: String?
    private(set) var recoverableAction: RecoverableAction?
    @ObservationIgnored let ingestionPresentation = IngestionPresentation()

    /// Global durable count from SQLite, independent of the active provider,
    /// favorites, attention, or search filter.
    var totalConversationCount: Int {
        health.indexedConversationCount
    }

    /// Written by the runtime only after an entire synchronization succeeds.
    /// Page-level storage timestamps must not be presented as completed syncs.
    var lastSuccessfulSyncAt: Date? {
        syncConfiguration?.lastSuccessfulSyncAt
    }

    var isReconciliationBusy: Bool {
        isImporting
            || isSyncing
            || isChangingSyncConfiguration
    }

    var isConfigurationBusy: Bool {
        isReconciliationBusy || isAutomaticReconciliationRunning
    }

    private var services: ApplicationServices?
    @ObservationIgnored private var libraryRequestGeneration = 0
    @ObservationIgnored private var healthRequestGeneration = 0
    @ObservationIgnored private var detailRequestGeneration = 0
    @ObservationIgnored private var detailRequestID: String?
    @ObservationIgnored private let ingestionProgressBuffer = LatestIngestionProgressBuffer()
    @ObservationIgnored private var ingestionProgressTask: Task<Void, Never>?
    @ObservationIgnored private var syncInvocationID: UUID?
    @ObservationIgnored private var revealedImportQueries: Set<LibraryQuery> = []
    @ObservationIgnored private var automaticReconciliationScheduler: AutomaticReconciliationScheduler?
    @ObservationIgnored private var sourceEventMonitor: FileSystemEventMonitor?
    @ObservationIgnored private var wakeObservation: NotificationObservation?
    private var isAutomaticReconciliationRunning = false

    private static let logger = Logger(
        subsystem: "com.ulisses.threadline",
        category: "automatic-reconciliation"
    )

    /// Progress is useful feedback, but it is not frame-level information.
    /// Publishing at 0.8 Hz keeps VoiceOver and visible status current without
    /// forcing SwiftUI to continuously reconcile views during SQLite writes.
    private static let ingestionProgressPublishInterval = Duration.milliseconds(1_250)

    private struct LibraryQuery: Hashable {
        let text: String?
        let provider: ProviderKind?
        let favoritesOnly: Bool
        let sidebarSelection: SidebarSelection
    }

    private enum ReconciliationStepResult {
        case success
        case failure(String)
        case cancelled

        var failureMessage: String? {
            guard case let .failure(message) = self else { return nil }
            return message
        }
    }

    deinit {
        sourceEventMonitor?.stop()
        let scheduler = automaticReconciliationScheduler
        Task {
            await scheduler?.stop()
        }
    }

    func start() async {
        guard services == nil else { return }
        isLoading = true
        do {
            let services = try await ApplicationServices.makeDefault()
            self.services = services
            syncConfiguration = await services.syncConfigurationSnapshot()
            // The cached registry is cheap and immediately useful. Its selected
            // folder transport is refreshed independently so device discovery
            // never delays the durable library or provider import.
            deviceSnapshot = await services.devicesSnapshot(refreshRemote: false)
            Task { [weak self] in
                await self?.loadDevices(refreshRemote: true)
            }
            // Show the durable local library immediately. Source discovery can
            // take time on large histories and must never block first paint.
            await reload()
            isLoading = false
            await startAutomaticReconciliation(configuration: services.configuration)
        } catch {
            isLoading = false
            recoverableAction = .start
            errorMessage = error.localizedDescription
        }
    }

    func reload(
        refreshSelectedDetail: Bool = false,
        reportErrors: Bool = true
    ) async {
        await loadLibrary(
            refreshHealth: true,
            refreshSelectedDetail: refreshSelectedDetail,
            reportErrors: reportErrors
        )
    }

    /// Reloads the current list/filter without performing status diagnostics.
    /// This is used for UI navigation and search while ingestion may own the
    /// storage actor; explicit refresh/sync operations still request health.
    func reloadCurrentView(refreshSelectedDetail: Bool = false) async {
        await loadLibrary(
            refreshHealth: false,
            refreshSelectedDetail: refreshSelectedDetail,
            reportErrors: true
        )
    }

    /// Refreshes the small status snapshot used by the menu bar without
    /// scanning providers or rebuilding the conversation list.
    func refreshStatus() async {
        guard let services else { return }
        healthRequestGeneration &+= 1
        let generation = healthRequestGeneration
        let snapshot = await services.healthSnapshot()
        let configuration = await services.syncConfigurationSnapshot()
        guard generation == healthRequestGeneration else { return }
        if health != snapshot {
            health = snapshot
        }
        if syncConfiguration != configuration {
            syncConfiguration = configuration
        }
    }

    func selectConversation(
        _ id: String?,
        forceReload: Bool = false,
        reportErrors: Bool = true
    ) async {
        if !forceReload, let id {
            if id == detailRequestID { return }
            if id == selectedConversationID, selectedDetail?.id == id { return }
        } else if !forceReload,
                  selectedConversationID == nil,
                  selectedDetail == nil {
            return
        }

        detailRequestGeneration &+= 1
        let generation = detailRequestGeneration
        if selectedConversationID != id {
            selectedConversationID = id
        }
        guard let id, let services else {
            detailRequestID = nil
            if selectedDetail != nil {
                selectedDetail = nil
            }
            return
        }

        detailRequestID = id
        if let currentDetail = selectedDetail, currentDetail.id != id {
            selectedDetail = nil
        }
        do {
            let detail = try await services.store.conversation(id: id)
            guard generation == detailRequestGeneration,
                  selectedConversationID == id else { return }
            if selectedDetail != detail {
                selectedDetail = detail
            }
            detailRequestID = nil
        } catch {
            guard generation == detailRequestGeneration else { return }
            detailRequestID = nil
            if reportErrors {
                recoverableAction = .reload
                errorMessage = error.localizedDescription
            } else {
                Self.logger.error(
                    "Automatic detail reload failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    func refresh() async {
        guard let services else { return }
        if isAutomaticReconciliationRunning, !isReconciliationBusy {
            await automaticReconciliationScheduler?.request(.sourceChange)
            return
        }
        guard !isReconciliationBusy else { return }
        await prepareIngestionPresentation()
        isImporting = true
        defer { isImporting = false }
        do {
            let progressBuffer = ingestionProgressBuffer
            try await services.ingestAll { progress in
                await progressBuffer.submit(progress)
            }
            await flushPendingIngestionProgress()
            await reload(refreshSelectedDetail: true)
        } catch is CancellationError {
            cancelIngestionProgressPublishing()
            return
        } catch {
            cancelIngestionProgressPublishing()
            recoverableAction = .refresh
            errorMessage = error.localizedDescription
        }
    }

    func syncNow() async {
        guard let services else { return }
        if isAutomaticReconciliationRunning, !isReconciliationBusy {
            await automaticReconciliationScheduler?.request(.sourceChange)
            return
        }
        guard !isReconciliationBusy else { return }
        _ = await synchronize(
            services: services,
            reportErrors: true,
            reloadAfterward: true,
            presentsProgress: true,
            automaticTrigger: nil
        )
    }

    private func synchronize(
        services: ApplicationServices,
        reportErrors: Bool,
        reloadAfterward: Bool,
        presentsProgress: Bool,
        automaticTrigger: AutomaticReconciliationScheduler.Trigger?
    ) async -> ReconciliationStepResult {
        var result = ReconciliationStepResult.success
        let invocationID = presentsProgress ? UUID() : nil
        if let invocationID {
            syncInvocationID = invocationID
            syncProgress = nil
            isSyncing = true
        }
        defer {
            if let invocationID,
               syncInvocationID == invocationID {
                syncInvocationID = nil
                isSyncing = false
            }
        }
        do {
            if let invocationID {
                try await services.syncNow { [weak self] progress in
                    await self?.publishSyncProgress(
                        progress,
                        invocationID: invocationID
                    )
                }
            } else {
                try await services.syncNow()
            }
            if presentsProgress, syncProgress?.phase != .completed {
                syncProgress = nil
            }
            if reloadAfterward {
                await reload(
                    refreshSelectedDetail: true,
                    reportErrors: reportErrors
                )
            }
        } catch is CancellationError {
            if presentsProgress {
                syncProgress = nil
            }
            result = .cancelled
        } catch {
            if presentsProgress {
                syncProgress = nil
            }
            result = .failure(error.localizedDescription)
            if reportErrors {
                recoverableAction = .sync
                errorMessage = error.localizedDescription
            } else {
                Self.logger.notice(
                    "Automatic sync deferred after \(Self.triggerName(automaticTrigger), privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        // Cloud sync can update this Mac's heartbeat or registry readiness.
        // Always reload the durable local snapshot, including after failure.
        let devices = await services.devicesSnapshot(refreshRemote: false)
        if deviceSnapshot != devices {
            deviceSnapshot = devices
        }
        let configuration = await services.syncConfigurationSnapshot()
        if syncConfiguration != configuration {
            syncConfiguration = configuration
        }
        return result
    }

    private func startAutomaticReconciliation(
        configuration: RuntimeConfiguration
    ) async {
        guard automaticReconciliationScheduler == nil else { return }

        let scheduler = AutomaticReconciliationScheduler { [weak self] trigger in
            await self?.performAutomaticReconciliation(trigger)
        }
        automaticReconciliationScheduler = scheduler

        let monitor = FileSystemEventMonitor(
            paths: [
                configuration.codexHomeURL.appending(
                    path: "sessions",
                    directoryHint: .isDirectory
                ).path,
                configuration.codexHomeURL.appending(
                    path: "archived_sessions",
                    directoryHint: .isDirectory
                ).path,
                configuration.claudeHomeURL.appending(
                    path: "projects",
                    directoryHint: .isDirectory
                ).path,
            ]
        ) { [weak scheduler] in
            await scheduler?.request(.sourceChange)
        }
        sourceEventMonitor = monitor

        let notificationCenter = NSWorkspace.shared.notificationCenter
        let wakeToken = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak scheduler] _ in
            Task {
                await scheduler?.request(.wake)
            }
        }
        wakeObservation = NotificationObservation(
            center: notificationCenter,
            token: wakeToken
        )

        monitor.start()
        await scheduler.start()
        Self.logger.info("Automatic reconciliation started")
    }

    private func performAutomaticReconciliation(
        _ trigger: AutomaticReconciliationScheduler.Trigger
    ) async {
        guard await waitForInteractiveOperationToFinish() else { return }
        guard let services else { return }
        isAutomaticReconciliationRunning = true
        defer { isAutomaticReconciliationRunning = false }

        if isImporting || isSyncing || isChangingSyncConfiguration {
            Self.logger.debug(
                "Automatic reconciliation deferred after operation state changed"
            )
            return
        }

        Self.logger.debug(
            "Automatic reconciliation started for \(Self.triggerName(trigger), privacy: .public)"
        )
        let ingestionResult = await performAutomaticIngestion(
            services: services,
            trigger: trigger
        )
        if let ingestionFailure = ingestionResult.failureMessage {
            updateAutomaticReconciliationError(
                "Automatic import failed: \(ingestionFailure)"
            )
        }
        guard !Task.isCancelled else { return }
        if case .cancelled = ingestionResult { return }
        let syncResult = await synchronize(
            services: services,
            reportErrors: false,
            reloadAfterward: false,
            presentsProgress: false,
            automaticTrigger: trigger
        )
        if case .cancelled = syncResult { return }
        let failures = [
            ingestionResult.failureMessage.map { "Automatic import failed: \($0)" },
            syncResult.failureMessage.map { "Automatic sync failed: \($0)" },
        ].compactMap { $0 }
        updateAutomaticReconciliationError(
            failures.isEmpty ? nil : failures.joined(separator: "\n")
        )
        await reload(refreshSelectedDetail: true, reportErrors: false)
        Self.logger.debug(
            "Automatic reconciliation finished for \(Self.triggerName(trigger), privacy: .public)"
        )
    }

    private func waitForInteractiveOperationToFinish() async -> Bool {
        var reportedWaiting = false
        while isImporting || isSyncing || isChangingSyncConfiguration {
            if !reportedWaiting {
                Self.logger.debug(
                    "Automatic reconciliation waiting for an active operation"
                )
                reportedWaiting = true
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func performAutomaticIngestion(
        services: ApplicationServices,
        trigger: AutomaticReconciliationScheduler.Trigger
    ) async -> ReconciliationStepResult {
        do {
            try await services.ingestAll()
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            Self.logger.error(
                "Automatic ingestion failed after \(Self.triggerName(trigger), privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .failure(error.localizedDescription)
        }
    }

    private func updateAutomaticReconciliationError(_ message: String?) {
        guard automaticReconciliationError != message else { return }
        automaticReconciliationError = message
    }

    private nonisolated static func triggerName(
        _ trigger: AutomaticReconciliationScheduler.Trigger?
    ) -> String {
        switch trigger {
        case .startup: "startup"
        case .sourceChange: "source-change"
        case .periodic: "periodic"
        case .wake: "wake"
        case nil: "manual"
        }
    }

    private func publishSyncProgress(_ progress: SyncProgress, invocationID: UUID) {
        guard isSyncing, syncInvocationID == invocationID else { return }
        syncProgress = progress
    }

    func toggleFavorite(_ conversation: ConversationSummary) async {
        guard let services else { return }
        do {
            try await services.store.setFavorite(!conversation.isFavorite, conversationID: conversation.id)
            await reloadCurrentView()
        } catch {
            recoverableAction = .reload
            errorMessage = error.localizedDescription
        }
    }

    func loadDevices(refreshRemote: Bool = true) async {
        guard let services, !isLoadingDevices else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        deviceSnapshot = await services.devicesSnapshot(refreshRemote: refreshRemote)
        deviceError = nil
    }

    func renameDevice(_ device: RegisteredDevice, displayName: String) async {
        guard let services else { return }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        deviceSnapshot = await services.renameDevice(id: device.id, displayName: normalizedName)
        deviceError = nil
    }

    func forgetDevice(_ device: RegisteredDevice) async {
        guard let services, device.id != deviceSnapshot?.currentDeviceID else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        deviceSnapshot = await services.retireDevice(id: device.id)
        deviceError = nil
    }

    func reconnectCurrentDevice() async {
        guard let services else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        deviceSnapshot = await services.reactivateCurrentDevice()
        deviceError = nil
    }

    func loadSyncConfiguration() async {
        guard let services, !isLoadingSyncConfiguration else { return }
        isLoadingSyncConfiguration = true
        defer { isLoadingSyncConfiguration = false }
        syncConfiguration = await services.syncConfigurationSnapshot()
    }

    func configureFolderSync(
        location: SyncLocationKind,
        intent: SyncSetupIntent,
        folderURL: URL,
        recoveryKey: String?
    ) async {
        guard let services, canChangeSyncConfiguration else { return }
        isChangingSyncConfiguration = true
        syncConfigurationError = nil
        latestRecoveryKey = nil
        defer { isChangingSyncConfiguration = false }
        do {
            let result = try await services.configureFolderSync(
                location: location,
                intent: intent,
                folderURL: folderURL,
                recoveryKey: recoveryKey
            )
            latestRecoveryKey = result.recoveryKey
            syncConfiguration = result.snapshot
            try await rebuildServicesAfterSyncChange()
        } catch {
            syncConfigurationError = error.localizedDescription
            syncConfiguration = await services.syncConfigurationSnapshot()
        }
    }

    func reconnectSyncFolder(_ folderURL: URL) async {
        guard let services, canChangeSyncConfiguration else { return }
        isChangingSyncConfiguration = true
        syncConfigurationError = nil
        defer { isChangingSyncConfiguration = false }
        do {
            syncConfiguration = try await services.reconnectSyncFolder(folderURL)
            try await rebuildServicesAfterSyncChange()
        } catch {
            syncConfigurationError = error.localizedDescription
        }
    }

    func migrateSync(to location: SyncLocationKind, folderURL: URL) async {
        guard let services, canChangeSyncConfiguration else { return }
        isChangingSyncConfiguration = true
        syncConfigurationError = nil
        defer { isChangingSyncConfiguration = false }
        if let current = syncConfiguration {
            syncConfiguration = SyncConfigurationSnapshot(
                location: current.location,
                connectionState: .migrating,
                folderDisplayName: current.folderDisplayName,
                syncSpaceID: current.syncSpaceID,
                lastSuccessfulSyncAt: current.lastSuccessfulSyncAt
            )
        }
        do {
            syncConfiguration = try await services.migrateSync(
                to: location,
                folderURL: folderURL
            )
            try await rebuildServicesAfterSyncChange()
        } catch {
            syncConfigurationError = error.localizedDescription
            syncConfiguration = await services.syncConfigurationSnapshot()
        }
    }

    func followExistingMigration(to location: SyncLocationKind, folderURL: URL) async {
        guard let services, canChangeSyncConfiguration else { return }
        isChangingSyncConfiguration = true
        syncConfigurationError = nil
        defer { isChangingSyncConfiguration = false }
        if let current = syncConfiguration {
            syncConfiguration = SyncConfigurationSnapshot(
                location: current.location,
                connectionState: .migrating,
                folderDisplayName: current.folderDisplayName,
                syncSpaceID: current.syncSpaceID,
                lastSuccessfulSyncAt: current.lastSuccessfulSyncAt
            )
        }
        do {
            syncConfiguration = try await services.followExistingMigration(
                to: location,
                folderURL: folderURL
            )
            try await rebuildServicesAfterSyncChange()
        } catch {
            syncConfigurationError = error.localizedDescription
            syncConfiguration = await services.syncConfigurationSnapshot()
        }
    }

    func switchToLocalOnly() async {
        guard let services, canChangeSyncConfiguration else { return }
        isChangingSyncConfiguration = true
        syncConfigurationError = nil
        defer { isChangingSyncConfiguration = false }
        do {
            syncConfiguration = try await services.switchToLocalOnly()
            latestRecoveryKey = nil
            try await rebuildServicesAfterSyncChange()
        } catch {
            syncConfigurationError = error.localizedDescription
        }
    }

    func dismissSyncConfigurationError() {
        syncConfigurationError = nil
    }

    private var canChangeSyncConfiguration: Bool {
        !isConfigurationBusy
    }

    private func rebuildServicesAfterSyncChange() async throws {
        syncProgress = nil
        let replacement = try await ApplicationServices.makeDefault()
        services = replacement
        syncConfiguration = await replacement.syncConfigurationSnapshot()
        deviceSnapshot = await replacement.devicesSnapshot(refreshRemote: true)
        await reload(refreshSelectedDetail: true)
    }

    func retryLastAction() async {
        let action = recoverableAction
        errorMessage = nil
        switch action {
        case .start: await start()
        case .reload: await reload()
        case .refresh: await refresh()
        case .sync: await syncNow()
        case nil: break
        }
    }

    private func startIngestionProgressPublishing() {
        guard ingestionProgressTask == nil else { return }
        ingestionProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.ingestionProgressPublishInterval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.publishPendingIngestionProgress()
            }
        }
    }

    private func publishPendingIngestionProgress() async {
        guard let progress = await ingestionProgressBuffer.takeLatest() else { return }
        ingestionPresentation.publish(progress)

        // On an empty installation, reveal one durable batch as soon as the
        // selected provider has committed data. Thereafter keep that list
        // stable and usable until the exact final reload. Existing libraries
        // never need incremental replacement during a background reindex.
        await revealFirstImportBatchIfNeeded(for: progress.provider)
    }

    private func flushPendingIngestionProgress() async {
        cancelIngestionProgressPublishing()
        guard let progress = await ingestionProgressBuffer.takeLatest() else { return }
        ingestionPresentation.publish(progress)
    }

    private func cancelIngestionProgressPublishing() {
        ingestionProgressTask?.cancel()
        ingestionProgressTask = nil
    }

    private func prepareIngestionPresentation() async {
        cancelIngestionProgressPublishing()
        await ingestionProgressBuffer.reset()
        revealedImportQueries.removeAll(keepingCapacity: true)
        ingestionPresentation.reset()
        startIngestionProgressPublishing()
    }

    private func revealFirstImportBatchIfNeeded(for provider: ProviderKind) async {
        guard conversations.isEmpty, searchText.isEmpty else { return }
        let request = libraryQuery()
        guard !revealedImportQueries.contains(request) else { return }

        let providerMatchesSelection = switch request.sidebarSelection {
        case .all: true
        case .codex: provider == .codex
        case .claude: provider == .claude
        case .favorites, .attention: false
        }
        guard providerMatchesSelection else { return }

        // Record before suspension so a coalesced callback cannot enqueue the
        // same query while SQLite is serving this one.
        revealedImportQueries.insert(request)
        await reloadCurrentView()
    }

    private func loadLibrary(
        refreshHealth: Bool,
        refreshSelectedDetail: Bool,
        reportErrors: Bool
    ) async {
        guard let services else { return }
        let request = libraryQuery()
        libraryRequestGeneration &+= 1
        let generation = libraryRequestGeneration
        healthRequestGeneration &+= 1
        let healthGeneration = healthRequestGeneration

        do {
            let loadedConversations = try await services.store.listConversations(
                query: request.text,
                provider: request.provider,
                favoritesOnly: request.favoritesOnly
            )

            let loadedHealth: HealthSnapshot?
            if refreshHealth {
                loadedHealth = await services.healthSnapshot()
            } else {
                loadedHealth = nil
            }

            if !reportErrors {
                let selectionBeforeRefresh = selectedConversationID
                let targetID: String? = if request.sidebarSelection == .attention {
                    nil
                } else if let selectionBeforeRefresh,
                          loadedConversations.contains(where: { $0.id == selectionBeforeRefresh }) {
                    selectionBeforeRefresh
                } else {
                    loadedConversations.first?.id
                }

                let loadedDetail: ConversationDetail?
                if let targetID,
                   refreshSelectedDetail || selectedDetail?.id != targetID {
                    loadedDetail = try await services.store.conversation(id: targetID)
                } else if targetID != nil {
                    loadedDetail = selectedDetail
                } else {
                    loadedDetail = nil
                }

                guard generation == libraryRequestGeneration,
                      request == libraryQuery(),
                      selectedConversationID == selectionBeforeRefresh else { return }

                if conversations != loadedConversations {
                    conversations = loadedConversations
                }
                if let loadedHealth,
                   healthGeneration == healthRequestGeneration,
                   health != loadedHealth {
                    health = loadedHealth
                }
                if selectedConversationID != targetID {
                    selectedConversationID = targetID
                }
                if selectedDetail != loadedDetail {
                    selectedDetail = loadedDetail
                }
                return
            }

            guard generation == libraryRequestGeneration,
                  request == libraryQuery() else { return }

            if conversations != loadedConversations {
                conversations = loadedConversations
            }
            if let loadedHealth,
               healthGeneration == healthRequestGeneration {
                if health != loadedHealth {
                    health = loadedHealth
                }
            }

            if request.sidebarSelection == .attention {
                await selectConversation(nil, reportErrors: reportErrors)
            } else if let selectedConversationID,
                      let summary = loadedConversations.first(where: { $0.id == selectedConversationID }) {
                if refreshSelectedDetail || selectedDetail?.id != selectedConversationID {
                    await selectConversation(
                        selectedConversationID,
                        forceReload: refreshSelectedDetail,
                        reportErrors: reportErrors
                    )
                } else {
                    if selectedDetail?.summary != summary {
                        selectedDetail?.summary = summary
                    }
                }
            } else if let first = loadedConversations.first {
                await selectConversation(first.id, reportErrors: reportErrors)
            } else {
                await selectConversation(nil, reportErrors: reportErrors)
            }
        } catch {
            guard generation == libraryRequestGeneration else { return }
            if reportErrors {
                recoverableAction = .reload
                errorMessage = error.localizedDescription
            } else {
                Self.logger.error(
                    "Automatic library reload failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    private func libraryQuery() -> LibraryQuery {
        let provider: ProviderKind? = switch sidebarSelection {
        case .codex: .codex
        case .claude: .claude
        default: nil
        }
        return LibraryQuery(
            text: searchText.isEmpty ? nil : searchText,
            provider: provider,
            favoritesOnly: sidebarSelection == .favorites,
            sidebarSelection: sidebarSelection
        )
    }
}
