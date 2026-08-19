import Darwin
import Foundation
import CoveCore

enum CoveUITestFixture: String, CaseIterable {
    case emptyQueue = "empty-queue"
    case collapsedCue = "collapsed-cue"
    case minimalCue = "minimal-cue"
    case mixedTasks = "mixed-20"
    case workspacePrimary = "workspace-primary"
    case workspaceAgentOpenFallback = "workspace-agent-open-fallback"
    case workspaceFavicon = "workspace-favicon"
    case workspaceFaviconPrivacy = "workspace-favicon-privacy"
    case commandApproval = "command-approval"
    case fileApproval = "file-approval"
    case permissionApproval = "permission-approval"
    case singleQuestion = "single-question"
    case multiQuestion = "multi-question"
    case privacyRedacted = "privacy-redacted"
    case privacyOffHiddenStatus = "privacy-off-hidden-status"
    case privacyOffLockedWorkspace = "privacy-off-locked-workspace"
    case deliveryFailure = "delivery-failure"
    case openFailure = "open-failure"
    case archivedTasks = "archived-tasks"
    case settingsAppearance = "settings-appearance"
    case settingsResidents = "settings-residents"
    case settingsGeneral = "settings-general"
    case settingsNotifications = "settings-notifications"
    case settingsSounds = "settings-sounds"
    case settingsPrivacy = "settings-privacy"
    case settingsPrivacyRedacted = "settings-privacy-redacted"
    case settingsSessions = "settings-sessions"

    var settingsPaneIdentifier: String? {
        switch self {
        case .settingsAppearance: "appearance"
        case .settingsResidents: "residents"
        case .settingsGeneral: "general"
        case .settingsNotifications: "notifications"
        case .settingsSounds: "sounds"
        case .settingsPrivacy, .settingsPrivacyRedacted: "privacyAndQuiet"
        case .settingsSessions: "sessions"
        default: nil
        }
    }
}

enum CoveUITestBackdrop: String {
    case white
    case black
}

struct CoveUITestConfiguration {
    static let hostBundleIdentifier = "local.chris.codexcove.uitesthost"
    static let runnerBundleIdentifier =
        "local.chris.codexcove.uitests.xctrunner"
    static let fixtureDirectoryPrefix = "CodexCoveUITests-"

    let fixture: CoveUITestFixture
    let stateDirectory: URL
    let decisionRecorder: CoveUITestDecisionRecorder
    let textScaleOverride: Double?
    let backdrop: CoveUITestBackdrop?

    static func detect(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> CoveUITestConfiguration? {
        // Packaged production builds deliberately ignore these arguments.
        guard bundleIdentifier == hostBundleIdentifier,
              let fixtureRaw = value(after: "--ui-test-fixture", in: arguments),
              let fixture = CoveUITestFixture(rawValue: fixtureRaw),
              let directoryPath = value(
                  after: "--ui-test-state-dir",
                  in: arguments
              ),
              directoryPath.hasPrefix("/")
        else {
            return nil
        }

        let textScaleFlag = "--ui-test-text-scale"
        let textScaleOverride: Double?
        if arguments.contains(textScaleFlag) {
            guard arguments.filter({ $0 == textScaleFlag }).count == 1,
                  let rawValue = value(after: textScaleFlag, in: arguments),
                  let value = Double(rawValue),
                  value.isFinite,
                  CoveSettings.textScaleRange.contains(value)
            else { return nil }
            textScaleOverride = value
        } else {
            textScaleOverride = nil
        }

        let backdropFlag = "--ui-test-backdrop"
        let backdrop: CoveUITestBackdrop?
        if arguments.contains(backdropFlag) {
            guard arguments.filter({ $0 == backdropFlag }).count == 1,
                  let rawValue = value(after: backdropFlag, in: arguments),
                  let value = CoveUITestBackdrop(rawValue: rawValue)
            else { return nil }
            backdrop = value
        } else {
            backdrop = nil
        }

        let directory = URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        ).standardizedFileURL
        guard let directory = prepareTemporaryDirectory(
            requestedDirectory: directory
        ) else { return nil }
        return CoveUITestConfiguration(
            fixture: fixture,
            stateDirectory: directory,
            decisionRecorder: CoveUITestDecisionRecorder(
                failsFirstAttempt: fixture == .deliveryFailure
            ),
            textScaleOverride: textScaleOverride,
            backdrop: backdrop
        )
    }

    var initialState: CoveState {
        var state = CoveUITestFixtures.state(for: fixture)
        if let textScaleOverride {
            state.settings.textScale = textScaleOverride
        }
        return state
    }

    var initialWorkspaceState: CoveWorkspaceState {
        var workspace = CoveWorkspaceState()
        guard fixture == .workspacePrimary
            || fixture == .workspaceFavicon
            || fixture == .workspaceFaviconPrivacy
        else { return workspace }
        if fixture == .workspaceFavicon || fixture == .workspaceFaviconPrivacy {
            let root = CoveSessionIdentity(
                source: .localCli,
                hostId: nil,
                sessionId: "fixture-favicon-root"
            )!
            workspace.observe(initialState.session.snapshots)
            workspace.setLinks([
                .init(
                    label: "Loaded favicon",
                    url: URL(string: "https://loaded-favicon.com/plan")!
                ),
                .init(
                    label: "Fallback favicon",
                    url: URL(string: "https://fallback-favicon.com/plan")!
                ),
            ], for: root)
            return workspace
        }
        let root = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "fixture-agent-root"
        )!
        let child = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "fixture-agent-idle"
        )!
        workspace.observe(initialState.session.snapshots)
        workspace.setLinks([
            .init(
                label: "Parent artifact",
                url: URL(string: "https://parent-artifact.test/one")!
            ),
        ], for: root)
        workspace.setLinks([
            .init(
                label: "Child artifact",
                url: URL(string: "https://child-artifact.test/two")!
            ),
        ], for: child)
        workspace.restoreArtifactOrder(Array(workspace.artifactOrderIDs().reversed()))
        return workspace
    }

    var settingsURL: URL {
        stateDirectory.appendingPathComponent("settings.json")
    }

    func writeMarker(_ value: String, named name: String) {
        try? Data(value.utf8).write(
            to: stateDirectory.appendingPathComponent(name),
            options: .atomic
        )
    }

    var themesURL: URL {
        stateDirectory.appendingPathComponent("Themes", isDirectory: true)
    }

    var importedSoundsURL: URL {
        stateDirectory
            .appendingPathComponent("Sounds", isDirectory: true)
            .appendingPathComponent("Imported", isDirectory: true)
    }

    var dismissedSessionsURL: URL {
        stateDirectory.appendingPathComponent("dismissed-sessions.json")
    }

    var workspaceURL: URL {
        stateDirectory.appendingPathComponent("workspace.json")
    }

    var runtimeURL: URL {
        stateDirectory.appendingPathComponent("run", isDirectory: true)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    /// Validates the only two state-directory boundaries fixture mode accepts:
    /// a descendant of this host process's temporary directory, or the
    /// already-created direct child supplied by the UI-test runner container.
    ///
    /// The overrides are internal test seams. Production detection always
    /// uses the current process roots and effective user ID.
    static func prepareTemporaryDirectory(
        requestedDirectory: URL,
        fileManager: FileManager = .default,
        temporaryRootOverride: URL? = nil,
        homeDirectoryOverride: URL? = nil,
        effectiveUserID: uid_t = getuid()
    ) -> URL? {
        let requested = requestedDirectory.standardizedFileURL
        let temporaryRoot = (
            temporaryRootOverride ?? fileManager.temporaryDirectory
        ).standardizedFileURL
        if isStrictDescendant(requested, of: temporaryRoot) {
            return prepareHostTemporaryDirectory(
                requested,
                root: temporaryRoot,
                fileManager: fileManager,
                effectiveUserID: effectiveUserID
            )
        }

        let homeDirectory = (
            homeDirectoryOverride
                ?? fileManager.homeDirectoryForCurrentUser
        ).standardizedFileURL
        let runnerTemporaryRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(
                runnerBundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .standardizedFileURL

        guard requested.deletingLastPathComponent().standardizedFileURL
                == runnerTemporaryRoot,
              hasValidFixtureDirectoryName(requested.lastPathComponent),
              existingDirectoryAncestryIsSafe(
                  from: homeDirectory,
                  through: requested,
                  fileManager: fileManager,
                  requiresEveryComponent: true
              ),
              directoryHasPrivateCurrentUserOwnership(
                  requested,
                  fileManager: fileManager,
                  effectiveUserID: effectiveUserID
              )
        else { return nil }
        return requested
    }

    private static func prepareHostTemporaryDirectory(
        _ requested: URL,
        root: URL,
        fileManager: FileManager,
        effectiveUserID: uid_t
    ) -> URL? {
        guard existingDirectoryAncestryIsSafe(
            from: root,
            through: requested,
            fileManager: fileManager,
            requiresEveryComponent: false
        ) else { return nil }

        do {
            try fileManager.createDirectory(
                at: requested,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let resolved = requested.resolvingSymlinksInPath()
                .standardizedFileURL
            // Re-check after creation so a symlink introduced while creating
            // an absent suffix cannot be accepted merely because it resolves
            // to another location under the temporary root.
            guard existingDirectoryAncestryIsSafe(
                from: root,
                through: requested,
                fileManager: fileManager,
                requiresEveryComponent: true
            ) else { return nil }

            let resolvedRoot = root.resolvingSymlinksInPath()
                .standardizedFileURL
            guard isStrictDescendant(resolved, of: resolvedRoot)
            else { return nil }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: resolved.path
            )
            guard directoryHasPrivateCurrentUserOwnership(
                resolved,
                fileManager: fileManager,
                effectiveUserID: effectiveUserID
            ) else { return nil }
            return resolved
        } catch {
            return nil
        }
    }

    private static func isStrictDescendant(
        _ candidate: URL,
        of root: URL
    ) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count))
                == rootComponents
    }

    private static func hasValidFixtureDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(fixtureDirectoryPrefix) else { return false }
        let suffix = String(name.dropFirst(fixtureDirectoryPrefix.count))
        guard !suffix.isEmpty, let identifier = UUID(uuidString: suffix)
        else { return false }
        return identifier.uuidString.caseInsensitiveCompare(suffix)
            == .orderedSame
    }

    /// Checks each component at and below `root` with lstat-style attributes,
    /// never accepting symbolic links. The runner boundary requires every
    /// component to pre-exist; the host boundary may create an absent suffix.
    private static func existingDirectoryAncestryIsSafe(
        from root: URL,
        through requested: URL,
        fileManager: FileManager,
        requiresEveryComponent: Bool
    ) -> Bool {
        let root = root.standardizedFileURL
        let requested = requested.standardizedFileURL
        guard requested == root || isStrictDescendant(requested, of: root)
        else { return false }

        var cursor = root
        let rootComponents = root.pathComponents
        let requestedComponents = requested.pathComponents
        let relativeComponents = requestedComponents.dropFirst(
            rootComponents.count
        )

        let componentsToInspect = [String?](arrayLiteral: nil)
            + relativeComponents.map(Optional.some)
        for component in componentsToInspect {
            if let component {
                cursor.appendPathComponent(component, isDirectory: true)
            }
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: cursor.path
            ) else {
                return !requiresEveryComponent
            }
            guard attributes[.type] as? FileAttributeType
                    == .typeDirectory
            else { return false }
        }
        return true
    }

    private static func directoryHasPrivateCurrentUserOwnership(
        _ directory: URL,
        fileManager: FileManager,
        effectiveUserID: uid_t
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: directory.path
        ), attributes[.type] as? FileAttributeType == .typeDirectory,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == effectiveUserID,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o700
        else { return false }
        return true
    }
}

final class CoveUITestFaviconURLProtocol: URLProtocol, @unchecked Sendable {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("favicon.com") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let data = url.host == "loaded-favicon.com" ? Self.png : Data()
        let status = data.isEmpty ? 404 : 200
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum CoveUITestDecisionError: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        "Simulated decision delivery failure"
    }
}

final class CoveUITestDecisionRecorder: CoveDecisionSending, @unchecked Sendable {
    typealias RecordHandler = @Sendable (Int, CoveDecisionFrame) -> Void

    private let lock = NSLock()
    private let failsFirstAttempt: Bool
    private var attempts: [(frame: CoveDecisionFrame, socketPath: String)] = []
    private var recordHandler: RecordHandler?

    init(failsFirstAttempt: Bool = false) {
        self.failsFirstAttempt = failsFirstAttempt
    }

    var attemptCount: Int {
        lock.withLock { attempts.count }
    }

    var recordedFrames: [CoveDecisionFrame] {
        lock.withLock { attempts.map(\.frame) }
    }

    func setRecordHandler(_ handler: RecordHandler?) {
        lock.withLock {
            recordHandler = handler
        }
    }

    func send(_ frame: CoveDecisionFrame, to socketPath: String) async throws {
        let (attemptNumber, handler) = lock.withLock {
            () -> (Int, RecordHandler?) in
            attempts.append((frame, socketPath))
            return (attempts.count, recordHandler)
        }
        handler?(attemptNumber, frame)
        if failsFirstAttempt && attemptNumber == 1 {
            throw CoveUITestDecisionError.simulatedFailure
        }
    }
}

@MainActor
final class CoveUITestTerminalJumpService: CoveTerminalJumping {
    private let recordJump: () -> Void
    private let failsJumps: Bool
    private let failingSessionIDs: Set<String>

    init(
        failsJumps: Bool = false,
        failingSessionIDs: Set<String> = [],
        recordJump: @escaping () -> Void = {}
    ) {
        self.failsJumps = failsJumps
        self.failingSessionIDs = failingSessionIDs
        self.recordJump = recordJump
    }

    func observe(_ envelope: CoveWireEnvelope) {}
    func restore(metadata: [CoveSessionMetadata]) {}

    func terminalLocationMetadata(
        for envelope: CoveWireEnvelope
    ) -> CoveTerminalLocationMetadata? {
        nil
    }

    func canJump(to snapshot: CoveSessionSnapshot) -> Bool {
        !failsJumps
            && !failingSessionIDs.contains(snapshot.sessionId ?? snapshot.snapshotId)
    }

    func jump(to snapshot: CoveSessionSnapshot) -> CoveJumpResult {
        recordJump()
        if failsJumps
            || failingSessionIDs.contains(snapshot.sessionId ?? snapshot.snapshotId) {
            return CoveJumpResult(
                focusedExactLocation: false,
                message: "The exact originating Codex location is not currently available."
            )
        }
        return CoveJumpResult(
            focusedExactLocation: true,
            message: "Recorded fixture jump"
        )
    }

    func jumpToCurrent() -> CoveJumpResult {
        recordJump()
        return CoveJumpResult(
            focusedExactLocation: true,
            message: "Recorded fixture jump"
        )
    }
}

enum CoveUITestFixtures {
    static func state(for fixture: CoveUITestFixture) -> CoveState {
        var settings = CoveSettings(
            privacyMode: (
                fixture == .privacyRedacted
                    || fixture == .workspaceFaviconPrivacy
                    || fixture == .settingsPrivacyRedacted
            ) ? .on : .off,
            launchAtLogin: false,
            showNotifications: false,
            playSounds: false,
            globalShortcutsEnabled: false,
            autoExpandOnEvent: false,
            idleAutoHideSeconds: 0,
            showUsage: false,
            showProfileTokenUsage: false,
            showTokenMetrics: false
        )
        settings.panelAnimationEnabled = false
        if fixture == .minimalCue {
            settings.minimalIslandMode = true
        }
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        var snapshots: [CoveSessionSnapshot] = []
        var requests: [CoveDirectRequest] = []
        var dismissed: [String] = []

        switch fixture {
        case .emptyQueue, .minimalCue:
            break
        case .collapsedCue:
            snapshots = [
                snapshot(
                    index: 1,
                    status: .working,
                    now: now
                )
            ]
        case .mixedTasks:
            snapshots = mixedSnapshots(now: now)
        case .workspacePrimary:
            snapshots = workspaceAgentSnapshots(now: now)
            requests = [agentApproval()]
        case .workspaceAgentOpenFallback:
            snapshots = workspaceOpenFallbackSnapshots(now: now)
        case .workspaceFavicon, .workspaceFaviconPrivacy:
            snapshots = workspaceFaviconSnapshots(now: now)
        case .commandApproval:
            requests = [approval(category: .command)]
            snapshots = [attentionSnapshot(status: .waitingApproval, now: now)]
        case .fileApproval:
            requests = [approval(category: .file)]
            snapshots = [attentionSnapshot(status: .waitingApproval, now: now)]
        case .permissionApproval:
            requests = [approval(category: .permissions)]
            snapshots = [attentionSnapshot(status: .waitingApproval, now: now)]
        case .singleQuestion:
            requests = [singleQuestion()]
            snapshots = [attentionSnapshot(status: .waitingInput, now: now)]
        case .multiQuestion:
            requests = [multiQuestion()]
            snapshots = [attentionSnapshot(status: .waitingInput, now: now)]
        case .privacyRedacted:
            requests = [approval(category: .command)]
            snapshots = [attentionSnapshot(status: .waitingApproval, now: now)]
        case .privacyOffHiddenStatus:
            requests = [approval(category: .command)]
            snapshots = [snapshot(index: 1, status: .hidden, now: now)]
        case .privacyOffLockedWorkspace:
            snapshots = [snapshot(index: 1, status: .working, now: now)]
        case .deliveryFailure:
            requests = [approval(category: .command)]
            snapshots = [attentionSnapshot(status: .waitingApproval, now: now)]
        case .openFailure:
            snapshots = [snapshot(index: 1, status: .working, now: now)]
        case .archivedTasks:
            dismissed = ["archived-1", "archived-2"]
        case .settingsAppearance, .settingsResidents, .settingsGeneral,
             .settingsNotifications, .settingsSounds, .settingsPrivacy,
             .settingsPrivacyRedacted, .settingsSessions:
            snapshots = [
                snapshot(
                    index: 1,
                    status: .working,
                    now: now
                )
            ]
        }

        return CoveState(
            session: CoveSessionState(
                isExpanded: fixture != .collapsedCue
                    && fixture != .minimalCue,
                isVisible: true,
                activeStatus: snapshots.first?.status ?? .idle,
                statusPriority: snapshots.first?.priority ?? 0,
                activeSnapshot: snapshots.first,
                snapshots: snapshots
            ),
            settings: settings,
            theme: CoveThemeCatalog.palette(
                for: settings.themeFamily,
                palette: settings.palette
            ),
            pendingDirectRequests: requests,
            privacyScene: fixture == .privacyOffLockedWorkspace
                ? .locked : .normal,
            dismissedSessionIDs: dismissed
        )
    }

    private static func mixedSnapshots(now: Date) -> [CoveSessionSnapshot] {
        let statuses: [CoveSessionStatus] = [
            .working, .active, .waitingApproval, .working, .active,
            .compacting, .completed, .failed, .interrupted, .working,
            .active, .completed, .working, .completed, .active,
            .working, .completed, .failed, .active, .working,
        ]
        return statuses.enumerated().map { index, status in
            snapshot(index: index + 1, status: status, now: now)
        }
    }

    private static func workspaceAgentSnapshots(
        now: Date
    ) -> [CoveSessionSnapshot] {
        let rootID = "fixture-agent-root"
        return [
            CoveSessionSnapshot(
                snapshotId: rootID,
                status: .working,
                priority: 40,
                title: "Fixture parent task",
                timestamp: now,
                sessionId: rootID,
                launchId: "fixture-agent-launch",
                source: .localCli,
                liveness: .live,
                activeTurnId: "fixture-parent-turn",
                controlRoute: .routedLocal
            ),
            CoveSessionSnapshot(
                snapshotId: "fixture-agent-idle",
                status: .idle,
                priority: 5,
                title: "Idle child agent",
                timestamp: now.addingTimeInterval(-1),
                sessionId: "fixture-agent-idle",
                launchId: "fixture-agent-launch",
                source: .localCli,
                parentSessionId: rootID,
                liveness: .live,
                controlRoute: .localAppServer
            ),
            CoveSessionSnapshot(
                snapshotId: "fixture-agent-active",
                status: .active,
                priority: 40,
                title: "Active child agent",
                latestOutput: "Initial child output",
                timestamp: now.addingTimeInterval(-2),
                sessionId: "fixture-agent-active",
                launchId: "fixture-agent-launch",
                source: .localCli,
                parentSessionId: rootID,
                liveness: .live,
                activeTurnId: "fixture-child-turn",
                controlRoute: .routedLocal
            ),
            CoveSessionSnapshot(
                snapshotId: "fixture-agent-missing-turn",
                status: .working,
                priority: 40,
                title: "Missing-turn child agent",
                timestamp: now.addingTimeInterval(-3),
                sessionId: "fixture-agent-missing-turn",
                launchId: "fixture-agent-launch",
                source: .localCli,
                parentSessionId: rootID,
                liveness: .live,
                controlRoute: .localAppServer
            ),
            CoveSessionSnapshot(
                snapshotId: "fixture-agent-pending",
                status: .waitingApproval,
                priority: 100,
                title: "Pending child agent",
                timestamp: now.addingTimeInterval(-4),
                sessionId: "fixture-agent-pending",
                launchId: "fixture-agent-launch",
                source: .localCli,
                parentSessionId: rootID,
                liveness: .live,
                activeTurnId: "fixture-pending-turn",
                controlRoute: .routedLocal,
                unread: true
            ),
            CoveSessionSnapshot(
                snapshotId: "fixture-new-top-level",
                status: .idle,
                priority: 5,
                title: "New top-level task",
                timestamp: now.addingTimeInterval(-5),
                sessionId: "fixture-new-top-level",
                source: .codexDesktop,
                liveness: .loaded,
                controlRoute: .desktop
            ),
        ]
    }

    private static func workspaceOpenFallbackSnapshots(
        now: Date
    ) -> [CoveSessionSnapshot] {
        let rootID = "fixture-open-root"
        return [
            CoveSessionSnapshot(
                snapshotId: rootID,
                status: .idle,
                priority: 5,
                title: "Openable parent task",
                timestamp: now,
                sessionId: rootID,
                launchId: "fixture-open-launch",
                source: .localCli,
                liveness: .live,
                controlRoute: .localAppServer
            ),
            CoveSessionSnapshot(
                snapshotId: "fixture-open-child",
                status: .idle,
                priority: 5,
                title: "Unavailable child location",
                timestamp: now.addingTimeInterval(-1),
                sessionId: "fixture-open-child",
                launchId: "fixture-open-launch",
                source: .localCli,
                parentSessionId: rootID,
                liveness: .live,
                controlRoute: .localAppServer
            ),
        ]
    }

    private static func workspaceFaviconSnapshots(
        now: Date
    ) -> [CoveSessionSnapshot] {
        [CoveSessionSnapshot(
            snapshotId: "fixture-favicon-root",
            status: .idle,
            priority: 5,
            title: "Favicon fixture task",
            latestOutput: "Suggested https://suggestion-favicon.com/plan",
            timestamp: now,
            sessionId: "fixture-favicon-root",
            launchId: "fixture-favicon-launch",
            source: .localCli,
            liveness: .live,
            controlRoute: .localAppServer
        )]
    }

    private static func agentApproval() -> CoveDirectRequest {
        .approval(
            CoveApprovalRequest(
                schemaVersion: 1,
                category: .command,
                requestId: "fixture-agent-approval",
                launchId: "fixture-agent-launch",
                sessionId: "fixture-agent-pending",
                turnId: "fixture-pending-turn",
                source: .localCli,
                title: "Review child-agent command",
                detail: "Resolve this request before steering the child agent.",
                choices: [
                    approvalChoice(.accept, label: "Allow once"),
                    approvalChoice(.decline, label: "Decline"),
                ],
                amendments: [],
                permissionProfile: nil,
                decisionSocket: "/fixture/agent-decision.sock"
            )
        )
    }

    private static func snapshot(
        index: Int,
        status: CoveSessionStatus,
        now: Date
    ) -> CoveSessionSnapshot {
        CoveSessionSnapshot(
            snapshotId: "fixture-task-\(index)",
            status: status,
            priority: priority(for: status),
            title: index == 3 ? "Only waiting approval" : "Fixture task \(index)",
            detail: "Deterministic fixture detail \(index)",
            timestamp: now.addingTimeInterval(TimeInterval(-index)),
            sessionId: "fixture-task-\(index)",
            launchId: "fixture-launch-\(index)",
            source: index.isMultiple(of: 3) ? .codexDesktop : .localCli,
            liveness: .live,
            activeTurnId: index == 1 ? "fixture-active-turn" : nil,
            controlRoute: index == 1 ? .routedLocal : nil,
            unread: [.waitingApproval, .waitingInput, .failed].contains(status)
        )
    }

    private static func attentionSnapshot(
        status: CoveSessionStatus,
        now: Date
    ) -> CoveSessionSnapshot {
        CoveSessionSnapshot(
            snapshotId: "fixture-attention",
            status: status,
            priority: priority(for: status),
            title: "Fixture attention task",
            detail: "Codex needs a safe response",
            timestamp: now,
            sessionId: "fixture-session",
            launchId: "fixture-launch",
            source: .localCli,
            liveness: .live,
            unread: true
        )
    }

    private static func approval(
        category: CoveApprovalCategory
    ) -> CoveDirectRequest {
        .approval(
            CoveApprovalRequest(
                schemaVersion: 1,
                category: category,
                requestId: "fixture-approval",
                launchId: "fixture-launch",
                sessionId: "fixture-session",
                turnId: "fixture-turn",
                title: "Review fixture \(category.rawValue) approval",
                detail: "This fixture action demonstrates its consequence before sending.",
                choices: [
                    approvalChoice(.accept, label: "Allow once"),
                    approvalChoice(
                        .acceptForSession,
                        label: "Allow for this task"
                    ),
                    approvalChoice(.decline, label: "Decline"),
                    approvalChoice(.cancel, label: "Cancel"),
                ],
                amendments: [],
                permissionProfile: nil,
                decisionSocket: "/fixture/decision.sock"
            )
        )
    }

    private static func approvalChoice(
        _ decision: CoveApprovalDecision,
        label: String
    ) -> CoveChoice {
        CoveChoice(
            identifier: decision.rawValue,
            label: label,
            raw: .object(["decision": .string(decision.rawValue)])
        )
    }

    private static func singleQuestion() -> CoveDirectRequest {
        .question(
            CoveQuestionRequest(
                schemaVersion: 1,
                requestId: "fixture-question",
                launchId: "fixture-launch",
                sessionId: "fixture-session",
                turnId: "fixture-turn",
                question: "Which deterministic option should Codex use?",
                options: [
                    CoveChoice(identifier: "one", label: "Option One"),
                    CoveChoice(identifier: "two", label: "Option Two"),
                ],
                allowsFreeform: true,
                decisionSocket: "/fixture/decision.sock"
            )
        )
    }

    private static func multiQuestion() -> CoveDirectRequest {
        .question(
            CoveQuestionRequest(
                schemaVersion: 1,
                requestId: "fixture-multi-question",
                launchId: "fixture-launch",
                sessionId: "fixture-session",
                turnId: "fixture-turn",
                questions: [
                    CoveQuestionPrompt(
                        questionId: "architecture",
                        header: "Architecture",
                        question: "Choose the complete architecture option without truncating this label.",
                        options: [
                            CoveChoice(
                                identifier: "native",
                                label: "Native application with local public Codex interfaces"
                            ),
                            CoveChoice(
                                identifier: "other",
                                label: "Another architecture"
                            ),
                        ],
                        allowsFreeform: false
                    ),
                    CoveQuestionPrompt(
                        questionId: "notes",
                        header: "Notes",
                        question: "Add any implementation constraints for the selected option.",
                        options: [],
                        allowsFreeform: true
                    ),
                ],
                decisionSocket: "/fixture/decision.sock"
            )
        )
    }

    private static func priority(for status: CoveSessionStatus) -> Int {
        switch status {
        case .waitingApproval: 100
        case .waitingInput: 95
        case .blocked: 90
        case .failed: 85
        case .interrupted: 75
        case .completed: 70
        case .compacting: 50
        case .working, .active: 40
        case .listening: 20
        case .idle, .quiet, .hidden: 0
        }
    }
}
