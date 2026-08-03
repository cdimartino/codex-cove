import Foundation
import ServiceManagement

final class CoveLaunchAtLoginService {
    private var lastRequestedValue: Bool?

    func sync(enabled: Bool) {
        guard lastRequestedValue != enabled else { return }
        lastRequestedValue = enabled

        let service = SMAppService.mainApp
        do {
            if enabled, service.status == .notRegistered {
                try service.register()
            } else if !enabled, service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            NSLog("CoveLaunchAtLoginService failed: \(error)")
        }
    }

    @discardableResult
    func unregisterIfRegistered() -> Bool {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            do {
                try service.unregister()
                lastRequestedValue = false
                return true
            } catch {
                NSLog("CoveLaunchAtLoginService unregister failed: \(error)")
                return false
            }
        case .notFound, .notRegistered:
            lastRequestedValue = false
            return true
        @unknown default:
            NSLog("CoveLaunchAtLoginService encountered an unknown registration status")
            return false
        }
    }
}
