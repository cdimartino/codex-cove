import Foundation
import ServiceManagement

enum CoveMaintenanceLaunchMode: Equatable {
    static let unregisterLoginItemArgument = "--unregister-login-item-and-quit"
    static let syncLoginItemArgument = "--sync-login-item-and-quit"

    case unregisterLoginItem
    case syncLoginItem
    case invalid

    init?(arguments: [String]) {
        let requestsUnregister = arguments.contains(
            Self.unregisterLoginItemArgument
        )
        let requestsSync = arguments.contains(Self.syncLoginItemArgument)

        switch (requestsUnregister, requestsSync) {
        case (false, false):
            return nil
        case (true, false):
            self = .unregisterLoginItem
        case (false, true):
            self = .syncLoginItem
        case (true, true):
            self = .invalid
        }
    }
}

protocol CoveLaunchAtLoginManaging: AnyObject {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
}

extension SMAppService: CoveLaunchAtLoginManaging {}

final class CoveLaunchAtLoginService {
    private let service: any CoveLaunchAtLoginManaging
    private var lastRequestedValue: Bool?

    init(service: any CoveLaunchAtLoginManaging = SMAppService.mainApp) {
        self.service = service
    }

    @discardableResult
    func sync(enabled: Bool) -> Bool {
        guard lastRequestedValue != enabled else { return true }

        do {
            switch (enabled, service.status) {
            case (true, .notRegistered):
                try service.register()
            case (true, .enabled), (true, .requiresApproval):
                break
            case (true, .notFound):
                NSLog("CoveLaunchAtLoginService could not find the main app service")
                return false
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            case (false, .notFound), (false, .notRegistered):
                break
            @unknown default:
                NSLog(
                    "CoveLaunchAtLoginService encountered an unknown registration status"
                )
                return false
            }
            lastRequestedValue = enabled
            return true
        } catch {
            NSLog("CoveLaunchAtLoginService failed: \(error)")
            return false
        }
    }

    @discardableResult
    func unregisterIfRegistered() -> Bool {
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
