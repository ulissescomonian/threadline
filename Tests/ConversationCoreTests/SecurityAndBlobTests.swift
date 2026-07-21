import Foundation
import CloudKit
import CryptoKit
import Security
import XCTest
@testable import ConversationCore

@MainActor
final class SecurityAndBlobTests: XCTestCase {
    func testEncryptedEnvelopeRoundTripsAndRejectsWrongKey() throws {
        let firstKey = Data(repeating: 0x11, count: 32)
        let secondKey = Data(repeating: 0x22, count: 32)
        let codec = try EncryptedEnvelopeCodec(keyData: firstKey)
        let conversation = sampleConversation()
        let envelope = try codec.seal(
            conversation,
            originDeviceID: "mini",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNotEqual(envelope.encryptedPayload, try JSONEncoder().encode(conversation))
        XCTAssertEqual(try codec.open(envelope), conversation)
        XCTAssertThrowsError(try EncryptedEnvelopeCodec(keyData: secondKey).open(envelope))

        var damaged = envelope.encryptedPayload
        damaged[damaged.startIndex] ^= 0xff
        let corrupted = SyncEnvelope(
            id: envelope.id,
            objectType: envelope.objectType,
            logicalVersion: envelope.logicalVersion,
            originDeviceID: envelope.originDeviceID,
            createdAt: envelope.createdAt,
            encryptedPayload: damaged,
            payloadHash: envelope.payloadHash
        )
        XCTAssertThrowsError(try codec.open(corrupted))

        let metadataTampered = SyncEnvelope(
            id: envelope.id,
            objectType: envelope.objectType,
            logicalVersion: envelope.logicalVersion,
            originDeviceID: envelope.originDeviceID,
            createdAt: envelope.createdAt.addingTimeInterval(1),
            encryptedPayload: envelope.encryptedPayload,
            payloadHash: envelope.payloadHash
        )
        XCTAssertThrowsError(try codec.open(metadataTampered))
        XCTAssertEqual(envelope.logicalVersion, SyncEnvelopeLimits.authenticatedFormatVersion)
    }

    func testRetryPolicyHonorsRetryAfterAndStopsAtAttemptLimit() {
        let policy = CloudRetryPolicy(maximumAttempts: 3, initialDelay: 0.5, maximumDelay: 5)
        XCTAssertEqual(
            policy.delay(for: .requestRateLimited, retryAfter: 2, failedAttempt: 0, jitter: 1),
            2
        )
        XCTAssertEqual(
            policy.delay(for: .networkFailure, retryAfter: nil, failedAttempt: 1, jitter: 1),
            1
        )
        XCTAssertNil(policy.delay(for: .permissionFailure, retryAfter: nil, failedAttempt: 0))
        XCTAssertNil(policy.delay(for: .networkFailure, retryAfter: nil, failedAttempt: 2))
    }

    func testMasterKeyProviderUsesInjectedStoreAndPersistsKey() throws {
        let memory = InMemoryKeyMaterialStore()
        let provider = MasterKeyProvider(service: "test", account: "master", store: memory)
        let first = try provider.loadOrCreate()
        let second = try provider.loadOrCreate()

        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(first, second)
        try provider.delete()
        XCTAssertNil(try memory.load(service: "test", account: "master"))
    }

    func testKeychainStoreScopesEveryOperationToValidatedAccessGroup() throws {
        let payload = Data("shared-key".utf8)
        let client = RecordingKeychainClient(
            copyResult: KeychainCopyResult(status: errSecSuccess, data: payload),
            updateStatus: errSecItemNotFound,
            addStatus: errSecSuccess,
            deleteStatus: errSecSuccess
        )
        let store = try KeychainKeyMaterialStore(
            synchronizable: true,
            accessGroup: "  TEAMID.com.ulisses.threadline.shared  ",
            client: client
        )

        XCTAssertEqual(try store.load(service: "threadline", account: "master"), payload)
        try store.save(payload, service: "threadline", account: "master")
        try store.delete(service: "threadline", account: "master")

        let calls = client.recordedCalls
        XCTAssertEqual(calls.count, 4)
        for query in calls.map(\.scopeQuery) {
            assertKeychainScope(
                query,
                synchronizable: true,
                accessGroup: "TEAMID.com.ulisses.threadline.shared"
            )
        }
        guard case .copy(let loadQuery) = calls[0],
              case .update(_, let updateAttributes) = calls[1],
              case .add(let addAttributes) = calls[2],
              case .delete = calls[3]
        else {
            return XCTFail("Unexpected Keychain operation order")
        }
        XCTAssertEqual(loadQuery[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(loadQuery[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(updateAttributes[kSecValueData as String] as? Data, payload)
        XCTAssertEqual(addAttributes[kSecValueData as String] as? Data, payload)
        XCTAssertEqual(
            addAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlock as String
        )
    }

    func testKeychainStoreOmitsAccessGroupWhenNilAndExplicitlyMatchesLocalItems() throws {
        let client = RecordingKeychainClient(
            copyResult: KeychainCopyResult(status: errSecItemNotFound, data: nil),
            updateStatus: errSecItemNotFound,
            addStatus: errSecSuccess,
            deleteStatus: errSecItemNotFound
        )
        let store = try KeychainKeyMaterialStore(
            synchronizable: false,
            accessGroup: nil,
            client: client
        )

        XCTAssertNil(try store.load(service: "threadline", account: "local-master"))
        try store.save(Data([0x01]), service: "threadline", account: "local-master")
        try store.delete(service: "threadline", account: "local-master")

        let calls = client.recordedCalls
        XCTAssertEqual(calls.count, 4)
        for query in calls.map(\.scopeQuery) {
            assertKeychainScope(query, synchronizable: false, accessGroup: nil)
        }
    }

    func testKeychainAccessGroupValidationAndAuthorizationPolicy() throws {
        XCTAssertThrowsError(try KeychainKeyMaterialStore(
            synchronizable: true,
            accessGroup: "  \n  ",
            client: RecordingKeychainClient()
        ))
        XCTAssertThrowsError(try KeychainKeyMaterialStore(
            synchronizable: true,
            accessGroup: String(repeating: "a", count: KeychainAccessGroupPolicy.maximumUTF8Length + 1),
            client: RecordingKeychainClient()
        ))
        XCTAssertTrue(KeychainAccessGroupPolicy.authorizes(
            accessGroup: "  TEAMID.com.ulisses.threadline.shared ",
            entitledAccessGroups: ["TEAMID.com.ulisses.threadline.shared"]
        ))
        XCTAssertFalse(KeychainAccessGroupPolicy.authorizes(
            accessGroup: "TEAMID.com.ulisses.threadline.shared",
            entitledAccessGroups: ["TEAMID.com.example.other"]
        ))
        XCTAssertFalse(KeychainAccessGroupPolicy.authorizes(
            accessGroup: "TEAMID.com.ulisses.threadline.shared",
            entitledAccessGroups: nil
        ))
    }

    func testKeychainAccessGroupResolutionRequiresOneUnambiguousSuffixMatch() {
        let suffix = "com.ulisses.threadline.shared"
        XCTAssertNil(KeychainAccessGroupPolicy.resolvedAccessGroup(
            canonicalSuffix: suffix,
            entitledAccessGroups: nil
        ))
        XCTAssertNil(KeychainAccessGroupPolicy.resolvedAccessGroup(
            canonicalSuffix: suffix,
            entitledAccessGroups: ["TEAMID.com.ulisses.threadline"]
        ))
        XCTAssertEqual(
            KeychainAccessGroupPolicy.resolvedAccessGroup(
                canonicalSuffix: suffix,
                entitledAccessGroups: [
                    "TEAMID.com.example.other",
                    "TEAMID.com.ulisses.threadline.shared",
                ]
            ),
            "TEAMID.com.ulisses.threadline.shared"
        )
        XCTAssertNil(KeychainAccessGroupPolicy.resolvedAccessGroup(
            canonicalSuffix: suffix,
            entitledAccessGroups: [
                "FIRST.com.ulisses.threadline.shared",
                "SECOND.com.ulisses.threadline.shared",
            ]
        ))
        XCTAssertNil(KeychainAccessGroupPolicy.resolvedAccessGroup(
            canonicalSuffix: suffix,
            entitledAccessGroups: ["TEAMID.notcom.ulisses.threadline.shared"]
        ))
    }

    func testRecoveringKeyStoreFallsBackAndLaterPromotesExistingKey() throws {
        let unavailablePrimary = ThrowingKeyMaterialStore()
        let fallback = InMemoryKeyMaterialStore()
        let recovering = RecoveringKeyMaterialStore(primary: unavailablePrimary, fallback: fallback)
        let key = Data(repeating: 0x5a, count: 32)

        try recovering.save(key, service: "test", account: "master")
        XCTAssertEqual(try fallback.load(service: "test", account: "master"), key)
        XCTAssertEqual(try recovering.load(service: "test", account: "master"), key)

        let availablePrimary = InMemoryKeyMaterialStore()
        let promoting = RecoveringKeyMaterialStore(primary: availablePrimary, fallback: fallback)
        XCTAssertEqual(try promoting.load(service: "test", account: "master"), key)
        XCTAssertEqual(try availablePrimary.load(service: "test", account: "master"), key)
    }

    func testContentAddressedBlobStoreDeduplicatesAndChecksIntegrity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadlineBlobTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContentAddressedBlobStore(rootURL: directory)
        let payload = Data("immutable transcript attachment".utf8)

        let firstHash = try await store.put(payload)
        let secondHash = try await store.put(payload)
        XCTAssertEqual(firstHash, secondHash)
        XCTAssertEqual(firstHash.count, 64)
        let contains = await store.contains(firstHash)
        let loaded = try await store.data(for: firstHash)
        let missing = try await store.data(for: String(repeating: "a", count: 64))
        XCTAssertTrue(contains)
        XCTAssertEqual(loaded, payload)
        XCTAssertNil(missing)
        XCTAssertEqual(try permissionBits(at: directory.path), 0o700)
        XCTAssertEqual(try permissionBits(at: directory.appendingPathComponent(String(firstHash.prefix(2))).path), 0o700)
        XCTAssertEqual(try permissionBits(at: directory.appendingPathComponent(String(firstHash.prefix(2))).appendingPathComponent(firstHash).path), 0o600)
    }

    func testEncryptedCodecCanReadLegacyVersionOneEnvelope() throws {
        let keyData = Data(repeating: 0x33, count: 32)
        let conversation = sampleConversation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let cleartext = try encoder.encode(conversation)
        let hash = PlaintextEnvelopeCodec.sha256(cleartext)
        let combined = try XCTUnwrap(
            AES.GCM.seal(cleartext, using: SymmetricKey(data: keyData)).combined
        )
        let legacy = SyncEnvelope(
            id: "conversation:\(conversation.summary.id):\(hash)",
            objectType: "conversation",
            logicalVersion: SyncEnvelopeLimits.legacyFormatVersion,
            originDeviceID: conversation.summary.originDeviceID,
            createdAt: Date(timeIntervalSince1970: 123),
            encryptedPayload: combined,
            payloadHash: hash
        )

        XCTAssertEqual(try EncryptedEnvelopeCodec(keyData: keyData).open(legacy), conversation)
    }

    func testPlaintextCodecChecksIntegrityAndObjectType() throws {
        let codec = PlaintextEnvelopeCodec()
        let envelope = try codec.seal(sampleConversation(), originDeviceID: "mini", createdAt: .distantPast)
        XCTAssertEqual(try codec.open(envelope), sampleConversation())

        let wrongType = SyncEnvelope(
            id: envelope.id,
            objectType: "unsupported",
            logicalVersion: envelope.logicalVersion,
            originDeviceID: envelope.originDeviceID,
            createdAt: envelope.createdAt,
            encryptedPayload: envelope.encryptedPayload,
            payloadHash: envelope.payloadHash
        )
        XCTAssertThrowsError(try codec.open(wrongType))
    }

    func testDisabledTransportReportsDegradedState() async throws {
        let transport = DisabledSyncTransport(reason: "Cloud sync is not configured")
        let healthy = await transport.healthCheck()
        XCTAssertFalse(healthy)
        do {
            try await transport.push([])
            XCTFail("Expected a cloud error")
        } catch let error as ThreadlineError {
            XCTAssertEqual(error.localizedDescription, "Cloud sync is not configured")
        }
    }

    private func sampleConversation() -> ProviderConversation {
        let summary = ConversationSummary(
            id: "secure-conversation",
            provider: .claude,
            providerSessionID: "claude-session",
            title: "Encrypted",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            originDeviceID: "mini",
            messageCount: 1
        )
        return ProviderConversation(
            summary: summary,
            events: [ConversationEvent(
                id: "secure-event",
                conversationID: summary.id,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 15),
                kind: .assistantMessage,
                role: .assistant,
                text: "Sensitive code",
                metadata: ["path": "/private/repository"],
                contentHash: "secure-hash",
                sourceDeviceID: "mini"
            )],
            sourceFingerprint: "secure-fingerprint",
            sourceSchemaVersion: "v1"
        )
    }

    private func assertKeychainScope(
        _ query: [String: Any],
        synchronizable: Bool,
        accessGroup: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            query[kSecClass as String] as? String,
            kSecClassGenericPassword as String,
            file: file,
            line: line
        )
        XCTAssertEqual(query[kSecAttrService as String] as? String, "threadline", file: file, line: line)
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            accessGroup == nil ? "local-master" : "master",
            file: file,
            line: line
        )
        XCTAssertEqual(
            query[kSecAttrSynchronizable as String] as? Bool,
            synchronizable,
            file: file,
            line: line
        )
        XCTAssertEqual(
            query[kSecAttrAccessGroup as String] as? String,
            accessGroup,
            file: file,
            line: line
        )
    }
}

private func permissionBits(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private struct ThrowingKeyMaterialStore: KeyMaterialStore {
    func load(service: String, account: String) throws -> Data? { throw TestError.unavailable }
    func save(_ data: Data, service: String, account: String) throws { throw TestError.unavailable }
    func delete(service: String, account: String) throws { throw TestError.unavailable }

    private enum TestError: Error { case unavailable }
}

private final class RecordingKeychainClient: KeychainClient, @unchecked Sendable {
    enum Call {
        case copy([String: Any])
        case update([String: Any], [String: Any])
        case add([String: Any])
        case delete([String: Any])

        var scopeQuery: [String: Any] {
            switch self {
            case .copy(let query), .update(let query, _), .add(let query), .delete(let query):
                query
            }
        }
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let copyResult: KeychainCopyResult
    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private let deleteStatus: OSStatus

    init(
        copyResult: KeychainCopyResult = KeychainCopyResult(status: errSecItemNotFound, data: nil),
        updateStatus: OSStatus = errSecItemNotFound,
        addStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.copyResult = copyResult
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.deleteStatus = deleteStatus
    }

    var recordedCalls: [Call] {
        lock.withLock { calls }
    }

    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult {
        lock.withLock { calls.append(.copy(query)) }
        return copyResult
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock { calls.append(.update(query, attributes)) }
        return updateStatus
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock { calls.append(.add(attributes)) }
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { calls.append(.delete(query)) }
        return deleteStatus
    }
}
