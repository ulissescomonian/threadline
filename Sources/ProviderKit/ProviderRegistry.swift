import ConversationCore
import Foundation

public struct ProviderRegistry: Sendable {
    private let adapters: [ProviderKind: any ProviderAdapter]

    public init(adapters: [ProviderKind: any ProviderAdapter]) {
        self.adapters = adapters
    }

    public init(
        environment: ProviderEnvironment = ProviderEnvironment(),
        deviceID: String? = nil,
        processRunner: any ProcessRunning = LocalProcessRunner()
    ) {
        self.init(adapters: [
            .codex: CodexAdapter(environment: environment, deviceID: deviceID, processRunner: processRunner),
            .claude: ClaudeAdapter(environment: environment, deviceID: deviceID, processRunner: processRunner),
        ])
    }

    public var availableKinds: [ProviderKind] {
        ProviderKind.allCases.filter { adapters[$0] != nil }
    }

    public func adapter(for kind: ProviderKind) -> (any ProviderAdapter)? {
        adapters[kind]
    }

    public func discoverSources() async -> [ProviderSource] {
        await withTaskGroup(of: [ProviderSource].self) { group in
            for adapter in adapters.values {
                group.addTask { await adapter.discoverSources() }
            }
            var sources: [ProviderSource] = []
            for await result in group { sources.append(contentsOf: result) }
            return sources.sorted { lhs, rhs in
                if lhs.provider.rawValue == rhs.provider.rawValue { return lhs.rootPath < rhs.rootPath }
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
        }
    }

    public func fetchAll(since: Date? = nil) async -> [ProviderKind: Result<[ProviderConversation], Error>] {
        await withTaskGroup(of: (ProviderKind, Result<[ProviderConversation], Error>).self) { group in
            for (kind, adapter) in adapters {
                group.addTask {
                    do { return (kind, .success(try await adapter.fetchConversations(since: since))) }
                    catch { return (kind, .failure(error)) }
                }
            }
            var output: [ProviderKind: Result<[ProviderConversation], Error>] = [:]
            for await (kind, result) in group { output[kind] = result }
            return output
        }
    }
}

public enum ProviderFactory {
    public static func makeDefault(
        environment: ProviderEnvironment = ProviderEnvironment(),
        deviceID: String? = nil,
        processRunner: any ProcessRunning = LocalProcessRunner()
    ) -> ProviderRegistry {
        ProviderRegistry(environment: environment, deviceID: deviceID, processRunner: processRunner)
    }
}
