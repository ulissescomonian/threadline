import ConversationCore
import Darwin
import Foundation

enum DeviceProfileFactory {
    static func make(deviceID: String) -> DeviceProfile {
        DeviceProfile(
            id: deviceID,
            displayName: "This Mac",
            modelIdentifier: hardwareModelIdentifier(),
            systemVersion: operatingSystemVersion(),
            appVersion: applicationVersion()
        )
    }

    private static func hardwareModelIdentifier() -> String? {
        var byteCount = 0
        guard sysctlbyname("hw.model", nil, &byteCount, nil, 0) == 0,
              byteCount > 1
        else { return nil }

        var buffer = [CChar](repeating: 0, count: byteCount)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname("hw.model", bytes.baseAddress, &byteCount, nil, 0)
        }
        guard result == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func applicationVersion() -> String {
        let dictionary = Bundle.main.infoDictionary
        let marketingVersion = dictionary?["CFBundleShortVersionString"] as? String
        let buildVersion = dictionary?["CFBundleVersion"] as? String
        switch (marketingVersion, buildVersion) {
        case let (marketing?, build?) where marketing != build:
            return "\(marketing) (\(build))"
        case let (marketing?, _):
            return marketing
        case let (_, build?):
            return build
        default:
            return "Development"
        }
    }
}
