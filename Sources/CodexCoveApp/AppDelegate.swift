import AppKit
import Combine
import Darwin
import SwiftUI
import CoveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    ObservableObject {
    private static let conservativeCaptureBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "com.loom.desktop",
        "com.obsproject.obs-studio",
    ]
    private static let codexDesktopBundleIdentifiers: Set<String> = [
        "com.openai.codex",
    ]

    // Declared first so maintenance launches can be isolated before any normal
    // UI or deferred service is started. The instance lock is still acquired
    // before the initializer constructs storage or CoveStore; retaining its
    // descriptor here owns the lock for app lifetime.
    private let uiTestConfiguration: CoveUITestConfiguration?
    private let maintenanceLaunchMode: CoveMaintenanceLaunchMode?
    private let instanceLock: CoveInstanceLock
    let store: CoveStore
    let workspaceStore: CoveWorkspaceStore
    private let overlayController: CoveOverlayController
    private let broker: CoveUnixSocketBroker
    private let remoteRelayManager: CoveRemoteRelayManager
    private let shortcuts: CoveKeyboardShortcutBroker
    private let terminalJumpService: CoveTerminalJumping
    private let metadataBridge: CoveMetadataBridge
    private var notificationService: CoveNotificationService?
    private var startupNotificationBuffer = CoveStartupNotificationBuffer()
    private let soundService = CoveSoundService()
    private let launchAtLoginService = CoveLaunchAtLoginService()
    private let sharedPrivacyBridge = CoveSharedPrivacyBridge()
    private let dismissedSessionStore: CoveDismissedSessionStore
    private var usageHydrator: CoveAccountUsageHydrator?
    private var desktopThreadHydrator: CoveDesktopThreadHydrator?
    private var desktopOwnedThreadController:
        CoveDesktopOwnedThreadControlClient?
    private var desktopHydrationExcludedSessionIDs = Set<String>()
    private var lastSharedPrivacyMode: CovePrivacyMode?
    private var cancellables: Set<AnyCancellable> = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var behaviorTimer: Timer?
    private var inFlightReminderIdentities = Set<CoveSessionIdentity>()
    private var settingsWindowController: NSWindowController?
    private var workspaceWindowController: NSWindowController?
    private var workspaceReconciliationTimer: Timer?
    private var restoresOverlayAfterWorkspace = false
    private struct RoutedThreadControlRoute {
        var launchId: String
        var socketPath: String
        var route: CoveThreadControlRoute
    }
    /// Ephemeral only: private socket locations must never enter settings,
    /// session metadata, diagnostics, or workspace persistence.
    private var routedThreadControlRoutes: [
        CoveSessionIdentity: RoutedThreadControlRoute
    ] = [:]
    private var uiTestBackdropWindow: NSWindow?
    private var eventVisibilityPolicy = CoveEventVisibilityPolicy()
    private var completedInitialLaunch = false
    private var revealRequestedDuringLaunch = false
    private var instanceRevealObserver: NSObjectProtocol?
    private let launchedAt = Date()
    private var deferredServicesStarted = false

    var isMaintenanceLaunch: Bool {
        maintenanceLaunchMode != nil
    }

    override init() {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let uiTestConfiguration = CoveUITestConfiguration.detect(
            bundleIdentifier: bundleIdentifier
        )
        if bundleIdentifier == CoveUITestConfiguration.hostBundleIdentifier,
           uiTestConfiguration == nil {
            NSLog(
                "Codex Cove UI-test host refused launch without a valid isolated fixture configuration."
            )
            Darwin.exit(EXIT_FAILURE)
        }
        self.uiTestConfiguration = uiTestConfiguration
        let maintenanceLaunchMode = uiTestConfiguration == nil
            ? CoveMaintenanceLaunchMode(
                arguments: ProcessInfo.processInfo.arguments
            )
            : nil
        self.maintenanceLaunchMode = maintenanceLaunchMode
        do {
            if let uiTestConfiguration {
                instanceLock = try CoveInstanceLock.acquire(
                    runtimeDirectory: uiTestConfiguration.runtimeURL
                )
            } else {
                instanceLock = try CoveInstanceLock.acquire()
            }
        } catch let error as CoveInstanceLock.AcquisitionError {
            switch error {
            case let .alreadyRunning(ownerPID):
                CoveInstanceLock.revealExistingInstance(ownerPID: ownerPID)
                Darwin.exit(
                    maintenanceLaunchMode == nil
                        ? EXIT_SUCCESS
                        : EXIT_FAILURE
                )
            default:
                NSLog("Codex Cove refused unsafe startup: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        } catch {
            NSLog("Codex Cove instance lock failed: \(error.localizedDescription)")
            Darwin.exit(EXIT_FAILURE)
        }

        let storage = CoveFileStateStorage(
            url: uiTestConfiguration?.settingsURL
                ?? CoveStateFilesystem.applicationSupportURL()
        )
        let remoteRelayManager = CoveRemoteRelayManager()
        self.remoteRelayManager = remoteRelayManager
        let decisionSender: any CoveDecisionSending
        if let uiTestConfiguration {
            decisionSender = uiTestConfiguration.decisionRecorder
        } else {
            decisionSender = remoteRelayManager
        }
        let store = CoveStore(
            storage: storage,
            decisionSender: decisionSender,
            themeStorage: uiTestConfiguration.map {
                CoveThemeFileStore(directoryURL: $0.themesURL)
            } ?? .applicationSupportStore(),
            initialState: uiTestConfiguration?.initialState,
            persistenceWritesEnabledOverride: uiTestConfiguration == nil
                ? nil
                : false,
            initialSoundPreferences: uiTestConfiguration == nil
                ? nil
                : CoveSoundPreferences(),
            soundWritesEnabled: uiTestConfiguration == nil,
            initialCustomThemes: uiTestConfiguration == nil ? nil : [],
            decisionSuccessFeedbackDuration: .milliseconds(700),
            openExternalURL: uiTestConfiguration == nil
                ? { NSWorkspace.shared.open($0) }
                : { _ in true }
        )
        self.store = store
        self.workspaceStore = CoveWorkspaceStore(
            storage: CoveWorkspaceFileStorage(
                url: uiTestConfiguration?.workspaceURL
                    ?? CoveStateFilesystem.workspaceURL()
            ),
            initialState: uiTestConfiguration == nil
                ? nil : CoveWorkspaceState(),
            writesEnabled: uiTestConfiguration == nil
        )
        self.overlayController = CoveOverlayController()
        self.broker = CoveUnixSocketBroker(socketPath: CoveDefaultPaths.socketPath)
        self.shortcuts = CoveKeyboardShortcutBroker()
        self.terminalJumpService = uiTestConfiguration == nil
            ? CoveSystemTerminalJumpService()
            : CoveUITestTerminalJumpService(
                failsJumps: uiTestConfiguration?.fixture == .openFailure
            ) { [weak store] in
                store?.recordFixtureJump()
            }
        self.metadataBridge = CoveMetadataBridge()
        self.dismissedSessionStore = CoveDismissedSessionStore(
            url: uiTestConfiguration?.dismissedSessionsURL
                ?? CoveStateFilesystem.applicationSupportDirectoryURL()
                    .appendingPathComponent("dismissed-sessions.json")
        )
        super.init()
        uiTestConfiguration?.decisionRecorder.setRecordHandler {
            [weak store] count, _ in
            Task { @MainActor [weak store] in
                store?.recordFixtureDecisionReceipt(count: count)
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard maintenanceLaunchMode == nil else { return }

        let distributedCenter = DistributedNotificationCenter.default()
        instanceRevealObserver = distributedCenter.addObserver(
            forName: CoveInstanceLock.revealNotification,
            object: Bundle.main.bundleIdentifier ?? "local.chris.codexcove",
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.completedInitialLaunch {
                    self.showCove()
                } else {
                    self.revealRequestedDuringLaunch = true
                }
            }
        }
        installUserRevealAppleEventHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let maintenanceLaunchMode {
            let succeeded: Bool
            switch maintenanceLaunchMode {
            case .unregisterLoginItem:
                succeeded = launchAtLoginService.unregisterIfRegistered()
            case .syncLoginItem:
                guard store.persistenceWarning == nil else {
                    NSLog(
                        "Codex Cove could not sync Launch at Login because "
                            + "persisted settings could not be loaded."
                    )
                    Darwin.exit(EXIT_FAILURE)
                }
                succeeded = launchAtLoginService.sync(
                    enabled: store.state.settings.launchAtLogin
                )
            case .invalid:
                NSLog("Codex Cove received conflicting maintenance launch arguments.")
                succeeded = false
            }

            guard succeeded else {
                Darwin.exit(EXIT_FAILURE)
            }
            Darwin.exit(EXIT_SUCCESS)
        }

        NSApp.setActivationPolicy(.accessory)
        if let backdrop = uiTestConfiguration?.backdrop {
            showUITestBackdrop(backdrop)
        }
        store.onJumpToSession = { [weak self] snapshot in
            self?.terminalJumpService.jump(to: snapshot)
                ?? CoveJumpResult(
                    focusedExactLocation: false,
                    message: "The exact originating Codex location is not currently available."
                )
        }
        store.onOpenDirectRequest = { [weak self] snapshot in
            self?.terminalJumpService.jump(to: snapshot)
                ?? CoveJumpResult(
                    focusedExactLocation: false,
                    message: "The exact originating Codex location is not currently available."
                )
        }
        if uiTestConfiguration == nil {
            store.onMarkRead = { [weak self] identity in
                self?.metadataBridge.markRead(identity: identity)
            }
            store.onDismissSession = { [weak self] identity in
                self?.archiveSession(identity) ?? false
            }
            store.onDismissSessions = { [weak self] identities in
                self?.archiveSessions(identities) ?? false
            }
            store.onSetPinned = { [weak self] identity, pinned in
                self?.metadataBridge.setPinned(
                    identity: identity,
                    pinned: pinned
                ) ?? false
            }
            store.onScheduleFollowUp = { [weak self] identity, date in
                self?.metadataBridge.scheduleReminder(
                    identity: identity,
                    at: date
                ) ?? false
            }
            store.onCancelFollowUp = { [weak self] identity in
                self?.metadataBridge.clearReminder(identity: identity) ?? false
            }
        } else {
            // Fixture actions remain fully interactive while never writing to
            // the user's Codex metadata or Application Support state.
            store.onMarkRead = { _ in }
            store.onDismissSession = { _ in true }
            store.onDismissSessions = { _ in true }
            store.onSetPinned = { _, _ in true }
            store.onScheduleFollowUp = { _, _ in true }
            store.onCancelFollowUp = { _ in true }
        }
        overlayController.attach(
            store: store,
            onOpenWorkspace: { [weak self] in
                self?.showWorkspace()
            },
            onOpenSettings: { [weak self] in
                self?.showSettings()
            },
            onRestoreArchived: { [weak self] sessionID in
                self?.restoreArchivedSession(sessionID)
            },
            fixtureStateDirectory: uiTestConfiguration?.stateDirectory.path
        )

        store.$state
            .sink { [weak self] state in
                self?.overlayController.update(with: state)
            }
            .store(in: &cancellables)

        store.$state
            .map(\.settings)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self,
                      self.deferredServicesStarted,
                      self.uiTestConfiguration == nil
                else { return }
                self.syncServices(with: self.store.state)
            }
            .store(in: &cancellables)

        if uiTestConfiguration?.fixture == .collapsedCue
            || uiTestConfiguration?.fixture == .minimalCue {
            // Preserve the fixture's collapsed presentation. Calling showCove()
            // would deliberately begin an interaction and expand it before
            // XCUITest can inspect the collapsed accessibility surface.
            overlayController.show()
        } else if store.state.settings.launchAtLogin && !revealRequestedDuringLaunch {
            // Login launches stay unobtrusive. User-initiated reopens always
            // use applicationShouldHandleReopen below.
            overlayController.show()
        } else {
            // Direct launch is deliberate interaction: reveal Cove long
            // enough to be discoverable, then honor normal collapse/hide.
            showCove()
        }
        completedInitialLaunch = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.startDeferredServices()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showCove()
        return false
    }

    private func showUITestBackdrop(_ backdrop: CoveUITestBackdrop) {
        guard let screen = NSScreen.main else { return }
        let color: NSColor = backdrop == .white ? .white : .black
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.backgroundColor = color
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue - 1
        )
        window.orderFrontRegardless()
        uiTestBackdropWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        broker.stop()
        remoteRelayManager.stop()
        usageHydrator?.stop()
        usageHydrator = nil
        desktopThreadHydrator?.stop()
        desktopThreadHydrator = nil
        desktopOwnedThreadController?.stop()
        desktopOwnedThreadController = nil
        workspaceReconciliationTimer?.invalidate()
        workspaceReconciliationTimer = nil
        shortcuts.stop()
        soundService.stop()
        notificationService?.onOpenSession = nil
        notificationService = nil
        startupNotificationBuffer.removeAll()
        store.cancelInteractionTimers()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        behaviorTimer?.invalidate()
        behaviorTimer = nil
        if let instanceRevealObserver {
            DistributedNotificationCenter.default().removeObserver(
                instanceRevealObserver
            )
            self.instanceRevealObserver = nil
        }
        store.flush()
    }

    func showSettings() {
        store.collapseForSettings()
        if let settingsWindowController,
           let window = settingsWindowController.window {
            presentSettingsWindow(
                window,
                controller: settingsWindowController
            )
            return
        }

        let settingsView = SettingsView(
            store: store,
            onRestoreArchived: { [weak self] sessionID in
                self?.restoreArchivedSession(sessionID)
            },
            initialPaneIdentifier: uiTestConfiguration?
                .fixture.settingsPaneIdentifier,
            importedSoundStore: uiTestConfiguration.map {
                CoveImportedSoundStore(rootURL: $0.importedSoundsURL)
            } ?? .applicationSupportStore(),
            externalSideEffectsEnabled: uiTestConfiguration == nil
        )
        let hostingView = NSHostingView(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Codex Cove Settings")
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 520)
        // Version the saved frame so the former narrow, over-tall Settings
        // layout cannot restore a clipped window after this IA migration.
        if uiTestConfiguration == nil {
            window.setFrameAutosaveName("CodexCove.Settings.v2")
        }
        window.identifier = NSUserInterfaceItemIdentifier(
            "CodexCove.Settings"
        )
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        presentSettingsWindow(window, controller: controller)
    }

    func showWorkspace() {
        if let controller = workspaceWindowController,
           let window = controller.window {
            presentWorkspaceWindow(window, controller: controller)
            return
        }
        let root = CoveWorkspaceWindowView(
            store: store,
            workspace: workspaceStore,
            onClose: { [weak self] in self?.closeWorkspace() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Codex Cove Workspace")
        window.contentView = NSHostingView(rootView: root)
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.identifier = .init("CodexCove.Workspace")
        window.delegate = self
        window.tabbingMode = .disallowed
        let frameName = "CodexCove.Workspace.v1"
        let restoredFrame = uiTestConfiguration == nil
            ? window.setFrameUsingName(frameName)
            : false
        if uiTestConfiguration == nil {
            window.setFrameAutosaveName(frameName)
        }
        if !restoredFrame { window.center() }
        let controller = NSWindowController(window: window)
        workspaceWindowController = controller
        presentWorkspaceWindow(window, controller: controller)
    }

    func closeWorkspace() {
        workspaceWindowController?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindowController?.window {
            store.endSettingsPresentation()
        }
        if window === workspaceWindowController?.window {
            workspaceReconciliationTimer?.invalidate()
            workspaceReconciliationTimer = nil
            overlayController.setWorkspaceSuppressed(false)
            if restoresOverlayAfterWorkspace {
                overlayController.show()
            }
            restoresOverlayAfterWorkspace = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func presentWorkspaceWindow(
        _ window: NSWindow,
        controller: NSWindowController
    ) {
        if !window.isVisible {
            restoresOverlayAfterWorkspace = overlayController.isVisible
            overlayController.setWorkspaceSuppressed(true)
        }
        window.collectionBehavior = [.moveToActiveSpace, .managed]
        window.level = .normal
        window.hidesOnDeactivate = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        updateCapturePrivacy(using: store.state, allowLockedExit: true)
        desktopThreadHydrator?.reconcileLoadedDesktopThreads()
        workspaceReconciliationTimer?.invalidate()
        workspaceReconciliationTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard window?.isVisible == true else { return }
                self?.desktopThreadHydrator?.reconcileLoadedDesktopThreads()
            }
        }
    }

    private func presentSettingsWindow(
        _ window: NSWindow,
        controller: NSWindowController
    ) {
        // Settings is intentionally a single reusable AppKit window instead
        // of another panel. Moving it to the active Space before ordering it
        // avoids the LSUIElement/accessory-app behavior where an existing
        // Settings window can remain behind Codex on a different Space.
        window.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .managed,
        ]
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.isVisible {
            window.orderOut(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // Activation and Space movement are asynchronous for accessory apps.
        // Reasserting the same window on the next run-loop turn keeps it above
        // a normal-level Codex window without allocating a replacement.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func toggleOverlay() {
        if store.state.settings.minimalIslandMode
            || !store.state.session.isVisible {
            restoreIsland()
        } else {
            overlayController.toggleVisibility()
        }
    }

    func showCove() {
        NSLog("Cove user reveal requested")
        NSApp.activate(ignoringOtherApps: true)
        store.dispatch(.setMinimalIslandMode(false))
        store.dispatch(.setVisible(true))
        store.beginOverlayInteraction(releaseAfterMilliseconds: 5_000)
        overlayController.show()
    }

    private func installUserRevealAppleEventHandlers() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(
            self,
            andSelector: #selector(handleUserRevealAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
        manager.setEventHandler(
            self,
            andSelector: #selector(handleUserRevealAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
    }

    @objc
    private func handleUserRevealAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard completedInitialLaunch else { return }
        showCove()
    }

    func collapseToMenuBar() {
        store.dispatch(.setMinimalIslandMode(true))
        overlayController.show()
    }

    func restoreIsland() {
        store.dispatch(.setMinimalIslandMode(false))
        store.dispatch(.setVisible(true))
        overlayController.show()
        store.beginOverlayInteraction()
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func restoreArchivedSession(_ sessionID: String?) {
        do {
            var dismissed = try dismissedSessionStore.load()
            if let sessionID {
                dismissed.remove(sessionID)
            } else {
                dismissed.removeAll()
            }
            try dismissedSessionStore.save(dismissed)
            store.dispatch(.restoreDismissedSessionIDs(Array(dismissed)))
            guard uiTestConfiguration == nil else { return }
            let metadata = metadataBridge.restore(into: store)
            terminalJumpService.restore(metadata: metadata)
        } catch {
            NSLog("Cove archived-session recovery failed: \(error)")
        }
    }

    private func archiveSession(_ identity: CoveSessionIdentity) -> Bool {
        archiveSessions([identity])
    }

    private func archiveSessions(_ identities: [CoveSessionIdentity]) -> Bool {
        do {
            var dismissed = try dismissedSessionStore.load()
            dismissed.formUnion(identities.map(\.id))
            try dismissedSessionStore.save(dismissed)
            return true
        } catch {
            NSLog("Cove archived-session persistence failed: \(error)")
            return false
        }
    }

    func showDoctor() {
        guard uiTestConfiguration == nil else { return }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/codex-cove")
            .path
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/codex-cove")
            .path
        let executable = [installed, bundled].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let executable else {
            presentDoctor(text: "Codex Cove helper is not installed.")
            return
        }
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["doctor"]
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let text = String(decoding: data, as: UTF8.self)
                    return text.isEmpty ? "Doctor returned no details." : text
                } catch {
                    return "Doctor could not start: \(error.localizedDescription)"
                }
            }.value
            var combinedReport = report
            let databaseAmbiguities = metadataBridge.diagnostics()?
                .ambiguousLegacyIdentityCount ?? 0
            let sidecarAmbiguities = store.state
                .ambiguousLegacySessionIdentityCount
            let ambiguityCount = databaseAmbiguities + sidecarAmbiguities
            if ambiguityCount > 0 {
                combinedReport += "\nWarning: \(ambiguityCount) legacy task metadata record(s) were preserved but not applied because their origin is ambiguous."
            }
            presentDoctor(text: combinedReport)
        }
    }

    private func presentDoctor(text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Codex Cove Doctor"
        alert.informativeText = String(text.prefix(8_000))
        alert.alertStyle = text.contains("Fail") || text.contains("Warning")
            ? .warning
            : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startDeferredServices() {
        guard !deferredServicesStarted else { return }
        deferredServicesStarted = true

        if let uiTestConfiguration {
            // Deterministic fixtures do not initialize or touch any live Cove,
            // Codex, login-item, notification, sound, broker, relay, or
            // metadata integration. Their state and decision channel exist
            // only inside the per-test temporary directory/process.
            workspaceStore.onControl = { request in
                .accepted(
                    turnId: request.operation == .start
                        ? "fixture-started-turn" : request.expectedTurnId
                )
            }
            store.dispatch(.boot)
            if uiTestConfiguration.fixture.settingsPaneIdentifier != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.showSettings()
                }
            }
            return
        }

        // UI is already ordered front. Restoration and integrations now run
        // after the first AppKit presentation turn.
        loadSharedPrivacy()
        metadataBridge.initialize()
        do {
            store.dispatch(
                .restoreDismissedSessionIDs(
                    Array(try dismissedSessionStore.load())
                )
            )
        } catch {
            NSLog("Cove archived-session restore failed: \(error)")
        }
        let restoredMetadata = metadataBridge.restore(into: store)
        terminalJumpService.restore(metadata: restoredMetadata)
        store.dispatch(.boot)

        let eventHandler: @Sendable (CoveWireEnvelope) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.ingest(event)
            }
        }
        broker.onEvent = eventHandler
        remoteRelayManager.setEventHandler(eventHandler)
        broker.start()
        remoteRelayManager.start()
        startUsageHydration()
        startDesktopThreadHydration(restoredMetadata: restoredMetadata)

        shortcuts.onToggleOverlay = { [weak self] in
            self?.toggleOverlay()
        }
        shortcuts.onToggleExpanded = { [weak self] in
            guard let self else { return }
            if self.store.state.session.isExpanded {
                self.store.dispatch(.setExpanded(false))
            } else {
                self.store.beginOverlayInteraction()
            }
        }
        shortcuts.onJumpToTerminal = { [weak self] _ in
            self?.terminalJumpService.jumpToCurrent()
        }
        installEnvironmentObservers()
        refreshQuietEnvironment()
        syncServices(with: store.state)
        behaviorTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuietEnvironment()
                self?.deliverDueReminders()
            }
        }

        // Notification Center initialization and authorization are explicitly
        // outside the launch-critical path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.startNotificationService()
        }
    }

    private func startNotificationService() {
        guard uiTestConfiguration == nil, notificationService == nil else {
            return
        }
        let service = CoveNotificationService()
        service.clearNotificationsFromEarlierLaunches()
        service.onOpenSession = {
            [weak self] sessionID, launchID, turnID, source, hostID in
            guard let self else { return }
            if let snapshot = CoveNotificationOriginResolver.snapshot(
                sessionID: sessionID,
                launchID: launchID,
                source: source,
                hostID: hostID,
                in: self.store.state.session.snapshots
            ) {
                _ = self.terminalJumpService.jump(to: snapshot)
            }
            if let turnID, let source {
                service.resolveAttention(
                    sessionID: sessionID,
                    launchID: launchID,
                    turnID: turnID,
                    source: source,
                    hostID: hostID
                )
            }
        }
        notificationService = service
        service.requestAuthorizationIfNeeded(
            enabled: store.state.settings.showNotifications
        )
        flushStartupNotifications()
        deliverDueReminders()
    }

    private func syncServices(with state: CoveState) {
        guard uiTestConfiguration == nil else { return }
        let focusedBundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier
        let quietReason = CoveQuietPolicy.reason(
            settings: state.settings,
            at: Date(),
            focusedBundleIdentifier: focusedBundleIdentifier
        )
        if state.quietReason != quietReason {
            store.refreshQuietEnvironment(
                focusedBundleIdentifier: focusedBundleIdentifier
            )
        }
        if state.settings.globalShortcutsEnabled {
            shortcuts.configure(enabled: true)
        } else {
            shortcuts.configure(enabled: false)
        }
        launchAtLoginService.sync(enabled: state.settings.launchAtLogin)
        notificationService?.requestAuthorizationIfNeeded(
            enabled: state.settings.showNotifications
        )
        syncSharedPrivacy(state.settings.privacyMode)
        updateCapturePrivacy(using: state)
    }

    private func ingest(_ incomingEvent: CoveWireEnvelope) {
        let event = prepareThreadControlRoute(in: incomingEvent)
        guard !store.state.processedEventIDs.contains(event.processedEventKey) else {
            return
        }
        let approvalReviewThreadID = event.approvalReviewSubagentThreadID
        if eventVisibilityPolicy.shouldSuppress(event) {
            if let approvalReviewThreadID {
                purgeInternalSession(
                    approvalReviewThreadID,
                    source: event.source,
                    hostID: event.hostId
                )
            }
            return
        }
        if event.kind.rawValue == "privacy.changed" {
            let payload = event.payload.objectValue ?? [:]
            guard let rawMode = payload["mode"]?.stringValue,
                  let mode = sharedPrivacyBridge.mode(from: rawMode) else {
                return
            }
            lastSharedPrivacyMode = mode
            if store.state.settings.privacyMode != mode {
                store.dispatch(.setPrivacy(mode))
            }
            return
        }
        let previousState = store.state
        terminalJumpService.observe(event)
        let terminalLocation = terminalJumpService
            .terminalLocationMetadata(for: event)
        let archivedIdentity = CoveSessionIdentity(
            source: event.source,
            hostId: event.hostId,
            sessionId: event.sessionId == "pending"
                ? event.launchId ?? event.sessionId
                : event.sessionId
        )
        let isArchived = archivedIdentity.map {
            store.state.dismissedSessionIDs.contains($0.id)
        } ?? false
        store.dispatch(.receivedEnvelope(event))

        if event.resolvedRequestID() != nil
            || Self.hookEventResolvesAttention(event) {
            resolveNotificationAttention(
                sessionID: event.sessionId,
                launchID: event.launchId,
                turnID: event.turnId,
                source: event.source,
                hostID: event.hostId
            )
        }
        if Self.hookEventResolvesAttention(event) {
            store.dispatch(
                .resolveDirectRequests(
                    sessionId: event.sessionId,
                    turnId: event.turnId,
                    launchId: event.launchId,
                    source: event.source,
                    hostId: event.hostId
                )
            )
        }

        metadataBridge.record(
            event,
            state: store.state,
            observedTerminalLocation: terminalLocation
        )
        hydrateDesktopThreadIfNeeded(from: event)

        guard let notificationKind = CoveNotificationEventKind.classify(event),
              Self.acceptedAttentionTransition(
                event,
                previousState: previousState,
                currentState: store.state
              ),
              CoveLaunchAlertPolicy.eventOccurredAfterLaunch(
                event,
                launchedAt: launchedAt
              )
        else { return }

        let focusedBundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier
        let suppressesAlerts = isArchived || store.shouldSuppressAlerts(
            for: event,
            focusedBundleIdentifier: focusedBundleIdentifier
        )
        let rule = store.state.settings.notificationPreferences.rule(
            for: notificationKind
        )
        let notificationsEnabled = store.state.settings.showNotifications
            && !suppressesAlerts
        if notificationService == nil {
            if notificationsEnabled && rule.enabled {
                startupNotificationBuffer.append(
                    envelope: event,
                    kind: notificationKind
                )
            }
        } else {
            deliverNotification(
                event,
                kind: notificationKind,
                rule: rule,
                enabled: notificationsEnabled
            )
        }

        // State and panel updates win the current run-loop turn. Audio setup is
        // lower priority and never blocks attention UI becoming visible.
        let soundDelay = notificationKind == .approval ? 1.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + soundDelay) { [weak self] in
            guard let self else { return }
            guard Self.attentionIsStillCurrent(
                event,
                kind: notificationKind,
                state: self.store.state
            ) else { return }
            self.soundService.play(
                for: event,
                globallyEnabled: self.store.state.settings.playSounds
                    && !suppressesAlerts,
                preferences: self.store.soundPreferences
            )
        }
    }

    private func prepareThreadControlRoute(
        in incoming: CoveWireEnvelope
    ) -> CoveWireEnvelope {
        guard incoming.sessionId != "unknown",
              incoming.sessionId != "pending",
              let identity = CoveSessionIdentity(
                  source: incoming.source,
                  hostId: incoming.hostId,
                  sessionId: incoming.sessionId
              ),
              let launchId = incoming.launchId,
              !launchId.isEmpty,
              var payload = incoming.payload.objectValue
        else { return incoming }

        if payload["liveness"]?.stringValue == CoveSessionLiveness.closed.rawValue {
            routedThreadControlRoutes.removeValue(forKey: identity)
            return incoming
        }

        let advertisedPath: String?
        let controlRoute: CoveThreadControlRoute
        switch incoming.source {
        case .localCli:
            guard let decisionPath = payload["decisionSocket"]?.stringValue,
                  decisionPath.hasPrefix("/")
            else { return incoming }
            advertisedPath = (decisionPath as NSString)
                .deletingPathExtension + ".c"
            controlRoute = .routedLocal
        case .remoteCli:
            guard let opaquePath = payload["threadControlSocket"]?.stringValue,
                  opaquePath.hasPrefix("cove-remote-thread://")
            else { return incoming }
            advertisedPath = opaquePath
            controlRoute = .routedRemote
        case .codexDesktop:
            return incoming
        }
        guard let advertisedPath else { return incoming }
        routedThreadControlRoutes[identity] = .init(
            launchId: launchId,
            socketPath: advertisedPath,
            route: controlRoute
        )
        payload["controlRoute"] = .string(controlRoute.rawValue)
        payload["liveness"] = .string(CoveSessionLiveness.live.rawValue)
        if let turnId = incoming.authoritativeStartedTurnID() {
            payload["activeTurnId"] = .string(turnId)
        } else if incoming.endsActiveTurn {
            payload["activeTurnId"] = .null
        }
        var event = incoming
        event.payload = .object(payload)
        return event
    }

    private func purgeInternalSession(
        _ sessionID: String,
        source: CoveWireSource,
        hostID: String?
    ) {
        guard !sessionID.isEmpty else { return }
        eventVisibilityPolicy.hideApprovalReviewThread(
            sessionId: sessionID,
            source: source,
            hostId: hostID
        )
        metadataBridge.remove(
            sessionID: sessionID,
            source: source,
            hostID: hostID
        )
        resolveNotificationAttention(
            sessionID: sessionID,
            launchID: nil,
            turnID: nil,
            source: source,
            hostID: hostID
        )
        store.forgetInternalSession(
            sessionID,
            source: source,
            hostID: hostID
        )
        guard let identity = CoveSessionIdentity(
            source: source,
            hostId: hostID,
            sessionId: sessionID
        ) else { return }
        inFlightReminderIdentities.remove(identity)
        _ = metadataBridge.setPinned(identity: identity, pinned: false)
        do {
            var dismissed = try dismissedSessionStore.load()
            if dismissed.remove(identity.id) != nil {
                try dismissedSessionStore.save(dismissed)
            }
        } catch {
            NSLog("Cove internal-session cleanup failed: \(error)")
        }
    }

    private func resolveNotificationAttention(
        sessionID: String,
        launchID: String?,
        turnID: String?,
        source: CoveWireSource,
        hostID: String?
    ) {
        startupNotificationBuffer.resolve(
            sessionID: sessionID,
            launchID: launchID,
            turnID: turnID,
            source: source,
            hostID: hostID
        )
        notificationService?.resolveAttention(
            sessionID: sessionID,
            launchID: launchID,
            turnID: turnID,
            source: source,
            hostID: hostID
        )
    }

    private func flushStartupNotifications() {
        let entries = startupNotificationBuffer.drain { [store] entry in
            Self.attentionIsStillCurrent(
                entry.envelope,
                kind: entry.kind,
                state: store.state
            )
        }
        for entry in entries {
            let event = entry.envelope
            let snapshotID = event.sessionId == "pending"
                ? event.launchId ?? event.sessionId
                : event.sessionId
            let isArchived = CoveSessionIdentity(
                source: event.source,
                hostId: event.hostId,
                sessionId: snapshotID
            ).map { store.state.dismissedSessionIDs.contains($0.id) } ?? false
            let focusedBundleIdentifier = NSWorkspace.shared.frontmostApplication?
                .bundleIdentifier
            let suppressesAlerts = isArchived || store.shouldSuppressAlerts(
                for: event,
                focusedBundleIdentifier: focusedBundleIdentifier
            )
            let rule = store.state.settings.notificationPreferences.rule(
                for: entry.kind
            )
            deliverNotification(
                event,
                kind: entry.kind,
                rule: rule,
                enabled: store.state.settings.showNotifications
                    && !suppressesAlerts
            )
        }
    }

    private func deliverNotification(
        _ event: CoveWireEnvelope,
        kind: CoveNotificationEventKind,
        rule: CoveNotificationRule,
        enabled: Bool
    ) {
        guard let notificationService else { return }
        notificationService.notify(
            envelope: event,
            kind: kind,
            rule: rule,
            context: notificationContext(for: event),
            enabled: enabled,
            redactsSensitiveContent: store.state.settings.privacyMode == .on
                || store.state.privacyScene != .normal
        )
    }

    private static func attentionIsStillCurrent(
        _ event: CoveWireEnvelope,
        kind: CoveNotificationEventKind,
        state: CoveState
    ) -> Bool {
        if let request = event.directRequest() {
            return state.pendingDirectRequests.contains { $0.key == request.key }
        }
        guard let update = event.sessionStatusUpdate() else {
            return kind == .followUp
        }
        guard let origin = event.originScope else { return false }
        let snapshotID = event.sessionId == "pending"
            ? event.launchId ?? event.eventId
            : event.sessionId
        return state.session.snapshots.first {
            $0.snapshotId == snapshotID && $0.originScope == origin
        }?.status == update.status
    }

    private static func acceptedAttentionTransition(
        _ event: CoveWireEnvelope,
        previousState: CoveState,
        currentState: CoveState
    ) -> Bool {
        if let request = event.directRequest() {
            return !previousState.pendingDirectRequests.contains(where: {
                $0.key == request.key
            }) && currentState.pendingDirectRequests.contains(where: {
                $0.key == request.key
            })
        }
        guard let update = event.sessionStatusUpdate() else { return false }
        guard let origin = event.originScope else { return false }
        let snapshotID = event.sessionId == "pending"
            ? event.launchId ?? event.eventId
            : event.sessionId
        let previous = previousState.session.snapshots.first {
            $0.snapshotId == snapshotID && $0.originScope == origin
        }
        let current = currentState.session.snapshots.first {
            $0.snapshotId == snapshotID && $0.originScope == origin
        }
        return current?.status == update.status
            && current?.timestamp == event.timestamp
            && previous?.status != update.status
    }

    private static func hookEventResolvesAttention(
        _ event: CoveWireEnvelope
    ) -> Bool {
        guard event.kind.rawValue == "hook",
              let name = event.payload.objectValue?["hookEventName"]?.stringValue
        else { return false }
        return [
            "PreToolUse",
            "PostToolUse",
            "Stop",
            "SessionEnd",
            "SubagentStop",
        ].contains(name)
    }

    private func notificationContext(
        for event: CoveWireEnvelope
    ) -> CoveNotificationDisplayContext {
        let snapshot = store.state.session.snapshots.first {
            ($0.sessionId ?? $0.snapshotId) == event.sessionId
                && $0.originScope == event.originScope
        }
        let object = event.payload.objectValue ?? [:]
        let nestedData = object["data"]?.objectValue ?? [:]
        let rawProject = object["project"]?.stringValue
            ?? object["projectName"]?.stringValue
            ?? nestedData["project"]?.stringValue
            ?? nestedData["cwd"]?.stringValue
            ?? nestedData["working_directory"]?.stringValue
        let project = rawProject.map { value in
            value.contains("/")
                ? URL(fileURLWithPath: value).lastPathComponent
                : value
        }
        let agentName = nestedData["agent_name"]?.stringValue
            ?? nestedData["agentName"]?.stringValue
        let baseTitle = snapshot?.title ?? event.displayEvent().title
        return CoveNotificationDisplayContext(
            taskTitle: agentName.map { "\(baseTitle) · \($0)" } ?? baseTitle,
            detail: snapshot?.detail ?? event.displayEvent().body,
            project: project,
            source: event.source.displayName,
            host: event.hostId
        )
    }

    private func loadSharedPrivacy() {
        do {
            guard let mode = try sharedPrivacyBridge.load() else {
                return
            }
            lastSharedPrivacyMode = mode
            if store.state.settings.privacyMode != mode {
                store.dispatch(.setPrivacy(mode))
            }
        } catch {
            lastSharedPrivacyMode = store.state.settings.privacyMode
            NSLog("Cove shared privacy load failed: \(error)")
        }
    }

    private func syncSharedPrivacy(_ mode: CovePrivacyMode) {
        guard lastSharedPrivacyMode != mode else { return }
        do {
            try sharedPrivacyBridge.save(mode)
        } catch {
            NSLog("Cove shared privacy save failed: \(error)")
        }
        lastSharedPrivacyMode = mode
    }

    private func startUsageHydration() {
        guard let configuration = try? CoveAccountUsageConfiguration.installed(
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "0.6.0"
        ) else {
            return
        }
        let hydrator = CoveAccountUsageHydrator(configuration: configuration)
        usageHydrator = hydrator
        hydrator.start { [weak self] result in
            guard case let .available(snapshot) = result else { return }
            self?.store.dispatch(.receivedUsage(snapshot))
        }
    }

    private func startDesktopThreadHydration(
        restoredMetadata: [CoveSessionMetadata]
    ) {
        guard let configuration = try? CoveDesktopThreadHydrationConfiguration.installed(
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "0.6.0"
        ) else {
            return
        }
        let hydrator = CoveDesktopThreadHydrator(configuration: configuration)
        desktopThreadHydrator = hydrator
        let controlClient = CoveDesktopOwnedThreadControlClient(
            configuration: configuration,
            runtimeDirectory: uiTestConfiguration?.runtimeURL
                ?? URL(fileURLWithPath: CoveDefaultPaths.socketPath)
                    .deletingLastPathComponent()
        )
        desktopOwnedThreadController = controlClient
        controlClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in self?.ingest(event) }
        }
        workspaceStore.onControl = { [weak self] request in
            guard let self else { return .rejected(.unavailable) }
            return await self.sendThreadControl(
                request,
                desktopClient: controlClient
            )
        }
        workspaceStore.onReconcileRequested = { [weak self] in
            self?.desktopThreadHydrator?.reconcileLoadedDesktopThreads()
        }
        hydrator.start(
            onUpdate: { [weak self] result, threadID in
                guard let self else { return }
                switch result {
                case let .available(snapshot):
                    self.applyDesktopHydration(snapshot)
                case .unavailable(.hiddenApprovalReviewThread):
                    self.purgeInternalSession(
                        threadID,
                        source: .codexDesktop,
                        hostID: nil
                    )
                case let .unavailable(failure):
                    NSLog(
                        "Codex Cove: Desktop thread hydration unavailable for \(threadID): \(failure.rawValue)"
                    )
                }
            },
            onDiscovery: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .available(batch):
                    batch.hiddenApprovalReviewThreadIDs.forEach { threadID in
                        self.purgeInternalSession(
                            threadID,
                            source: .codexDesktop,
                            hostID: nil
                        )
                    }
                    self.applyDesktopReconciliation(batch)
                case let .unavailable(failure):
                    NSLog(
                        "Codex Cove: Desktop thread discovery unavailable: \(failure.rawValue)"
                    )
                }
            }
        )
        hydrator.reconcileLoadedDesktopThreads()
        // Validate only records already known to have originated in Desktop.
        // Discovery owns unknown IDs; CLI and remote records retain their
        // persisted origin and are never queried by the Desktop hydrator.
        let restorableSessionIDs = CoveDesktopThreadSnapshotParser
            .startupDesktopThreadIDs(from: restoredMetadata)
        for sessionID in restorableSessionIDs {
            hydrator.hydrate(threadID: sessionID)
        }
    }

    private func sendThreadControl(
        _ request: CoveThreadControlRequest,
        desktopClient: any CoveThreadControlling
    ) async -> CoveThreadControlResult {
        switch request.target.source {
        case .codexDesktop:
            return await desktopClient.send(request)
        case .localCli:
            guard let route = routedThreadControlRoutes[request.target],
                  route.route == .routedLocal
            else { return .rejected(.staleRoute) }
            return await CoveThreadControlSocketClient().send(
                request,
                launchId: route.launchId,
                to: route.socketPath
            )
        case .remoteCli:
            guard let route = routedThreadControlRoutes[request.target],
                  route.route == .routedRemote
            else { return .rejected(.staleRoute) }
            return await remoteRelayManager.sendThreadControl(
                request,
                launchId: route.launchId,
                routePath: route.socketPath
            )
        }
    }

    private func hydrateDesktopThreadIfNeeded(from event: CoveWireEnvelope) {
        guard event.source == .codexDesktop,
              event.kind != .sessionSnapshot,
              event.sessionId != "unknown",
              event.sessionId != "pending",
              CoveDesktopThreadClient.isSafeThreadIdentifier(event.sessionId)
        else {
            return
        }
        desktopThreadHydrator?.hydrate(threadID: event.sessionId)
    }

    private func applyDesktopHydration(_ snapshot: CoveSessionSnapshot) {
        let sessionID = snapshot.sessionId ?? snapshot.snapshotId
        guard CoveDesktopThreadSnapshotParser.canApplyDesktopSnapshot(
            snapshot,
            excluding: desktopHydrationExcludedSessionIDs,
            currentSnapshots: store.state.session.snapshots
        ) else {
            return
        }
        let payload: [String: CoveJSONValue] = [
            "snapshotId": .string(snapshot.snapshotId),
            "status": .string(snapshot.status.rawValue),
            "priority": .number(Double(snapshot.priority)),
            "title": .string(snapshot.title),
            "detail": snapshot.detail.map(CoveJSONValue.string) ?? .null,
            "latestOutput": snapshot.latestOutput.map(CoveJSONValue.string)
                ?? .null,
            "unread": .bool(snapshot.unread),
            "parentThreadId": snapshot.parentSessionId.map(CoveJSONValue.string)
                ?? .null,
            "liveness": snapshot.liveness.map { .string($0.rawValue) }
                ?? .null,
            "activeTurnId": snapshot.activeTurnId.map(CoveJSONValue.string)
                ?? .null,
            "controlRoute": snapshot.controlRoute.map { .string($0.rawValue) }
                ?? .null,
        ]
        let timestampMilliseconds = Int(
            (snapshot.timestamp.timeIntervalSince1970 * 1_000).rounded()
        )
        let envelope = CoveWireEnvelope(
            eventId: "desktop-hydration-\(sessionID)-\(timestampMilliseconds)",
            kind: .sessionSnapshot,
            timestamp: snapshot.timestamp,
            source: .codexDesktop,
            sessionId: sessionID,
            payload: .object(payload)
        )
        guard !store.state.processedEventIDs.contains(envelope.processedEventKey) else {
            return
        }
        terminalJumpService.observe(envelope)
        store.dispatch(.receivedEnvelope(envelope))
        metadataBridge.record(envelope, state: store.state)
    }

    private func applyDesktopReconciliation(
        _ batch: CoveDesktopThreadDiscoveryBatch
    ) {
        batch.snapshots.forEach(applyDesktopHydration)
        guard batch.loadedThreadSetIsComplete else { return }
        let loaded = Set(batch.loadedThreadIDs)
        for current in store.state.session.snapshots
        where current.source == .codexDesktop {
            let identity = current.sessionId ?? current.snapshotId
            guard !loaded.contains(identity) else { continue }
            var closed = current
            closed.liveness = .closed
            closed.controlRoute = nil
            closed.activeTurnId = nil
            closed.timestamp = max(closed.timestamp, Date())
            store.dispatch(.receivedSnapshot(closed))
        }
    }

    private func installEnvironmentObservers() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.store.endOverlayInteraction()
                }
            }
        )

        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: workspace, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.remoteRelayManager.prepareForSleep()
                    self?.store.dispatch(.setVisible(false))
                    self?.store.dispatch(.setPrivacyScene(.locked))
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: workspace, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.remoteRelayManager.resumeAndReload()
                    self?.usageHydrator?.refreshNow()
                    self?.store.dispatch(.setVisible(true))
                    self?.updateCapturePrivacy(using: self?.store.state ?? CoveState())
                    self?.overlayController.show()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: workspace, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.store.dispatch(.setVisible(false))
                    self?.store.dispatch(.setPrivacyScene(.locked))
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: workspace, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.usageHydrator?.refreshNow()
                    self?.store.dispatch(.setVisible(true))
                    self?.updateCapturePrivacy(
                        using: self?.store.state ?? CoveState(),
                        allowLockedExit: true
                    )
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: workspace, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.overlayController.update(with: self?.store.state ?? CoveState())
                }
            }
        )

        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            notificationTokens.append(
                center.addObserver(forName: name, object: workspace, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.updateCapturePrivacy(using: self.store.state)
                        self.refreshQuietEnvironment()
                    }
                }
            )
        }
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: workspace, queue: .main) { [weak self] notification in
                let bundleIdentifier = (
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                )?.bundleIdentifier
                Task { @MainActor in
                    guard let self else { return }
                    let activeBundleIdentifier = bundleIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    if activeBundleIdentifier != Bundle.main.bundleIdentifier {
                        self.store.endOverlayInteraction()
                    }
                    guard let activeBundleIdentifier,
                          Self.codexDesktopBundleIdentifiers.contains(activeBundleIdentifier)
                    else {
                        return
                    }
                    self.desktopThreadHydrator?.reconcileLoadedDesktopThreads()
                }
            }
        )
    }

    private func updateCapturePrivacy(
        using state: CoveState,
        allowLockedExit: Bool = false
    ) {
        let shouldRedact: Bool
        if state.settings.privacyMode == .auto,
           state.settings.conservativeCapturePrivacy {
            shouldRedact = NSWorkspace.shared.runningApplications.contains { application in
                guard let identifier = application.bundleIdentifier else { return false }
                return Self.conservativeCaptureBundleIdentifiers.contains(identifier)
            }
        } else {
            shouldRedact = false
        }
        let desired = state.privacyScene.resolvingCapturePrivacy(
            isCapturePrivacyActive: shouldRedact,
            allowLockedExit: allowLockedExit
        )
        if state.privacyScene != desired {
            store.dispatch(.setPrivacyScene(desired))
        }
    }

    private func refreshQuietEnvironment() {
        store.refreshQuietEnvironment(
            focusedBundleIdentifier: NSWorkspace.shared.frontmostApplication?
                .bundleIdentifier
        )
    }

    private func deliverDueReminders() {
        guard store.state.settings.showNotifications,
              let notificationService
        else { return }
        let rule = store.state.settings.notificationPreferences.rule(
            for: .followUp
        )
        guard rule.enabled else { return }
        let focusedBundleIdentifier = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier
        for metadata in metadataBridge.dueReminders() {
            guard let identity = metadata.sessionIdentity else { continue }
            if let reminderAt = metadata.reminderAt,
               reminderAt < launchedAt {
                _ = metadataBridge.clearReminder(identity: identity)
                continue
            }
            guard !store.state.dismissedSessionIDs.contains(identity.id)
            else { continue }
            guard inFlightReminderIdentities.insert(identity).inserted
            else { continue }
            let snapshot = store.state.session.snapshots.first {
                $0.sessionId == metadata.sessionId
                    && $0.originScope == CoveOriginScope(
                        source: metadata.source,
                        hostId: metadata.hostId
                    )
            }
            guard !store.shouldSuppressAlerts(
                for: snapshot,
                focusedBundleIdentifier: focusedBundleIdentifier
            ) else {
                inFlightReminderIdentities.remove(identity)
                continue
            }
            notificationService.notifyFollowUp(
                sessionID: metadata.sessionId,
                launchID: metadata.launchId,
                source: metadata.source,
                hostID: metadata.hostId,
                title: snapshot?.title,
                rule: rule,
                enabled: true,
                redactsSensitiveContent: store.state.settings.privacyMode == .on
                    || store.state.privacyScene != .normal
            ) { [weak self] delivered in
                Task { @MainActor in
                    guard let self else { return }
                    guard delivered else {
                        self.inFlightReminderIdentities.remove(identity)
                        return
                    }
                    // Clear only after the notification center accepted the
                    // request. If the durable clear fails, retain the in-flight
                    // marker to avoid duplicate delivery during this launch.
                    if self.metadataBridge.clearReminder(
                        identity: identity
                    ) {
                        self.inFlightReminderIdentities.remove(identity)
                        self.store.didDeliverFollowUp(
                            identity: identity
                        )
                    }
                }
            }
        }
    }
}

private struct CoveDismissedSessionStore {
    private struct Document: Codable {
        var schemaVersion: Int
        var sessionIDs: [String]
    }

    private let url: URL

    init(
        url: URL = CoveStateFilesystem.applicationSupportDirectoryURL()
            .appendingPathComponent("dismissed-sessions.json")
    ) {
        self.url = url
    }

    func load() throws -> Set<String> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
        )
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1 || document.schemaVersion == 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Set(document.sessionIDs.prefix(1_000).filter(isValid))
    }

    func save(_ sessionIDs: Set<String>) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let document = Document(
            schemaVersion: 2,
            sessionIDs: Array(sessionIDs.filter(isValid)).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 2_048
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}
