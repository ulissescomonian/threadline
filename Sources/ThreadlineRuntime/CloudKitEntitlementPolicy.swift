import Foundation
import Security

/// Decides whether it is safe to construct a `CKContainer` for the current
/// process. `CKContainer(identifier:)` traps when the requested container is
/// absent from the code signature, so this check must happen before CloudKit
/// is initialized and cannot be replaced by ordinary error handling.
enum CloudKitEntitlementPolicy {
    static let containerIdentifiersKey = "com.apple.developer.icloud-container-identifiers"
    static let servicesKey = "com.apple.developer.icloud-services"

    static func currentProcessAuthorizes(containerIdentifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
        let containers = SecTaskCopyValueForEntitlement(
            task,
            containerIdentifiersKey as CFString,
            nil
        )
        let services = SecTaskCopyValueForEntitlement(
            task,
            servicesKey as CFString,
            nil
        )
        return authorizes(
            containerIdentifier: containerIdentifier,
            containerIdentifiers: containers,
            services: services
        )
    }

    static func authorizes(
        containerIdentifier: String,
        containerIdentifiers: CFTypeRef?,
        services: CFTypeRef?
    ) -> Bool {
        guard let containerIdentifiers = containerIdentifiers as? [String],
              containerIdentifiers.contains(containerIdentifier),
              let services = services as? [String],
              services.contains("CloudKit")
        else { return false }
        return true
    }
}
