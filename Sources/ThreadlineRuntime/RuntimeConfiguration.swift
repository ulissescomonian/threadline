import Foundation

public struct RuntimeConfiguration: Sendable {
    public let applicationSupportURL: URL
    public let databaseURL: URL
    public let blobDirectoryURL: URL
    public let codexHomeURL: URL
    public let claudeHomeURL: URL
    public let cloudContainerIdentifier: String

    public init(
        applicationSupportURL: URL,
        codexHomeURL: URL,
        claudeHomeURL: URL,
        cloudContainerIdentifier: String = "iCloud.com.ulisses.threadline"
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.databaseURL = applicationSupportURL.appending(path: "Threadline.sqlite")
        self.blobDirectoryURL = applicationSupportURL.appending(path: "Blobs", directoryHint: .isDirectory)
        self.codexHomeURL = codexHomeURL
        self.claudeHomeURL = claudeHomeURL
        self.cloudContainerIdentifier = cloudContainerIdentifier
    }

    public static func systemDefault(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RuntimeConfiguration {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // An override keeps automated/manual QA completely isolated from a
        // user's real library. Production launches use Application Support.
        let applicationSupport = environment["THREADLINE_APP_SUPPORT"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? supportRoot.appending(path: "Threadline", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupport.path)

        let codexHome = environment["CODEX_HOME"].map { URL(filePath: $0) }
            ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
            ?? home.appending(path: ".claude", directoryHint: .isDirectory)

        return RuntimeConfiguration(
            applicationSupportURL: applicationSupport,
            codexHomeURL: codexHome,
            claudeHomeURL: claudeHome
        )
    }
}

public enum DeviceIdentity {
    public static func loadOrCreate(in applicationSupportURL: URL) throws -> String {
        let url = applicationSupportURL.appending(path: "device-id")
        if let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return value
        }

        let value = UUID().uuidString.lowercased()
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
}
