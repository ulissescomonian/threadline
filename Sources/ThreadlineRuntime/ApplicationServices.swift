import ConversationCore
import CryptoKit
import Foundation
import ProviderKit

public struct LocalLibrarySnapshot: Sendable {
    public let conversations: [ConversationSummary]
    public let health: HealthSnapshot

    public init(conversations: [ConversationSummary], health: HealthSnapshot) {
        self.conversations = conversations
        self.health = health
    }
}

public struct IngestionProgress: Sendable, Equatable {
    public let provider: ProviderKind
    public let committedConversationCount: Int

    public init(provider: ProviderKind, committedConversationCount: Int) {
        self.provider = provider
        self.committedConversationCount = committedConversationCount
    }
}

enum ThreadlineKeychainStoreFactory {
    static let canonicalAccessGroupSuffix = "com.ulisses.threadline.shared"

    static func resolvedAccessGroup(entitledAccessGroups: [String]?) -> String? {
        KeychainAccessGroupPolicy.resolvedAccessGroup(
            canonicalSuffix: canonicalAccessGroupSuffix,
            entitledAccessGroups: entitledAccessGroups
        )
    }

    static func makeSynchronizableStore() throws -> KeychainKeyMaterialStore {
        let accessGroup = KeychainAccessGroupPolicy.currentProcessResolvedAccessGroup(
            canonicalSuffix: canonicalAccessGroupSuffix
        )
        guard let accessGroup else {
            return KeychainKeyMaterialStore(synchronizable: true)
        }
        return try KeychainKeyMaterialStore(
            synchronizable: true,
            accessGroup: accessGroup
        )
    }

    /// Compatibility store for builds that persisted the synchronizable key
    /// before Threadline selected its shared access group explicitly.
    static func makeLegacySynchronizableStore() -> KeychainKeyMaterialStore {
        KeychainKeyMaterialStore(synchronizable: true)
    }
}

enum ThreadlineDatabaseTarget: Equatable {
    case main
    case staging
}

enum CloudKeyDatabaseSafetyPolicy {
    static func databaseTarget(
        cloudKitAuthorized: Bool,
        remoteManifestVerified: Bool,
        winningKeyResolvedAndPersisted: Bool
    ) -> ThreadlineDatabaseTarget {
        guard cloudKitAuthorized else { return .main }
        guard remoteManifestVerified, winningKeyResolvedAndPersisted else {
            return .staging
        }
        return .main
    }
}

public actor ApplicationServices {
    public nonisolated let store: any ConversationStore
    public nonisolated let configuration: RuntimeConfiguration
    public nonisolated let deviceID: String
    public nonisolated let deviceRegistry: any DeviceRegistry

    private let providers: ProviderRegistry
    private let transport: any SyncTransport
    private let remoteSyncConfigured: Bool
    private let transportDisplayName: String
    private let syncConfigurationStore: SyncConfigurationStore
    private let folderAccess: ScopedFolderAccess?
    private var syncCursor: SyncCursor
    private var runtimeIssues: [HealthIssue] = []
    private var syncInProgress = false

    private static let ingestionOverlap: TimeInterval = 2
    private static let syncKeyService = "com.ulisses.threadline.sync"

    struct KeyBootstrapResolution {
        let key: Data
        let cloudReady: Bool
        let reason: String?
        let usesStagingDatabase: Bool

        init(
            key: Data,
            reason: String?,
            cloudKitAuthorized: Bool,
            remoteManifestVerified: Bool,
            winningKeyResolvedAndPersisted: Bool
        ) {
            self.key = key
            cloudReady = cloudKitAuthorized
                && remoteManifestVerified
                && winningKeyResolvedAndPersisted
            self.reason = reason
            usesStagingDatabase = CloudKeyDatabaseSafetyPolicy.databaseTarget(
                cloudKitAuthorized: cloudKitAuthorized,
                remoteManifestVerified: remoteManifestVerified,
                winningKeyResolvedAndPersisted: winningKeyResolvedAndPersisted
            ) == .staging
        }

        static func localOnly(key: Data, reason: String?) -> Self {
            Self(
                key: key,
                reason: reason,
                cloudKitAuthorized: false,
                remoteManifestVerified: false,
                winningKeyResolvedAndPersisted: false
            )
        }

        static func confirmedCloud(key: Data) -> Self {
            Self(
                key: key,
                reason: nil,
                cloudKitAuthorized: true,
                remoteManifestVerified: true,
                winningKeyResolvedAndPersisted: true
            )
        }

        static func unconfirmedCloud(key: Data, reason: String) -> Self {
            Self(
                key: key,
                reason: reason,
                cloudKitAuthorized: true,
                remoteManifestVerified: false,
                winningKeyResolvedAndPersisted: false
            )
        }
    }

    public static func makeDefault(
        configuration: RuntimeConfiguration? = nil,
        masterKeyProvider: MasterKeyProvider? = nil
    ) async throws -> ApplicationServices {
        let configuration = try configuration ?? .systemDefault()
        let deviceID = try DeviceIdentity.loadOrCreate(in: configuration.applicationSupportURL)
        let syncConfigurationStore = SyncConfigurationStore(
            applicationSupportURL: configuration.applicationSupportURL
        )
        let folderConfiguration: ResolvedFolderSyncConfiguration?
        do {
            folderConfiguration = try await syncConfigurationStore.resolvedConfiguration()
        } catch {
            // A missing provider, stale bookmark, or unavailable Keychain item
            // must never prevent the durable local library from opening.
            folderConfiguration = nil
        }
        // CloudKit remains available as an engineering-only compatibility
        // transport, but it must never activate merely because a signature
        // happens to carry old entitlements. Public builds start local-only
        // and remote sync begins only after an explicit folder choice.
        let cloudKitAuthorized = ProcessInfo.processInfo.environment[
            "THREADLINE_ENABLE_CLOUDKIT_SPIKE"
        ] == "1" && CloudKitEntitlementPolicy.currentProcessAuthorizes(
            containerIdentifier: configuration.cloudContainerIdentifier
        )
        let keyResolution: KeyBootstrapResolution
        if let folderConfiguration {
            keyResolution = .localOnly(key: folderConfiguration.keyData, reason: nil)
        } else if !cloudKitAuthorized {
            // The store requires a codec even when synchronization is disabled.
            // This random process-only key satisfies that dependency, but local-
            // only mode never seals, opens, persists, or transports envelopes.
            // Avoiding every Keychain store here also keeps unsigned local builds
            // from blocking startup on a system Keychain request they cannot use.
            let ephemeralKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            keyResolution = .localOnly(
                key: ephemeralKey,
                reason: "Choose a synchronized folder in Settings → Sync."
            )
        } else if let masterKeyProvider {
            let injectedKey = try masterKeyProvider.loadOrCreate()
            keyResolution = .unconfirmedCloud(
                key: injectedKey,
                reason: "The remote sync space was not verified for the supplied encryption key."
            )
        } else {
            let synchronizableStore = try ThreadlineKeychainStoreFactory.makeSynchronizableStore()
            let legacySynchronizableStore = ThreadlineKeychainStoreFactory.makeLegacySynchronizableStore()
            keyResolution = try await resolveCloudKey(
                containerIdentifier: configuration.cloudContainerIdentifier,
                deviceID: deviceID,
                primary: synchronizableStore,
                legacy: legacySynchronizableStore
            )
        }
        let masterKey = keyResolution.key
        let keyFingerprint = SHA256.hash(data: masterKey)
            .map { String(format: "%02x", $0) }
            .joined()
        let codec = try EncryptedEnvelopeCodec(keyData: masterKey)
        let store = try SQLiteConversationStore(
            databaseURL: folderConfiguration == nil && keyResolution.usesStagingDatabase
                ? configuration.applicationSupportURL.appending(path: "Threadline-staging.sqlite")
                : configuration.databaseURL,
            deviceID: deviceID,
            envelopeCodec: codec,
            queuesForSync: folderConfiguration != nil
                || (cloudKitAuthorized && keyResolution.cloudReady)
        )
        try await store.migrate()

        var providerEnvironment = ProcessInfo.processInfo.environment
        providerEnvironment["CODEX_HOME"] = configuration.codexHomeURL.path
        providerEnvironment["CLAUDE_CONFIG_DIR"] = configuration.claudeHomeURL.path
        let environment = ProviderEnvironment(environment: providerEnvironment)
        let providers = ProviderFactory.makeDefault(environment: environment, deviceID: deviceID)
        let transport: any SyncTransport
        let profile = DeviceProfileFactory.make(deviceID: deviceID)
        let deviceRegistry: any DeviceRegistry
        let deviceRegistryCacheURL = configuration.applicationSupportURL
            .appending(path: "device-registry.json")
        let remoteSyncConfigured: Bool
        let transportDisplayName: String
        if let folderConfiguration {
            transport = FolderSyncTransport(
                rootURL: folderConfiguration.access.url,
                manifest: folderConfiguration.manifest,
                currentDeviceID: deviceID
            )
            deviceRegistry = FolderDeviceRegistry(
                profile: profile,
                rootURL: folderConfiguration.access.url,
                keyData: folderConfiguration.keyData,
                keyFingerprint: folderConfiguration.manifest.keyFingerprint,
                cacheURL: deviceRegistryCacheURL
            )
            remoteSyncConfigured = true
            transportDisplayName = folderConfiguration.stored.location.displayName
        } else if cloudKitAuthorized, keyResolution.cloudReady {
            transport = CloudKitSyncTransport(
                containerIdentifier: configuration.cloudContainerIdentifier,
                assetDirectory: configuration.applicationSupportURL.appending(
                    path: "CloudAssets",
                    directoryHint: .isDirectory
                )
            )
            deviceRegistry = CloudKitDeviceRegistry(
                profile: profile,
                containerIdentifier: configuration.cloudContainerIdentifier,
                keyFingerprint: keyFingerprint,
                cacheURL: deviceRegistryCacheURL
            )
            remoteSyncConfigured = true
            transportDisplayName = "iCloud"
        } else {
            let savedSyncSnapshot = await syncConfigurationStore.snapshot()
            let unavailableReason: String
            switch savedSyncSnapshot.connectionState {
            case .requiresReconnect(let detail), .unavailable(let detail):
                unavailableReason = detail
            case .localOnly, .ready, .migrating:
                unavailableReason = keyResolution.reason
                    ?? "Choose a synchronized folder in Settings → Sync."
            }
            transport = DisabledSyncTransport(
                reason: unavailableReason
            )
            deviceRegistry = LocalDeviceRegistry(
                profile: profile,
                cacheURL: deviceRegistryCacheURL,
                reason: unavailableReason
            )
            remoteSyncConfigured = false
            transportDisplayName = "Local Only"
        }
        let cursor = try await store.loadSyncCursor(transportIdentifier: transport.identifier)

        return ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: deviceID,
            providers: providers,
            transport: transport,
            deviceRegistry: deviceRegistry,
            cloudKitAuthorized: cloudKitAuthorized,
            remoteSyncConfigured: remoteSyncConfigured,
            transportDisplayName: transportDisplayName,
            syncConfigurationStore: syncConfigurationStore,
            folderAccess: folderConfiguration?.access,
            syncCursor: cursor
        )
    }

    /// Resolves key material only after reading the remote manifest. A Mac
    /// joining an existing space must never create or promote a different
    /// synchronizable key while iCloud Keychain is still catching up.
    private static func resolveCloudKey(
        containerIdentifier: String,
        deviceID: String,
        primary: any KeyMaterialStore,
        legacy: any KeyMaterialStore
    ) async throws -> KeyBootstrapResolution {
        let fallback = KeychainKeyMaterialStore(synchronizable: false)
        let state = await CloudSyncSpaceBootstrap.inspect(
            containerIdentifier: containerIdentifier
        )

        switch state {
        case .existing(let remoteFingerprint):
            if let matching = matchingExistingKey(
                fingerprint: remoteFingerprint,
                primary: primary,
                recoveryStores: [legacy, fallback]
            ) {
                return matching
            }
            return try stagingKey(
                reason: "Waiting for the encryption key for this Threadline sync space to arrive through iCloud Keychain."
            )

        case .missing:
            let primaryKey = validKey(try? primary.load(
                service: syncKeyService,
                account: "conversation-master-key-v1"
            ))
            let legacyKey = validKey(try? legacy.load(
                service: syncKeyService,
                account: "conversation-master-key-v1"
            ))
            let fallbackKey = validKey(try? fallback.load(
                service: syncKeyService,
                account: "conversation-master-key-v1"
            ))
            let candidate = try primaryKey ?? legacyKey ?? fallbackKey ?? MasterKeyProvider(
                service: syncKeyService,
                account: "conversation-bootstrap-candidate-v1",
                store: KeychainKeyMaterialStore(synchronizable: false)
            ).loadOrCreate()
            let candidateFingerprint = fingerprint(candidate)
            let claimed = await CloudSyncSpaceBootstrap.claim(
                containerIdentifier: containerIdentifier,
                keyFingerprint: candidateFingerprint,
                createdByDeviceID: deviceID
            )
            if case .existing(let winnerFingerprint) = claimed,
               winnerFingerprint == candidateFingerprint {
                do {
                    try primary.save(
                        candidate,
                        service: syncKeyService,
                        account: "conversation-master-key-v1"
                    )
                    return .confirmedCloud(key: candidate)
                } catch {
                    return try stagingKey(
                        reason: "The sync space was created, but iCloud Keychain could not store its encryption key."
                    )
                }
            }
            if case .existing(let winnerFingerprint) = claimed,
               let winner = matchingExistingKey(
                    fingerprint: winnerFingerprint,
                    primary: primary,
                    recoveryStores: [legacy, fallback]
               ) {
                return winner
            }
            let reason: String
            if case .unavailable(let detail) = claimed {
                reason = detail
            } else {
                reason = "Another Mac created the sync space first. Waiting for its encryption key through iCloud Keychain."
            }
            return try stagingKey(reason: reason)

        case .unavailable(let reason):
            return try stagingKey(reason: reason)
        }
    }

    static func matchingExistingKey(
        fingerprint expected: String,
        primary: any KeyMaterialStore,
        recoveryStores: [any KeyMaterialStore]
    ) -> KeyBootstrapResolution? {
        if let key = validKey(try? primary.load(
            service: syncKeyService,
            account: "conversation-master-key-v1"
        )), fingerprint(key) == expected {
            return .confirmedCloud(key: key)
        }
        for recoveryStore in recoveryStores {
            guard let key = validKey(try? recoveryStore.load(
                service: syncKeyService,
                account: "conversation-master-key-v1"
            )), fingerprint(key) == expected else { continue }
            do {
                try primary.save(
                    key,
                    service: syncKeyService,
                    account: "conversation-master-key-v1"
                )
                return .confirmedCloud(key: key)
            } catch {
                continue
            }
        }
        return nil
    }

    private static func stagingKey(reason: String) throws -> KeyBootstrapResolution {
        let key = try MasterKeyProvider(
            service: syncKeyService,
            account: "conversation-staging-key-v1",
            store: KeychainKeyMaterialStore(synchronizable: false)
        ).loadOrCreate()
        return .unconfirmedCloud(key: key, reason: reason)
    }

    private static func validKey(_ key: Data?) -> Data? {
        guard let key, key.count == 32 else { return nil }
        return key
    }

    private static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    public init(
        store: any ConversationStore,
        configuration: RuntimeConfiguration,
        deviceID: String,
        providers: ProviderRegistry,
        transport: any SyncTransport,
        deviceRegistry: (any DeviceRegistry)? = nil,
        cloudKitAuthorized: Bool = false,
        remoteSyncConfigured: Bool? = nil,
        transportDisplayName: String = "Synchronization",
        syncConfigurationStore: SyncConfigurationStore? = nil,
        folderAccess: ScopedFolderAccess? = nil,
        syncCursor: SyncCursor = SyncCursor()
    ) {
        self.store = store
        self.configuration = configuration
        self.deviceID = deviceID
        self.providers = providers
        self.transport = transport
        self.remoteSyncConfigured = remoteSyncConfigured ?? cloudKitAuthorized
        self.transportDisplayName = transportDisplayName
        self.syncConfigurationStore = syncConfigurationStore ?? SyncConfigurationStore(
            applicationSupportURL: configuration.applicationSupportURL
        )
        self.folderAccess = folderAccess
        self.deviceRegistry = deviceRegistry ?? LocalDeviceRegistry(
            profile: DeviceProfileFactory.make(deviceID: deviceID),
            cacheURL: configuration.applicationSupportURL.appending(path: "device-registry.json"),
            reason: "Folder synchronization is not configured for this runtime."
        )
        self.syncCursor = syncCursor
    }

    public func ingestAll(
        onProgress: @escaping @Sendable (IngestionProgress) async -> Void = { _ in }
    ) async throws {
        // Capture every provider's lower and upper bounds before starting any
        // filesystem scan. A provider watermark advances only after all of its
        // fetched conversations have been committed successfully.
        let scanBoundary = Date()
        var providerCursors: [ProviderKind: Date] = [:]
        for kind in ProviderKind.allCases {
            providerCursors[kind] = try await store.loadProviderIngestCursor(provider: kind)
        }
        let snapshot = try await store.healthSnapshot()
        var issues: [HealthIssue] = runtimeIssues.filter { !$0.id.hasPrefix("provider-") }
        let committer = IngestionCommitter(store: store, onProgress: onProgress)
        let conversationStore = store

        try await withThrowingTaskGroup(of: HealthIssue?.self) { group in
            for kind in ProviderKind.allCases {
                guard let adapter = providers.adapter(for: kind) else { continue }
                let since = providerCursors[kind]?.addingTimeInterval(-Self.ingestionOverlap)
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        try await adapter.scanConversations(since: since) { conversation in
                            try await committer.commit(conversation)
                        }
                        // An adapter may finish normally after its sibling has
                        // cancelled the group. Never promote that partial run.
                        try Task.checkCancellation()
                        try await conversationStore.saveProviderIngestCursor(
                            scanBoundary,
                            provider: kind
                        )
                        return nil
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        return HealthIssue(
                            id: "provider-\(kind.rawValue)",
                            severity: .warning,
                            title: "\(kind.displayName) could not be updated",
                            detail: Self.safeProviderFailureDetail(error, provider: kind),
                            recoverySuggestion: "Check the provider installation, then refresh the library again."
                        )
                    }
                }
            }

            do {
                for try await issue in group {
                    if let issue {
                        issues.append(issue)
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
        try Task.checkCancellation()

        let imported = await committer.committedCount
        if imported == 0, snapshot.indexedConversationCount == 0 {
            issues.append(HealthIssue(
                id: "provider-empty-library",
                severity: .info,
                title: "No conversations were imported",
                detail: "Threadline found no readable sessions in the configured sources.",
                recoverySuggestion: "Confirm that Codex or Claude Code already has local history."
            ))
        }
        runtimeIssues = deduplicated(issues)
    }

    /// Reads the already-indexed library without scanning providers or touching
    /// the configured sync transport. The app can render this snapshot immediately, then call
    /// `ingestAll()` in a separate task and reload when ingestion completes.
    public func loadLocalLibrary(
        query: String? = nil,
        provider: ProviderKind? = nil,
        favoritesOnly: Bool = false
    ) async throws -> LocalLibrarySnapshot {
        async let conversations = store.listConversations(
            query: query,
            provider: provider,
            favoritesOnly: favoritesOnly
        )
        async let health = store.healthSnapshot()
        return try await LocalLibrarySnapshot(
            conversations: conversations,
            health: health
        )
    }

    public func syncNow(
        onProgress: @escaping @Sendable (SyncProgress) async -> Void = { _ in }
    ) async throws {
        guard !syncInProgress else {
            throw ThreadlineError.unavailable("A synchronization run is already in progress.")
        }
        let syncLease = try SyncRunLease(
            at: configuration.applicationSupportURL.appending(path: ".sync-run.lock")
        )
        syncInProgress = true
        defer {
            syncInProgress = false
            withExtendedLifetime(syncLease) {}
        }

        let runID = UUID()
        let startedAt = Date()
        let localEndpoint = "This Mac"
        let remoteEndpoint = transportDisplayName
        await onProgress(SyncProgress(
            runID: runID,
            phase: .preparing,
            source: remoteEndpoint,
            destination: localEndpoint,
            activity: "Checking the synchronization space",
            startedAt: startedAt
        ))

        // Registry readiness is an application-level safety barrier. A retired
        // device or mismatched encryption key must not even read from any
        // transport, regardless of which synchronized-folder provider owns it.
        let registrySnapshot = await deviceRegistry.prepareForSync()
        switch registrySnapshot.readiness {
        case .ready:
            break
        case .localOnly(let reason):
            throw ThreadlineError.cloud("Device registration is local-only: \(reason)")
        case .unavailable(let reason):
            throw ThreadlineError.cloud("Device registration is unavailable: \(reason)")
        case .keyMismatch:
            throw ThreadlineError.cloud(
                "This Mac uses a different conversation encryption key and cannot synchronize."
            )
        }
        guard let currentDevice = registrySnapshot.devices.first(where: {
            $0.id == deviceRegistry.currentDeviceID
        }) else {
            throw ThreadlineError.cloud(
                "This Mac is not present in the device registry and cannot synchronize."
            )
        }
        guard !currentDevice.isRetired else {
            throw ThreadlineError.cloud(
                "This Mac is marked as retired and cannot synchronize until it is reactivated."
            )
        }
        guard await transport.healthCheck() else {
            runtimeIssues = deduplicated(runtimeIssues + [HealthIssue(
                id: "sync-unavailable",
                severity: .warning,
                title: "\(transportDisplayName) sync is unavailable",
                detail: "Threadline could not read and write the configured synchronization location.",
                recoverySuggestion: "Open Settings → Sync and reconnect the selected folder."
            )])
            throw ThreadlineError.cloud("The configured synchronization location is unavailable.")
        }

        let initialHealth = try await store.healthSnapshot()
        var receivedItemCount = 0
        var receivedByteCount: Int64 = 0
        var stalledPullAttempts = 0

        // Pull first while local objects are still queued. That preserves the
        // store's ability to recognize two offline continuations and fork them
        // before either branch is accepted by the durable transport. A pull
        // result is deliberately bounded, so keep advancing until the current
        // remote snapshot is drained instead of making a large first sync look
        // complete after only one page.
        while true {
            try Task.checkCancellation()
            let completedBeforePull = receivedItemCount
            let bytesBeforePull = receivedByteCount
            let pulled = try await transport.pull(since: syncCursor) { transportProgress in
                let totalItems = transportProgress.totalItemCount.map {
                    completedBeforePull + $0
                }
                let totalBytes = transportProgress.totalByteCount.map {
                    bytesBeforePull + $0
                }
                await onProgress(SyncProgress(
                    runID: runID,
                    phase: .receiving,
                    source: remoteEndpoint,
                    destination: localEndpoint,
                    completedItemCount: completedBeforePull
                        + transportProgress.completedItemCount,
                    totalItemCount: totalItems,
                    completedByteCount: bytesBeforePull
                        + transportProgress.completedByteCount,
                    totalByteCount: totalBytes,
                    activity: transportProgress.activity == .enumerating
                        ? "Discovering remote items"
                        : "Reading encrypted remote items",
                    startedAt: startedAt
                ))
            }
            let hasUnreadRemoteItems = (pulled.remainingItemCount ?? 0) > 0
                || (pulled.remainingByteCount ?? 0) > 0
            if pulled.envelopes.isEmpty, hasUnreadRemoteItems {
                stalledPullAttempts += 1
                guard stalledPullAttempts < 3 else {
                    throw ThreadlineError.unavailable(
                        "Remote synchronization items remain, but Threadline could not read the next item."
                    )
                }
                await onProgress(SyncProgress(
                    runID: runID,
                    phase: .receiving,
                    source: remoteEndpoint,
                    destination: localEndpoint,
                    completedItemCount: receivedItemCount,
                    totalItemCount: pulled.remainingItemCount.map {
                        receivedItemCount + $0
                    },
                    completedByteCount: receivedByteCount,
                    totalByteCount: nil,
                    activity: "Waiting to retry an unavailable remote item",
                    startedAt: startedAt
                ))
                try await Task.sleep(for: .milliseconds(250 * stalledPullAttempts))
                continue
            }
            stalledPullAttempts = 0
            guard pulled.envelopes.isEmpty || pulled.cursor.token != syncCursor.token else {
                throw ThreadlineError.invalidPayload(
                    "The synchronization transport returned data without advancing its cursor."
                )
            }
            if !pulled.envelopes.isEmpty {
                let pulledBytes = Int64(pulled.envelopes.reduce(0) {
                    $0 + $1.encryptedPayload.count
                })
                await onProgress(SyncProgress(
                    runID: runID,
                    phase: .applying,
                    source: remoteEndpoint,
                    destination: localEndpoint,
                    completedItemCount: receivedItemCount,
                    totalItemCount: receivedItemCount + pulled.envelopes.count
                        + (pulled.remainingItemCount ?? 0),
                    completedByteCount: receivedByteCount,
                    // Transport progress measures encoded bytes on disk while
                    // the store sees decrypted envelope bytes. Do not combine
                    // those different units into a misleading percentage.
                    totalByteCount: nil,
                    activity: "Applying \(pulled.envelopes.count) item(s) to the local index",
                    startedAt: startedAt
                ))
                try await store.applyRemote(pulled.envelopes)
                receivedItemCount += pulled.envelopes.count
                receivedByteCount += pulledBytes
            }
            try await store.saveSyncCursor(
                pulled.cursor,
                transportIdentifier: transport.identifier
            )
            syncCursor = pulled.cursor
            if pulled.envelopes.isEmpty { break }
        }

        // Initial libraries can contain thousands of conversations. Publish
        // them in bounded transport batches, but drain every durable batch in
        // this operation so the status count reaches a truthful steady state.
        var sentItemCount = 0
        var sentByteCount: Int64 = 0
        var sendingTotalItems = initialHealth.pendingObjectCount
        var sendingTotalBytes = initialHealth.pendingByteCount
        await onProgress(SyncProgress(
            runID: runID,
            phase: .sending,
            source: localEndpoint,
            destination: remoteEndpoint,
            completedItemCount: 0,
            totalItemCount: sendingTotalItems,
            completedByteCount: 0,
            totalByteCount: sendingTotalBytes,
            activity: sendingTotalItems == 0
                ? "No local items are waiting to upload"
                : "Preparing local items for upload",
            startedAt: startedAt
        ))
        while true {
            try Task.checkCancellation()
            let pending = try await store.pendingEnvelopes(
                limit: 100,
                maximumBytes: SyncEnvelopeLimits.maximumTransportBatchBytes
            )
            guard !pending.isEmpty else { break }
            let pendingBytes = Int64(pending.reduce(0) { $0 + $1.encryptedPayload.count })
            sendingTotalItems = max(sendingTotalItems, sentItemCount + pending.count)
            sendingTotalBytes = max(sendingTotalBytes, sentByteCount + pendingBytes)
            try await transport.push(pending)
            // This acknowledgement is strictly the durable transport
            // accepting the objects. It is not a destination-device receipt;
            // that requires a separate per-device watermark contract.
            try await store.markEnvelopesAcknowledged(ids: pending.map(\.id))
            sentItemCount += pending.count
            sentByteCount += pendingBytes
            await onProgress(SyncProgress(
                runID: runID,
                phase: .sending,
                source: localEndpoint,
                destination: remoteEndpoint,
                completedItemCount: sentItemCount,
                totalItemCount: sendingTotalItems,
                completedByteCount: sentByteCount,
                totalByteCount: sendingTotalBytes,
                activity: "Uploaded and acknowledged \(sentItemCount) item(s)",
                startedAt: startedAt
            ))
        }
        await onProgress(SyncProgress(
            runID: runID,
            phase: .finalizing,
            source: localEndpoint,
            destination: remoteEndpoint,
            completedItemCount: sentItemCount,
            totalItemCount: sentItemCount,
            completedByteCount: sentByteCount,
            totalByteCount: sentByteCount,
            activity: "Saving the completed synchronization state",
            startedAt: startedAt
        ))
        runtimeIssues.removeAll { $0.id == "sync-unavailable" }
        try await syncConfigurationStore.markSyncSuccessful()
        await onProgress(SyncProgress(
            runID: runID,
            phase: .completed,
            source: localEndpoint,
            destination: remoteEndpoint,
            completedItemCount: sentItemCount,
            totalItemCount: sentItemCount,
            completedByteCount: sentByteCount,
            totalByteCount: sentByteCount,
            activity: "Synchronization completed",
            startedAt: startedAt
        ))
    }

    public func devicesSnapshot(refreshRemote: Bool = false) async -> DeviceRegistrySnapshot {
        if refreshRemote {
            return await deviceRegistry.refresh()
        }
        return await deviceRegistry.cachedSnapshot()
    }

    public func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot {
        await deviceRegistry.renameDevice(id: id, displayName: displayName)
    }

    public func retireDevice(id: String) async -> DeviceRegistrySnapshot {
        await deviceRegistry.retireDevice(id: id)
    }

    public func reactivateCurrentDevice() async -> DeviceRegistrySnapshot {
        await deviceRegistry.reactivateCurrentDevice()
    }

    public func syncConfigurationSnapshot() async -> SyncConfigurationSnapshot {
        await syncConfigurationStore.snapshot()
    }

    public func configureFolderSync(
        location: SyncLocationKind,
        intent: SyncSetupIntent,
        folderURL: URL,
        recoveryKey: String?
    ) async throws -> SyncSetupResult {
        try await syncConfigurationStore.configure(
            location: location,
            intent: intent,
            folderURL: folderURL,
            recoveryKey: recoveryKey,
            deviceID: deviceID
        )
    }

    public func reconnectSyncFolder(_ folderURL: URL) async throws -> SyncConfigurationSnapshot {
        try await syncConfigurationStore.reconnect(folderURL: folderURL)
    }

    public func migrateSync(
        to location: SyncLocationKind,
        folderURL: URL
    ) async throws -> SyncConfigurationSnapshot {
        // A provider migration copies the durable encrypted sync space, not a
        // possibly stale partial snapshot. Reconcile and drain the current
        // transport before switching the locally stored bookmark.
        try await syncNow()
        return try await syncConfigurationStore.migrate(to: location, folderURL: folderURL)
    }

    public func followExistingMigration(
        to location: SyncLocationKind,
        folderURL: URL
    ) async throws -> SyncConfigurationSnapshot {
        try await syncConfigurationStore.followExistingMigration(
            to: location,
            folderURL: folderURL
        )
    }

    public func switchToLocalOnly() async throws -> SyncConfigurationSnapshot {
        try await syncConfigurationStore.disconnect()
        return .localOnly
    }

    public func healthSnapshot() async -> HealthSnapshot {
        do {
            var snapshot = try await store.healthSnapshot()
            let sources = await providers.discoverSources()
            async let transportAvailable = transport.healthCheck()
            async let registrySnapshot = deviceRegistry.cachedSnapshot()
            let (isTransportAvailable, devices) = await (transportAvailable, registrySnapshot)
            let currentDevice = devices.devices.first {
                $0.id == deviceRegistry.currentDeviceID
            }
            let isCurrentDeviceActive = currentDevice.map { !$0.isRetired } ?? false
            let isRegistryReady = devices.readiness == .ready
            snapshot.codexAvailable = sources.contains { $0.provider == .codex && $0.isAvailable }
            snapshot.claudeAvailable = sources.contains { $0.provider == .claude && $0.isAvailable }
            snapshot.cloudAvailable = isTransportAvailable && isRegistryReady && isCurrentDeviceActive
            let deviceIssue = deviceRegistryIssue(snapshot: devices, currentDevice: currentDevice)
            snapshot.issues = deduplicated(
                snapshot.issues + runtimeIssues + [deviceIssue].compactMap { $0 }
            )
            return snapshot
        } catch {
            return HealthSnapshot(issues: [HealthIssue(
                id: "runtime-health",
                severity: .error,
                title: "The library could not be checked",
                detail: Self.safeRuntimeFailureDetail(error),
                recoverySuggestion: "Quit and reopen Threadline. Your original history is not modified."
            )])
        }
    }

    private func deviceRegistryIssue(
        snapshot: DeviceRegistrySnapshot,
        currentDevice: RegisteredDevice?
    ) -> HealthIssue? {
        // Local-only libraries must not live permanently in Needs Attention
        // merely because remote discovery is unavailable by design.
        guard remoteSyncConfigured else { return nil }

        if snapshot.readiness == .keyMismatch {
            return HealthIssue(
                id: "device-registry",
                severity: .error,
                title: "Encryption keys do not match",
                detail: "This Mac has a different conversation encryption key, so synchronization is blocked.",
                recoverySuggestion: "Reconnect the same Threadline sync space and enter its matching recovery key."
            )
        }
        if currentDevice?.isRetired == true {
            return HealthIssue(
                id: "device-registry",
                severity: .warning,
                title: "This Mac is removed from sync",
                detail: "Threadline will keep the local library available but will not read or write cloud changes from this Mac.",
                recoverySuggestion: "Open Settings → Devices and reconnect this Mac to resume cooperative synchronization."
            )
        }

        switch snapshot.readiness {
        case .ready where currentDevice == nil:
            return HealthIssue(
                id: "device-registry",
                severity: .warning,
                title: "This Mac is not registered",
                detail: "The device registry is available, but it does not contain this Threadline installation.",
                recoverySuggestion: "Open Settings → Devices and refresh device discovery."
            )
        case .unavailable(let reason):
            return HealthIssue(
                id: "device-registry",
                severity: .warning,
                title: "Device registration is unavailable",
                detail: reason,
                recoverySuggestion: "Check the selected provider in Settings → Sync, then retry."
            )
        case .localOnly(let reason):
            return HealthIssue(
                id: "device-registry",
                severity: .warning,
                title: "Synchronization is waiting",
                detail: reason,
                recoverySuggestion: "Open Settings → Sync and reconnect the selected folder."
            )
        case .ready, .keyMismatch:
            return nil
        }
    }

    private static func safeProviderFailureDetail(
        _ error: Error,
        provider: ProviderKind
    ) -> String {
        if let providerError = error as? ProviderKitError {
            switch providerError {
            case .executableUnavailable(let path):
                return "The \(URL(fileURLWithPath: path).lastPathComponent) executable is unavailable."
            case .processFailed(let executable, let status, _):
                return "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(status)."
            case .processTimedOut(let executable):
                return "\(URL(fileURLWithPath: executable).lastPathComponent) timed out."
            case .malformedResponse:
                return "\(provider.displayName) returned a response Threadline could not parse."
            case .unreadableSource(let path):
                return "Threadline could not read the configured source \(URL(fileURLWithPath: path).lastPathComponent)."
            }
        }
        return safeRuntimeFailureDetail(error, context: "Import")
    }

    private static func safeRuntimeFailureDetail(
        _ error: Error,
        context: String = "Library check"
    ) -> String {
        if case .database(let detail) = error as? ThreadlineError {
            let marker = "UNIQUE constraint failed:"
            if let markerRange = detail.range(of: marker) {
                let suffix = detail[markerRange.upperBound...]
                let columns = suffix.prefix { character in
                    character.isLetter || character.isNumber || "_., ".contains(character)
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                if !columns.isEmpty {
                    return "\(context) failed because the database rejected duplicate values for \(columns)."
                }
            }
            return "\(context) failed during a local database operation."
        }
        if error is CancellationError {
            return "\(context) was cancelled."
        }
        return "\(context) failed with \(String(reflecting: type(of: error)))."
    }

    private func deduplicated(_ issues: [HealthIssue]) -> [HealthIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert($0.id).inserted }
    }
}

private actor IngestionCommitter {
    private let store: any ConversationStore
    private let onProgress: @Sendable (IngestionProgress) async -> Void
    private(set) var committedCount = 0

    init(
        store: any ConversationStore,
        onProgress: @escaping @Sendable (IngestionProgress) async -> Void
    ) {
        self.store = store
        self.onProgress = onProgress
    }

    func commit(_ conversation: ProviderConversation) async throws {
        try Task.checkCancellation()
        try await store.upsert(conversation)
        committedCount += 1
        await onProgress(IngestionProgress(
            provider: conversation.summary.provider,
            committedConversationCount: committedCount
        ))
    }
}
