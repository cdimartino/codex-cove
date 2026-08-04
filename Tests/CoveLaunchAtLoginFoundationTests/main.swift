import Foundation
import ServiceManagement

private struct FoundationTestRunner {
    private(set) var assertionCount = 0

    mutating func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertionCount += 1
        guard condition() else {
            fatalError(
                "Launch-at-login foundation test failed at \(file):\(line): \(message)"
            )
        }
    }
}

private enum ForcedServiceError: Error {
    case requested
}

private final class FakeLaunchAtLoginService: CoveLaunchAtLoginManaging {
    var status: SMAppService.Status
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var registerFailuresRemaining = 0
    var unregisterFailuresRemaining = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if registerFailuresRemaining > 0 {
            registerFailuresRemaining -= 1
            throw ForcedServiceError.requested
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if unregisterFailuresRemaining > 0 {
            unregisterFailuresRemaining -= 1
            throw ForcedServiceError.requested
        }
        status = .notRegistered
    }
}

private func testMaintenanceArgumentParsing(
    _ runner: inout FoundationTestRunner
) {
    runner.expect(
        CoveMaintenanceLaunchMode(arguments: ["Codex Cove"]) == nil,
        "a normal launch must not select maintenance mode"
    )
    runner.expect(
        CoveMaintenanceLaunchMode(arguments: [
            "Codex Cove",
            CoveMaintenanceLaunchMode.syncLoginItemArgument,
        ]) == .syncLoginItem,
        "the sync argument must select sync maintenance"
    )
    runner.expect(
        CoveMaintenanceLaunchMode(arguments: [
            "Codex Cove",
            CoveMaintenanceLaunchMode.unregisterLoginItemArgument,
        ]) == .unregisterLoginItem,
        "the unregister argument must preserve unregister maintenance"
    )
    runner.expect(
        CoveMaintenanceLaunchMode(arguments: [
            CoveMaintenanceLaunchMode.syncLoginItemArgument,
            CoveMaintenanceLaunchMode.unregisterLoginItemArgument,
        ]) == .invalid,
        "conflicting maintenance arguments must be rejected"
    )
}

private func testEnableAndDisableTransitions(
    _ runner: inout FoundationTestRunner
) {
    let enableItem = FakeLaunchAtLoginService(status: .notRegistered)
    let enableService = CoveLaunchAtLoginService(service: enableItem)
    runner.expect(
        enableService.sync(enabled: true),
        "enabling a nonregistered service must succeed"
    )
    runner.expect(enableItem.status == .enabled, "enable must register the service")
    runner.expect(enableItem.registerCallCount == 1, "enable must register once")
    runner.expect(
        enableService.sync(enabled: true),
        "a repeated successful enable must remain successful"
    )
    runner.expect(
        enableItem.registerCallCount == 1,
        "a repeated successful enable must use the request cache"
    )

    let disableItem = FakeLaunchAtLoginService(status: .enabled)
    let disableService = CoveLaunchAtLoginService(service: disableItem)
    runner.expect(
        disableService.sync(enabled: false),
        "disabling an enabled service must succeed"
    )
    runner.expect(
        disableItem.status == .notRegistered,
        "disable must unregister the service"
    )
    runner.expect(
        disableItem.unregisterCallCount == 1,
        "disable must unregister once"
    )
}

private func testNoOpStates(_ runner: inout FoundationTestRunner) {
    let enabledItem = FakeLaunchAtLoginService(status: .enabled)
    runner.expect(
        CoveLaunchAtLoginService(service: enabledItem).sync(enabled: true),
        "an enabled service already satisfies an enable request"
    )
    runner.expect(
        enabledItem.registerCallCount == 0 && enabledItem.unregisterCallCount == 0,
        "an enabled service must not be mutated for an enable request"
    )

    let approvalItem = FakeLaunchAtLoginService(status: .requiresApproval)
    runner.expect(
        CoveLaunchAtLoginService(service: approvalItem).sync(enabled: true),
        "a pending approval already represents a successful enable request"
    )
    runner.expect(
        approvalItem.registerCallCount == 0 && approvalItem.unregisterCallCount == 0,
        "a pending approval must not be re-registered"
    )

    let disabledItem = FakeLaunchAtLoginService(status: .notRegistered)
    runner.expect(
        CoveLaunchAtLoginService(service: disabledItem).sync(enabled: false),
        "a nonregistered service already satisfies a disable request"
    )
    runner.expect(
        disabledItem.registerCallCount == 0 && disabledItem.unregisterCallCount == 0,
        "a nonregistered service must not be mutated for a disable request"
    )
}

private func testRetryAfterFailures(_ runner: inout FoundationTestRunner) {
    let registerItem = FakeLaunchAtLoginService(status: .notRegistered)
    registerItem.registerFailuresRemaining = 1
    let registerService = CoveLaunchAtLoginService(service: registerItem)
    runner.expect(
        !registerService.sync(enabled: true),
        "a thrown registration error must fail the sync"
    )
    runner.expect(
        registerService.sync(enabled: true),
        "a failed registration must remain retryable"
    )
    runner.expect(
        registerItem.registerCallCount == 2 && registerItem.status == .enabled,
        "the registration retry must reach the enabled state"
    )

    let unregisterItem = FakeLaunchAtLoginService(status: .enabled)
    unregisterItem.unregisterFailuresRemaining = 1
    let unregisterService = CoveLaunchAtLoginService(service: unregisterItem)
    runner.expect(
        !unregisterService.sync(enabled: false),
        "a thrown unregistration error must fail the sync"
    )
    runner.expect(
        unregisterService.sync(enabled: false),
        "a failed unregistration must remain retryable"
    )
    runner.expect(
        unregisterItem.unregisterCallCount == 2
            && unregisterItem.status == .notRegistered,
        "the unregistration retry must reach the nonregistered state"
    )
}

private func testNotFoundBehavior(_ runner: inout FoundationTestRunner) {
    let enableItem = FakeLaunchAtLoginService(status: .notFound)
    runner.expect(
        !CoveLaunchAtLoginService(service: enableItem).sync(enabled: true),
        "a missing service cannot satisfy an enable request"
    )
    runner.expect(
        enableItem.registerCallCount == 0 && enableItem.unregisterCallCount == 0,
        "a missing service must not receive a registration call"
    )

    let disableItem = FakeLaunchAtLoginService(status: .notFound)
    runner.expect(
        CoveLaunchAtLoginService(service: disableItem).sync(enabled: false),
        "a missing service already satisfies a disable request"
    )
    runner.expect(
        disableItem.registerCallCount == 0 && disableItem.unregisterCallCount == 0,
        "disabling a missing service must be a no-op"
    )

    let maintenanceItem = FakeLaunchAtLoginService(status: .notFound)
    runner.expect(
        CoveLaunchAtLoginService(service: maintenanceItem)
            .unregisterIfRegistered(),
        "maintenance unregister must accept an already-missing service"
    )
    runner.expect(
        maintenanceItem.unregisterCallCount == 0,
        "maintenance unregister must not mutate a missing service"
    )
}

@main
private enum CoveLaunchAtLoginFoundationTests {
    static func main() {
        var runner = FoundationTestRunner()
        testMaintenanceArgumentParsing(&runner)
        testEnableAndDisableTransitions(&runner)
        testNoOpStates(&runner)
        testRetryAfterFailures(&runner)
        testNotFoundBehavior(&runner)
        print(
            "Cove launch-at-login foundation tests passed "
                + "(\(runner.assertionCount) assertions)"
        )
    }
}
