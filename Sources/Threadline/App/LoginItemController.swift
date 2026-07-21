import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItemController {
    enum State: Equatable {
        case enabled
        case requiresApproval
        case disabled
        case unavailable(String)
    }

    private(set) var state: State = .disabled
    private(set) var operationError: String?
    private(set) var isChanging = false
    private let service = SMAppService.mainApp

    var isRequestedEnabled: Bool {
        switch state {
        case .enabled, .requiresApproval: true
        case .disabled, .unavailable: false
        }
    }

    init() {
        refresh()
    }

    func setEnabled(_ shouldEnable: Bool) {
        guard !isChanging else { return }
        isChanging = true
        operationError = nil
        defer { isChanging = false }

        do {
            if shouldEnable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            refreshState()
            operationError = "Threadline couldn’t update its Start at Login setting. \(error.localizedDescription)"
            return
        }
        refreshState()
    }

    func refresh() {
        let previousState = state
        refreshState()
        if state != previousState {
            operationError = nil
        }
    }

    func dismissOperationError() {
        operationError = nil
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshState() {
        state = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable(
            "macOS can’t register this local copy of Threadline because its app signature isn’t eligible. A properly Apple-signed build is required to start it at login."
        )
        @unknown default: .unavailable("macOS returned an unknown status for Threadline’s login item.")
        }
    }
}
