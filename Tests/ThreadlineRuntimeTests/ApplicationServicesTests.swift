import ConversationCore
import CryptoKit
import Foundation
import ProviderKit
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class ApplicationServicesTests: XCTestCase {
    func testCloudKeyDatabaseSafetyPolicyRequiresConfirmedRemoteWinner() {
        XCTAssertEqual(
            CloudKeyDatabaseSafetyPolicy.databaseTarget(
                cloudKitAuthorized: true,
                remoteManifestVerified: false,
                winningKeyResolvedAndPersisted: true
            ),
            .staging,
            "CloudKit unavailable must stage even when a local key already exists"
        )
        XCTAssertEqual(
            CloudKeyDatabaseSafetyPolicy.databaseTarget(
                cloudKitAuthorized: true,
                remoteManifestVerified: true,
                winningKeyResolvedAndPersisted: false
            ),
            .staging,
            "A different or unresolved winning fingerprint must stage"
        )
        XCTAssertEqual(
            CloudKeyDatabaseSafetyPolicy.databaseTarget(
                cloudKitAuthorized: true,
                remoteManifestVerified: true,
                winningKeyResolvedAndPersisted: true
            ),
            .main,
            "A verified manifest with its persisted winning key may use main"
        )
        XCTAssertEqual(
            CloudKeyDatabaseSafetyPolicy.databaseTarget(
                cloudKitAuthorized: false,
                remoteManifestVerified: false,
                winningKeyResolvedAndPersisted: false
            ),
            .main,
            "A local-only process continues using the main database"
        )
    }

    func testThreadlineKeychainFactoryRequiresOneCanonicalAccessGroupMatch() {
        XCTAssertNil(ThreadlineKeychainStoreFactory.resolvedAccessGroup(
            entitledAccessGroups: nil
        ))
        XCTAssertNil(ThreadlineKeychainStoreFactory.resolvedAccessGroup(
            entitledAccessGroups: ["TEAMID.com.example.other"]
        ))
        XCTAssertEqual(
            ThreadlineKeychainStoreFactory.resolvedAccessGroup(entitledAccessGroups: [
                "TEAMID.com.example.other",
                "TEAMID.com.ulisses.threadline.shared",
            ]),
            "TEAMID.com.ulisses.threadline.shared"
        )
        XCTAssertNil(ThreadlineKeychainStoreFactory.resolvedAccessGroup(entitledAccessGroups: [
            "FIRST.com.ulisses.threadline.shared",
            "SECOND.com.ulisses.threadline.shared",
        ]))
    }

    func testMatchingLegacyKeyIsPromotedOnlyWhenRemoteFingerprintMatches() throws {
        let primary = InMemoryKeyMaterialStore()
        let legacy = InMemoryKeyMaterialStore()
        let key = Data(repeating: 0x2A, count: 32)
        try legacy.save(
            key,
            service: "com.ulisses.threadline.sync",
            account: "conversation-master-key-v1"
        )
        let fingerprint = SHA256.hash(data: key)
            .map { String(format: "%02x", $0) }
            .joined()

        let resolution = ApplicationServices.matchingExistingKey(
            fingerprint: fingerprint,
            primary: primary,
            recoveryStores: [legacy]
        )

        XCTAssertEqual(resolution?.key, key)
        XCTAssertTrue(resolution?.cloudReady == true)
        XCTAssertEqual(
            try primary.load(
                service: "com.ulisses.threadline.sync",
                account: "conversation-master-key-v1"
            ),
            key
        )

        let unrelatedPrimary = InMemoryKeyMaterialStore()
        let mismatch = ApplicationServices.matchingExistingKey(
            fingerprint: String(repeating: "0", count: 64),
            primary: unrelatedPrimary,
            recoveryStores: [legacy]
        )
        XCTAssertNil(mismatch)
        XCTAssertNil(try unrelatedPrimary.load(
            service: "com.ulisses.threadline.sync",
            account: "conversation-master-key-v1"
        ))
    }

    func testCloudKitPolicyRequiresContainerAndServiceEntitlements() {
        let container = "iCloud.com.ulisses.threadline"

        XCTAssertFalse(CloudKitEntitlementPolicy.authorizes(
            containerIdentifier: container,
            containerIdentifiers: nil,
            services: nil
        ))
        XCTAssertFalse(CloudKitEntitlementPolicy.authorizes(
            containerIdentifier: container,
            containerIdentifiers: [container] as CFArray,
            services: [] as CFArray
        ))
        XCTAssertFalse(CloudKitEntitlementPolicy.authorizes(
            containerIdentifier: container,
            containerIdentifiers: ["iCloud.example.other"] as CFArray,
            services: ["CloudKit"] as CFArray
        ))
        XCTAssertTrue(CloudKitEntitlementPolicy.authorizes(
            containerIdentifier: container,
            containerIdentifiers: [container] as CFArray,
            services: ["CloudKit"] as CFArray
        ))
    }

    func testDefaultBootstrapStaysLocalAndNeverAccessesKeyStoreWithoutCloudKitEntitlement() async throws {
        guard !CloudKitEntitlementPolicy.currentProcessAuthorizes(
            containerIdentifier: "iCloud.com.ulisses.threadline"
        ) else {
            throw XCTSkip("The test process is CloudKit-entitled")
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ThreadlineLocalBootstrapTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let codexHome = root.appending(path: "codex", directoryHint: .isDirectory)
        let claudeHome = root.appending(path: "claude", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let configuration = RuntimeConfiguration(
            applicationSupportURL: support,
            codexHomeURL: codexHome,
            claudeHomeURL: claudeHome
        )
        let services = try await ApplicationServices.makeDefault(
            configuration: configuration,
            masterKeyProvider: MasterKeyProvider(
                service: "com.ulisses.threadline.tests.\(UUID().uuidString)",
                account: "local-bootstrap",
                store: RejectingKeyMaterialStore()
            )
        )
        let health = await services.healthSnapshot()

        XCTAssertFalse(health.cloudAvailable)
        XCTAssertFalse(health.issues.contains { $0.id == "device-registry" })
        XCTAssertTrue(fileManager.fileExists(atPath: configuration.databaseURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: support.appending(
            path: "Threadline-staging.sqlite"
        ).path))
    }

    func testEndToEndIngestImportsBothProvidersAndPersistsPrivateCursors() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ThreadlineRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fixtureRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ManualQA", directoryHint: .isDirectory)
        let codexHome = root.appending(path: "codex", directoryHint: .isDirectory)
        let claudeHome = root.appending(path: "claude", directoryHint: .isDirectory)
        try fileManager.copyItem(at: fixtureRoot.appending(path: "codex"), to: codexHome)
        try fileManager.copyItem(at: fixtureRoot.appending(path: "claude"), to: claudeHome)

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let legacyCursorDirectory = support.appending(path: "IngestCursors", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: legacyCursorDirectory, withIntermediateDirectories: true)
        let legacyFutureCursor = Data(#"{"completedThrough":4000000000}"#.utf8)
        for provider in ProviderKind.allCases {
            try legacyFutureCursor.write(
                to: legacyCursorDirectory.appending(path: "\(provider.rawValue).json")
            )
        }
        try JSONEncoder().encode(SyncCursor(
            token: Data("legacy-sidecar".utf8),
            updatedAt: .distantFuture
        )).write(to: support.appending(path: "cloud-cursor.json"))
        let configuration = RuntimeConfiguration(
            applicationSupportURL: support,
            codexHomeURL: codexHome,
            claudeHomeURL: claudeHome
        )
        let store = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: "runtime-test-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await store.migrate()

        let providerEnvironment = ProviderEnvironment(environment: [
            "CODEX_HOME": codexHome.path,
            "CLAUDE_CONFIG_DIR": claudeHome.path,
            "PATH": "",
        ])
        let unavailableExecutable = root.appending(path: "unavailable-provider-cli")
        let providers = ProviderRegistry(adapters: [
            .codex: CodexAdapter(
                environment: providerEnvironment,
                deviceID: "runtime-test-device",
                executableURL: unavailableExecutable
            ),
            .claude: ClaudeAdapter(
                environment: providerEnvironment,
                deviceID: "runtime-test-device",
                executableURL: unavailableExecutable
            ),
        ])
        let services = ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: "runtime-test-device",
            providers: providers,
            transport: DisabledSyncTransport(reason: "runtime fixture")
        )
        let progressRecorder = IngestionProgressRecorder()

        try await services.ingestAll { progress in
            await progressRecorder.record(progress)
        }
        let conversations = try await store.listConversations(query: nil, provider: nil, favoritesOnly: false)
        let progress = await progressRecorder.values
        let health = await services.healthSnapshot()
        let issueDetails = health.issues.map { "\($0.title): \($0.detail)" }.joined(separator: " | ")
        XCTAssertEqual(Set(conversations.map(\.provider)), Set(ProviderKind.allCases), issueDetails)
        XCTAssertEqual(conversations.count, 2, issueDetails)
        XCTAssertEqual(Set(progress.map(\.provider)), Set(ProviderKind.allCases))
        XCTAssertEqual(progress.map(\.committedConversationCount).sorted(), [1, 2])

        let codexCursor = try await store.loadProviderIngestCursor(provider: .codex)
        let claudeCursor = try await store.loadProviderIngestCursor(provider: .claude)
        XCTAssertNotNil(codexCursor)
        XCTAssertNotNil(claudeCursor)
        XCTAssertLessThan(try XCTUnwrap(codexCursor), Date(timeIntervalSinceReferenceDate: 4_000_000_000))
        XCTAssertLessThan(try XCTUnwrap(claudeCursor), Date(timeIntervalSinceReferenceDate: 4_000_000_000))
        XCTAssertTrue(fileManager.fileExists(atPath: support.appending(path: "cloud-cursor.json").path))

        let reopened = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: "runtime-test-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await reopened.migrate()
        let persistedCodexCursor = try await reopened.loadProviderIngestCursor(provider: .codex)
        let persistedClaudeCursor = try await reopened.loadProviderIngestCursor(provider: .claude)
        XCTAssertEqual(persistedCodexCursor, codexCursor)
        XCTAssertEqual(persistedClaudeCursor, claudeCursor)
    }

    func testProviderDatabaseFailureProducesSafeEnglishHealthIssue() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "ThreadlineRuntimeHealthTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let configuration = RuntimeConfiguration(
            applicationSupportURL: root,
            codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
        )
        let store = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: "runtime-health-test-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await store.migrate()
        let services = ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: "runtime-health-test-device",
            providers: ProviderRegistry(adapters: [
                .codex: FailingProviderAdapter(error: ThreadlineError.database(
                    "SQLite statement failed: UNIQUE constraint failed: events.id\nprivate-payload-must-not-appear"
                )),
            ]),
            transport: DisabledSyncTransport(reason: "Test transport")
        )

        try await services.ingestAll()
        let health = await services.healthSnapshot()
        let issue = try XCTUnwrap(health.issues.first { $0.id == "provider-codex" })

        XCTAssertEqual(issue.title, "Codex could not be updated")
        XCTAssertEqual(
            issue.detail,
            "Import failed because the database rejected duplicate values for events.id."
        )
        XCTAssertEqual(
            issue.recoverySuggestion,
            "Check the provider installation, then refresh the library again."
        )
        XCTAssertFalse(issue.detail.contains("private-payload"))
        let failedProviderCursor = try await store.loadProviderIngestCursor(provider: .codex)
        XCTAssertNil(failedProviderCursor)
    }

    func testBlockedProviderDoesNotPreventOtherProviderFromCompleting() async throws {
        let root = try makeTemporaryDirectory(prefix: "ThreadlineConcurrentIngestTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = RuntimeConfiguration(
            applicationSupportURL: root,
            codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
        )
        let store = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: "concurrent-ingest-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await store.migrate()
        let codexGate = AsyncTestGate()
        let services = ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: "concurrent-ingest-device",
            providers: ProviderRegistry(adapters: [
                .codex: BlockingProviderAdapter(
                    kind: .codex,
                    conversation: makeProviderConversation(provider: .codex),
                    gate: codexGate
                ),
                .claude: SingleConversationProviderAdapter(
                    kind: .claude,
                    conversation: makeProviderConversation(provider: .claude)
                ),
            ]),
            transport: DisabledSyncTransport(reason: "runtime fixture")
        )

        let ingestion = Task {
            try await services.ingestAll()
        }
        await codexGate.waitUntilBlocked()

        var claudeCompletedWhileCodexWasBlocked = false
        for _ in 0..<100 {
            let conversations = try await store.listConversations(
                query: nil,
                provider: nil,
                favoritesOnly: false
            )
            let claudeCursor = try await store.loadProviderIngestCursor(provider: .claude)
            if conversations.contains(where: { $0.provider == .claude }), claudeCursor != nil {
                claudeCompletedWhileCodexWasBlocked = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let conversationsBeforeRelease = try await store.listConversations(
            query: nil,
            provider: nil,
            favoritesOnly: false
        )
        let codexCursorBeforeRelease = try await store.loadProviderIngestCursor(provider: .codex)
        XCTAssertTrue(claudeCompletedWhileCodexWasBlocked)
        XCTAssertFalse(conversationsBeforeRelease.contains { $0.provider == .codex })
        XCTAssertNil(codexCursorBeforeRelease)

        await codexGate.release()
        try await ingestion.value
        let completedConversations = try await store.listConversations(
            query: nil,
            provider: nil,
            favoritesOnly: false
        )
        let codexCursorAfterRelease = try await store.loadProviderIngestCursor(provider: .codex)
        XCTAssertEqual(Set(completedConversations.map(\.provider)), Set(ProviderKind.allCases))
        XCTAssertNotNil(codexCursorAfterRelease)
    }

    func testCancellationErrorCancelsSiblingAndDoesNotPromoteCursors() async throws {
        let root = try makeTemporaryDirectory(prefix: "ThreadlineIngestCancellationTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = RuntimeConfiguration(
            applicationSupportURL: root,
            codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
        )
        let store = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: "ingest-cancellation-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await store.migrate()
        let probe = IngestCancellationProbe()
        let services = ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: "ingest-cancellation-device",
            providers: ProviderRegistry(adapters: [
                .codex: CancelingProviderAdapter(probe: probe),
                .claude: CancellationObservingProviderAdapter(probe: probe),
            ]),
            transport: DisabledSyncTransport(reason: "runtime fixture")
        )

        do {
            try await services.ingestAll()
            XCTFail("Expected provider cancellation to cancel the ingestion")
        } catch is CancellationError {
            // Expected: the throwing task group propagates cancellation.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let siblingObservedCancellation = await probe.siblingObservedCancellation
        let codexCursor = try await store.loadProviderIngestCursor(provider: .codex)
        let claudeCursor = try await store.loadProviderIngestCursor(provider: .claude)
        XCTAssertTrue(siblingObservedCancellation)
        XCTAssertNil(codexCursor)
        XCTAssertNil(claudeCursor)
    }

    func testSyncPreparesDeviceRegistryBeforeTouchingTransport() async throws {
        let root = try makeTemporaryDirectory(prefix: "ThreadlineRegistryOrderTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeCallRecorder()
        let registry = FakeDeviceRegistry(readiness: .ready, recorder: recorder)
        let pulledCursor = SyncCursor(
            token: Data("transport-token".utf8),
            updatedAt: Date(timeIntervalSince1970: 500)
        )
        let transport = RecordingSyncTransport(
            identifier: "recording-sync",
            pulledCursor: pulledCursor,
            recorder: recorder
        )
        let services = try await makeSyncServices(
            root: root,
            registry: registry,
            transport: transport
        )

        try await services.syncNow()

        let calls = await recorder.values
        XCTAssertEqual(calls, ["registry.prepare", "transport.health", "transport.pull"])
        let health = await services.healthSnapshot()
        XCTAssertTrue(health.cloudAvailable)
        XCTAssertFalse(health.issues.contains { $0.id == "device-registry" })
        let savedCursor = try await services.store.loadSyncCursor(
            transportIdentifier: "recording-sync"
        )
        let unrelatedCursor = try await services.store.loadSyncCursor(
            transportIdentifier: "another-transport"
        )
        XCTAssertEqual(savedCursor, pulledCursor)
        XCTAssertEqual(unrelatedCursor, SyncCursor())
    }

    func testCursorStateIsIsolatedBetweenMainAndStagingDatabases() async throws {
        let root = try makeTemporaryDirectory(prefix: "ThreadlineCursorDatabaseIsolationTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let mainStore = try SQLiteConversationStore(
            databaseURL: root.appending(path: "Threadline.sqlite"),
            deviceID: "main-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        let stagingStore = try SQLiteConversationStore(
            databaseURL: root.appending(path: "Threadline-staging.sqlite"),
            deviceID: "staging-device",
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await mainStore.migrate()
        try await stagingStore.migrate()

        let mainIngestCursor = Date(timeIntervalSince1970: 100)
        let stagingIngestCursor = Date(timeIntervalSince1970: 200)
        let mainSyncCursor = SyncCursor(
            token: Data("main".utf8),
            updatedAt: mainIngestCursor
        )
        let stagingSyncCursor = SyncCursor(
            token: Data("staging".utf8),
            updatedAt: stagingIngestCursor
        )
        try await mainStore.saveProviderIngestCursor(mainIngestCursor, provider: .codex)
        try await stagingStore.saveProviderIngestCursor(stagingIngestCursor, provider: .codex)
        try await mainStore.saveSyncCursor(mainSyncCursor, transportIdentifier: "cloud")
        try await stagingStore.saveSyncCursor(stagingSyncCursor, transportIdentifier: "cloud")

        let loadedMainIngest = try await mainStore.loadProviderIngestCursor(provider: .codex)
        let loadedStagingIngest = try await stagingStore.loadProviderIngestCursor(provider: .codex)
        let loadedMainClaude = try await mainStore.loadProviderIngestCursor(provider: .claude)
        let loadedMainSync = try await mainStore.loadSyncCursor(transportIdentifier: "cloud")
        let loadedStagingSync = try await stagingStore.loadSyncCursor(transportIdentifier: "cloud")
        XCTAssertEqual(loadedMainIngest, mainIngestCursor)
        XCTAssertEqual(loadedStagingIngest, stagingIngestCursor)
        XCTAssertNil(loadedMainClaude)
        XCTAssertEqual(loadedMainSync, mainSyncCursor)
        XCTAssertEqual(loadedStagingSync, stagingSyncCursor)
    }

    func testKeyMismatchBlocksSyncBeforeTransportAccess() async throws {
        let root = try makeTemporaryDirectory(prefix: "ThreadlineRegistryMismatchTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeCallRecorder()
        let registry = FakeDeviceRegistry(
            readiness: .keyMismatch,
            includeCurrentDevice: false,
            recorder: recorder
        )
        let transport = RecordingSyncTransport(recorder: recorder)
        let services = try await makeSyncServices(
            root: root,
            registry: registry,
            transport: transport
        )

        do {
            try await services.syncNow()
            XCTFail("Expected a key mismatch to block synchronization")
        } catch let error as ThreadlineError {
            XCTAssertTrue(error.localizedDescription.contains("different conversation encryption key"))
        }
        let calls = await recorder.values
        XCTAssertEqual(calls, ["registry.prepare"])
        let health = await services.healthSnapshot()
        XCTAssertFalse(health.cloudAvailable)
        XCTAssertEqual(
            health.issues.first { $0.id == "device-registry" }?.title,
            "Encryption keys do not match"
        )
    }

    func testRetiredDeviceBlocksSyncBeforeTransportAccess() async throws {
        let root = try makeTemporaryDirectory(prefix: "ThreadlineRegistryRetiredTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeCallRecorder()
        let registry = FakeDeviceRegistry(
            readiness: .ready,
            currentDeviceRetired: true,
            recorder: recorder
        )
        let transport = RecordingSyncTransport(recorder: recorder)
        let services = try await makeSyncServices(
            root: root,
            registry: registry,
            transport: transport
        )

        do {
            try await services.syncNow()
            XCTFail("Expected a retired device to block synchronization")
        } catch let error as ThreadlineError {
            XCTAssertTrue(error.localizedDescription.contains("marked as retired"))
        }
        let calls = await recorder.values
        XCTAssertEqual(calls, ["registry.prepare"])
        let health = await services.healthSnapshot()
        XCTAssertFalse(health.cloudAvailable)
        XCTAssertEqual(
            health.issues.first { $0.id == "device-registry" }?.title,
            "This Mac is removed from sync"
        )
    }

    func testDeviceProfileUsesGenericNonPersonalDisplayName() {
        let profile = DeviceProfileFactory.make(deviceID: "profile-test-device")

        XCTAssertEqual(profile.id, "profile-test-device")
        XCTAssertEqual(profile.displayName, "This Mac")
        XCTAssertFalse(profile.systemVersion.isEmpty)
        XCTAssertFalse(profile.appVersion.isEmpty)
    }

    private func makeSyncServices(
        root: URL,
        registry: any DeviceRegistry,
        transport: any SyncTransport
    ) async throws -> ApplicationServices {
        let configuration = RuntimeConfiguration(
            applicationSupportURL: root,
            codexHomeURL: root.appending(path: "codex", directoryHint: .isDirectory),
            claudeHomeURL: root.appending(path: "claude", directoryHint: .isDirectory)
        )
        let store = try SQLiteConversationStore(
            databaseURL: configuration.databaseURL,
            deviceID: registry.currentDeviceID,
            envelopeCodec: PlaintextEnvelopeCodec()
        )
        try await store.migrate()
        return ApplicationServices(
            store: store,
            configuration: configuration,
            deviceID: registry.currentDeviceID,
            providers: ProviderRegistry(adapters: [:]),
            transport: transport,
            deviceRegistry: registry,
            cloudKitAuthorized: true
        )
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor RuntimeCallRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor FakeDeviceRegistry: DeviceRegistry {
    nonisolated let currentDeviceID = "fake-device"

    private let recorder: RuntimeCallRecorder
    private var snapshot: DeviceRegistrySnapshot

    init(
        readiness: DeviceRegistryReadiness,
        currentDeviceRetired: Bool = false,
        includeCurrentDevice: Bool = true,
        recorder: RuntimeCallRecorder
    ) {
        self.recorder = recorder
        let devices = includeCurrentDevice ? [RegisteredDevice(
            id: currentDeviceID,
            displayName: "This Mac",
            systemVersion: "15.0.0",
            appVersion: "1.0",
            registeredAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            retiredAt: currentDeviceRetired ? Date(timeIntervalSince1970: 3) : nil
        )] : []
        snapshot = DeviceRegistrySnapshot(
            currentDeviceID: currentDeviceID,
            devices: devices,
            readiness: readiness,
            refreshedAt: Date(timeIntervalSince1970: 4)
        )
    }

    func cachedSnapshot() async -> DeviceRegistrySnapshot { snapshot }

    func refresh() async -> DeviceRegistrySnapshot { snapshot }

    func prepareForSync() async -> DeviceRegistrySnapshot {
        await recorder.record("registry.prepare")
        return snapshot
    }

    func renameDevice(id: String, displayName: String) async -> DeviceRegistrySnapshot {
        if let index = snapshot.devices.firstIndex(where: { $0.id == id }) {
            snapshot.devices[index].displayName = displayName
        }
        return snapshot
    }

    func retireDevice(id: String) async -> DeviceRegistrySnapshot { snapshot }

    func reactivateCurrentDevice() async -> DeviceRegistrySnapshot { snapshot }
}

private actor RecordingSyncTransport: SyncTransport {
    nonisolated let identifier: String
    private let pulledCursor: SyncCursor?
    private let recorder: RuntimeCallRecorder

    init(
        identifier: String = "recording-sync",
        pulledCursor: SyncCursor? = nil,
        recorder: RuntimeCallRecorder
    ) {
        self.identifier = identifier
        self.pulledCursor = pulledCursor
        self.recorder = recorder
    }

    func push(_ envelopes: [SyncEnvelope]) async throws {
        await recorder.record("transport.push")
    }

    func pull(since cursor: SyncCursor) async throws -> SyncPullResult {
        await recorder.record("transport.pull")
        return SyncPullResult(envelopes: [], cursor: pulledCursor ?? cursor)
    }

    func healthCheck() async -> Bool {
        await recorder.record("transport.health")
        return true
    }
}

private struct FailingProviderAdapter: ProviderAdapter {
    let kind: ProviderKind = .codex
    let error: ThreadlineError

    func discoverSources() async -> [ProviderSource] { [] }

    func fetchConversations(since: Date?) async throws -> [ProviderConversation] {
        throw error
    }

    func fetchConversation(id: String) async throws -> ProviderConversation? {
        nil
    }
}

private struct SingleConversationProviderAdapter: ProviderAdapter {
    let kind: ProviderKind
    let conversation: ProviderConversation

    func discoverSources() async -> [ProviderSource] { [] }

    func fetchConversations(since: Date?) async throws -> [ProviderConversation] {
        [conversation]
    }

    func fetchConversation(id: String) async throws -> ProviderConversation? {
        id == conversation.summary.id ? conversation : nil
    }
}

private struct BlockingProviderAdapter: ProviderAdapter {
    let kind: ProviderKind
    let conversation: ProviderConversation
    let gate: AsyncTestGate

    func discoverSources() async -> [ProviderSource] { [] }

    func fetchConversations(since: Date?) async throws -> [ProviderConversation] {
        [conversation]
    }

    func scanConversations(
        since: Date?,
        yield: @escaping @Sendable (ProviderConversation) async throws -> Void
    ) async throws {
        await gate.blockUntilReleased()
        try Task.checkCancellation()
        try await yield(conversation)
    }

    func fetchConversation(id: String) async throws -> ProviderConversation? {
        id == conversation.summary.id ? conversation : nil
    }
}

private actor AsyncTestGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        isBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor IngestCancellationProbe {
    private var siblingStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var siblingObservedCancellation = false

    func markSiblingStarted() {
        siblingStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilSiblingStarts() async {
        guard !siblingStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func recordSiblingCancellation() {
        siblingObservedCancellation = true
    }
}

private struct CancelingProviderAdapter: ProviderAdapter {
    let kind: ProviderKind = .codex
    let probe: IngestCancellationProbe

    func discoverSources() async -> [ProviderSource] { [] }

    func fetchConversations(since: Date?) async throws -> [ProviderConversation] { [] }

    func scanConversations(
        since: Date?,
        yield: @escaping @Sendable (ProviderConversation) async throws -> Void
    ) async throws {
        await probe.waitUntilSiblingStarts()
        throw CancellationError()
    }

    func fetchConversation(id: String) async throws -> ProviderConversation? { nil }
}

private struct CancellationObservingProviderAdapter: ProviderAdapter {
    let kind: ProviderKind = .claude
    let probe: IngestCancellationProbe

    func discoverSources() async -> [ProviderSource] { [] }

    func fetchConversations(since: Date?) async throws -> [ProviderConversation] { [] }

    func scanConversations(
        since: Date?,
        yield: @escaping @Sendable (ProviderConversation) async throws -> Void
    ) async throws {
        await probe.markSiblingStarted()
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            await probe.recordSiblingCancellation()
            throw CancellationError()
        }
    }

    func fetchConversation(id: String) async throws -> ProviderConversation? { nil }
}

private func makeProviderConversation(provider: ProviderKind) -> ProviderConversation {
    let conversationID = "\(provider.rawValue)-concurrent-conversation"
    let timestamp = Date(timeIntervalSince1970: 1_000)
    return ProviderConversation(
        summary: ConversationSummary(
            id: conversationID,
            provider: provider,
            providerSessionID: "\(provider.rawValue)-session",
            title: "\(provider.displayName) concurrent import",
            preview: "Imported while the other provider is blocked",
            createdAt: timestamp,
            updatedAt: timestamp,
            originDeviceID: "concurrent-ingest-device",
            messageCount: 1
        ),
        events: [ConversationEvent(
            id: "\(conversationID)-event",
            conversationID: conversationID,
            sequence: 1,
            timestamp: timestamp,
            kind: .userMessage,
            role: .user,
            text: "Concurrent import",
            contentHash: "\(provider.rawValue)-event-hash",
            sourceDeviceID: "concurrent-ingest-device"
        )],
        sourceFingerprint: "\(provider.rawValue)-fingerprint",
        sourceSchemaVersion: "test-v1"
    )
}

private struct RejectingKeyMaterialStore: KeyMaterialStore {
    func load(service: String, account: String) throws -> Data? {
        throw ThreadlineError.encryption("Local-only bootstrap accessed the key store")
    }

    func save(_ data: Data, service: String, account: String) throws {
        throw ThreadlineError.encryption("Local-only bootstrap accessed the key store")
    }

    func delete(service: String, account: String) throws {
        throw ThreadlineError.encryption("Local-only bootstrap accessed the key store")
    }
}

private actor IngestionProgressRecorder {
    private(set) var values: [IngestionProgress] = []

    func record(_ progress: IngestionProgress) {
        values.append(progress)
    }
}
