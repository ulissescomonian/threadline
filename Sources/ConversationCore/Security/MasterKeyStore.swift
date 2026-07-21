import Foundation
import Security

public protocol KeyMaterialStore: Sendable {
    func load(service: String, account: String) throws -> Data?
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public enum KeychainAccessGroupPolicy {
    public static let entitlementKey = "keychain-access-groups"
    public static let maximumUTF8Length = 1_024

    public static func currentProcessAuthorizes(accessGroup: String) -> Bool {
        authorizes(
            accessGroup: accessGroup,
            entitledAccessGroups: currentProcessEntitledAccessGroups()
        )
    }

    public static func currentProcessResolvedAccessGroup(
        canonicalSuffix: String
    ) -> String? {
        resolvedAccessGroup(
            canonicalSuffix: canonicalSuffix,
            entitledAccessGroups: currentProcessEntitledAccessGroups()
        )
    }

    public static func authorizes(
        accessGroup: String,
        entitledAccessGroups: [String]?
    ) -> Bool {
        guard let normalized = try? validated(accessGroup) else { return false }
        return entitledAccessGroups?.contains(normalized) == true
    }

    public static func resolvedAccessGroup(
        canonicalSuffix: String,
        entitledAccessGroups: [String]?
    ) -> String? {
        guard let suffix = try? validated(canonicalSuffix) else { return nil }
        let qualifiedSuffix = ".\(suffix)"
        let matches = Set((entitledAccessGroups ?? []).compactMap { candidate -> String? in
            guard let normalized = try? validated(candidate), normalized == candidate else {
                return nil
            }
            guard normalized == suffix || normalized.hasSuffix(qualifiedSuffix) else {
                return nil
            }
            return normalized
        })
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func currentProcessEntitledAccessGroups() -> [String]? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return nil }
        return SecTaskCopyValueForEntitlement(
            task,
            entitlementKey as CFString,
            nil
        ) as? [String]
    }

    static func validated(_ accessGroup: String) throws -> String {
        let normalized = accessGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ThreadlineError.encryption("The Keychain access group must not be empty")
        }
        guard normalized.utf8.count <= maximumUTF8Length else {
            throw ThreadlineError.encryption(
                "The Keychain access group exceeds the safe \(maximumUTF8Length)-byte limit"
            )
        }
        return normalized
    }
}

public struct KeychainKeyMaterialStore: KeyMaterialStore {
    private let synchronizable: Bool
    private let accessGroup: String?
    private let client: any KeychainClient

    public init(synchronizable: Bool = true) {
        self.synchronizable = synchronizable
        accessGroup = nil
        client = SystemKeychainClient()
    }

    public init(synchronizable: Bool = true, accessGroup: String?) throws {
        self.synchronizable = synchronizable
        self.accessGroup = try accessGroup.map(KeychainAccessGroupPolicy.validated)
        client = SystemKeychainClient()
    }

    init(
        synchronizable: Bool,
        accessGroup: String?,
        client: any KeychainClient
    ) throws {
        self.synchronizable = synchronizable
        self.accessGroup = try accessGroup.map(KeychainAccessGroupPolicy.validated)
        self.client = client
    }

    public func load(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = client.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data else {
            throw keychainError(result.status, operation: "read")
        }
        return data
    }

    public func save(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = client.update(query, attributes: attributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus, operation: "update")
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = client.add(newItem)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus, operation: "save")
        }
    }

    public func delete(service: String, account: String) throws {
        let status = client.delete(baseQuery(service: service, account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "delete")
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func keychainError(_ status: OSStatus, operation: String) -> ThreadlineError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return .encryption("Could not \(operation) the encryption key in Keychain: \(detail)")
    }
}

struct KeychainCopyResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol KeychainClient: Sendable {
    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemKeychainClient: KeychainClient {
    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainCopyResult(status: status, data: item as? Data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Keeps local development builds usable when the synchronizable Keychain is
/// unavailable (for example, an ad-hoc signed build without iCloud
/// entitlements). When entitlements become available, a key previously stored
/// in the fallback Keychain is promoted to the synchronizable Keychain before
/// a new key is ever generated, so existing encrypted data remains readable.
public struct RecoveringKeyMaterialStore: KeyMaterialStore {
    private let primary: any KeyMaterialStore
    private let fallback: any KeyMaterialStore

    public init(
        primary: any KeyMaterialStore = KeychainKeyMaterialStore(synchronizable: true),
        fallback: any KeyMaterialStore = KeychainKeyMaterialStore(synchronizable: false)
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func load(service: String, account: String) throws -> Data? {
        do {
            if let value = try primary.load(service: service, account: account) {
                return value
            }

            if let recovered = try fallback.load(service: service, account: account) {
                try? primary.save(recovered, service: service, account: account)
                return recovered
            }
            return nil
        } catch {
            return try fallback.load(service: service, account: account)
        }
    }

    public func save(_ data: Data, service: String, account: String) throws {
        do {
            try primary.save(data, service: service, account: account)
        } catch {
            try fallback.save(data, service: service, account: account)
        }
    }

    public func delete(service: String, account: String) throws {
        var firstError: Error?
        do {
            try primary.delete(service: service, account: account)
        } catch {
            firstError = error
        }
        do {
            try fallback.delete(service: service, account: account)
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }
}

public final class InMemoryKeyMaterialStore: KeyMaterialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func load(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service)|\(account)"] }
    }

    public func save(_ data: Data, service: String, account: String) throws {
        lock.withLock { values["\(service)|\(account)"] = data }
    }

    public func delete(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: "\(service)|\(account)") }
    }
}

public struct MasterKeyProvider: Sendable {
    public let service: String
    public let account: String
    private let store: any KeyMaterialStore

    public init(
        service: String = "com.threadline.sync",
        account: String = "conversation-master-key-v1",
        store: any KeyMaterialStore = RecoveringKeyMaterialStore()
    ) {
        self.service = service
        self.account = account
        self.store = store
    }

    public func loadOrCreate() throws -> Data {
        if let existing = try store.load(service: service, account: account) {
            guard existing.count == 32 else {
                throw ThreadlineError.encryption("The stored master key has an invalid length")
            }
            return existing
        }

        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ThreadlineError.encryption("The system random generator could not create a master key")
        }
        try store.save(key, service: service, account: account)
        return key
    }

    public func delete() throws {
        try store.delete(service: service, account: account)
    }
}
