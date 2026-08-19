import Darwin
import Dispatch
import Foundation
import CoveCore

private struct MemoryStorage: CoveStateStorage {
    func load() throws -> CoveState? { nil }
    func save(_ state: CoveState) throws {}
}

private enum ProbeFailure: Error {
    case failed
}

private final class FaviconURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseError: Error?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func configure(
        data: Data,
        status: Int = 200,
        error: Error? = nil
    ) {
        lock.lock()
        responseData = data
        responseStatus = status
        responseError = error
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let data = Self.responseData
        let status = Self.responseStatus
        let error = Self.responseError
        Self.lock.unlock()
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
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

private actor ProbeSender: CoveDecisionSending {
    let shouldFail: Bool
    private var frames: [CoveDecisionFrame] = []
    private var socketPaths: [String] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func send(_ frame: CoveDecisionFrame, to socketPath: String) async throws {
        frames.append(frame)
        socketPaths.append(socketPath)
        if shouldFail {
            throw ProbeFailure.failed
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    func count() -> Int {
        frames.count
    }

    func paths() -> [String] {
        socketPaths
    }
}

@main
@MainActor
private struct CoveStoreFoundationTests {
    static func approvalFixture() -> (
        request: CoveApprovalRequest,
        allowOnce: CoveChoice,
        decline: CoveChoice
    ) {
        let allowOnce = CoveChoice(
            identifier: CoveApprovalDecision.accept.rawValue,
            label: "Allow once"
        )
        let decline = CoveChoice(
            identifier: CoveApprovalDecision.decline.rawValue,
            label: "Decline"
        )
        return (
            CoveApprovalRequest(
                schemaVersion: 1,
                category: .command,
                requestId: "approval-1",
                launchId: "launch-1",
                sessionId: "session-1",
                title: "Run command",
                detail: "Run a fixture command",
                choices: [allowOnce, decline],
                amendments: [],
                permissionProfile: nil,
                decisionSocket: "/tmp/cove-fixture.sock"
            ),
            allowOnce,
            decline
        )
    }

    static func makeStore(
        sender: ProbeSender,
        approval: CoveApprovalRequest
    ) -> CoveStore {
        CoveStore(
            storage: MemoryStorage(),
            decisionSender: sender,
            initialState: CoveState(
                session: CoveSessionState(isExpanded: true),
                pendingDirectRequests: [.approval(approval)]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            decisionSuccessFeedbackDuration: .milliseconds(10),
            openExternalURL: { _ in true }
        )
    }

    static func waitUntil(
        attempts: Int = 500,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    static func testArchiveAllCompletedSafety() {
        let now = Date(timeIntervalSince1970: 1_000)
        func snapshot(
            _ id: String,
            sessionID: String? = nil,
            status: CoveSessionStatus
        ) -> CoveSessionSnapshot {
            CoveSessionSnapshot(
                snapshotId: id,
                status: status,
                priority: status == .completed ? 8 : 40,
                title: id,
                timestamp: now,
                sessionId: sessionID ?? id,
                source: .localCli,
                unread: true
            )
        }

        let pinnedCompleted = snapshot("completed-pinned", status: .completed)
        let remindedCompleted = snapshot("completed-reminded", status: .completed)
        let failed = snapshot("failed", status: .failed)
        let active = snapshot("active", status: .working)
        let sharedCompleted = snapshot(
            "shared-completed",
            sessionID: "shared-session",
            status: .completed
        )
        let sharedActive = snapshot(
            "shared-active",
            sessionID: "shared-session",
            status: .active
        )
        let store = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    snapshots: [
                        pinnedCompleted,
                        remindedCompleted,
                        failed,
                        active,
                        sharedCompleted,
                        sharedActive,
                    ]
                ),
                pinnedSessionIDs: [
                    pinnedCompleted.sessionIdentity!.id,
                    active.sessionIdentity!.id,
                ]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: []
        )

        var archivedBatches: [[String]] = []
        var unpinned: [String] = []
        var canceledReminders: [String] = []
        store.onDismissSessions = {
            archivedBatches.append($0.map(\.sessionId))
            return true
        }
        store.onSetPinned = { sessionID, pinned in
            if !pinned { unpinned.append(sessionID.sessionId) }
            return true
        }
        store.onScheduleFollowUp = { _, _ in true }
        store.onCancelFollowUp = {
            canceledReminders.append($0.sessionId)
            return true
        }
        store.scheduleFollowUp(remindedCompleted)

        precondition(store.archivableCompletedCount == 2)
        store.archiveAllCompleted()

        precondition(
            archivedBatches == [["completed-pinned", "completed-reminded"]]
        )
        precondition(unpinned == ["completed-pinned"])
        precondition(canceledReminders == ["completed-reminded"])
        precondition(store.archivableCompletedCount == 0)
        precondition(
            Set(store.state.dismissedSessionIDs)
                == [
                    pinnedCompleted.sessionIdentity!.id,
                    remindedCompleted.sessionIdentity!.id,
                ]
        )
        precondition(
            store.state.pinnedSessionIDs == [active.sessionIdentity!.id]
        )
        precondition(store.reminders[remindedCompleted.sessionIdentity!] == nil)
        precondition(
            Set(store.state.session.snapshots.map(\.snapshotId))
                == ["failed", "active", "shared-completed", "shared-active"]
        )
    }

    static func main() async {
        testWorkspaceArtifactMutations()
        await testFaviconLoader()
        do {
            try testUITestTemporaryDirectoryPolicy()
        } catch {
            fatalError("UI-test temporary-directory policy failed: \(error)")
        }
        testDirectRequestOriginRouting()
        await testDirectRequestDecisionOriginIsolation()
        testMissingExactOriginDoesNotUseCurrentLocation()
        testNotificationOriginResolution()
        testEditorFocusResponseContract()
        testEditorFocusSocketTransport()
        testEditorExactOriginBinding()
        testSessionOpenFailureFeedback()
        do {
            try testMetadataOriginCollisionFailsClosed()
        } catch {
            fatalError("Metadata origin collision test failed: \(error)")
        }
        testArchiveAllCompletedSafety()
        await testRecoverableIdleAutoHide()
        do {
            try testCustomThemeDraftPersistsWhenSettingsCloses()
        } catch {
            fatalError("Custom theme close persistence failed: \(error)")
        }
        do {
            try testCustomThemeSaveAndExport()
        } catch {
            fatalError("Custom theme save/export failed: \(error)")
        }

        let fixture = approvalFixture()
        let requestKey = CoveDirectRequest.approval(fixture.request).key

        let sender = ProbeSender()
        let store = makeStore(sender: sender, approval: fixture.request)
        precondition(store.overlayPresentation == .queue)
        precondition(store.focusDirectRequest(requestKey))

        // A positive choice is staged and dirty, but sends nothing yet.
        precondition(
            store.selectApprovalChoice(
                fixture.allowOnce,
                for: fixture.request
            )
        )
        precondition(store.decisionAttemptCount == 0)
        precondition(store.isActionDirty(requestKey))
        precondition(store.decisionDelivery.isStaged(requestKey))

        // Settings hides Cove without discarding a staged decision.
        store.collapseForSettings()
        precondition(store.overlayPresentation == .collapsed)
        precondition(store.isActionDirty(requestKey))
        store.setOverlayHovered(true)
        store.collapseForSettings()
        try? await Task.sleep(for: .milliseconds(300))
        precondition(store.overlayPresentation == .collapsed)
        store.showQueue()
        store.dispatch(.setExpanded(true))
        precondition(store.overlayPresentation == .collapsed)
        precondition(!store.state.session.isExpanded)
        store.endSettingsPresentation()
        precondition(store.focusDirectRequest(requestKey))

        // Hover and keyboard focus can both leave a panel while an approval is
        // staged. Neither path may collapse a dirty focused action.
        store.dispatch(.setAutoCollapseDelay(1))
        store.setOverlayHovered(true)
        store.setOverlayFocused(true)
        store.setOverlayHovered(false)
        store.setOverlayFocused(false)
        store.endOverlayInteraction()
        try? await Task.sleep(for: .milliseconds(1_150))
        precondition(store.state.session.isExpanded)
        precondition(
            store.overlayPresentation
                == .focused(.directRequest(requestKey))
        )

        // Escape protects the draft. Keep Editing preserves focus and value.
        precondition(
            store.requestPresentationBack() == .confirmDiscard(requestKey)
        )
        precondition(
            store.overlayPresentation
                == .focused(.directRequest(requestKey))
        )
        store.keepEditingPendingDirtyExit()
        precondition(store.approvalDraft(for: requestKey)?.choice == fixture.allowOnce)

        // The legacy collapse signal is guarded by the same dirty policy.
        store.dispatch(.setExpanded(false))
        precondition(store.state.session.isExpanded)
        precondition(
            store.pendingDirtyExitConfirmation?.destination == .collapsed
        )
        store.keepEditingPendingDirtyExit()

        // Confirmation starts exactly one send; a repeated click is rejected.
        precondition(store.confirmApproval(for: fixture.request))
        precondition(!store.confirmApproval(for: fixture.request))
        precondition(store.decisionAttemptCount == 1)
        let successCompleted = await waitUntil {
            await sender.count() == 1
                && store.state.pendingDirectRequests.isEmpty
        }
        precondition(successCompleted)
        let successSendCount = await sender.count()
        precondition(successSendCount == 1)
        precondition(store.state.pendingDirectRequests.isEmpty)
        precondition(store.overlayPresentation == .queue)

        // A failure retains its exact payload. Retry is also single-flight.
        let failureSender = ProbeSender(shouldFail: true)
        let failureStore = makeStore(
            sender: failureSender,
            approval: fixture.request
        )
        precondition(failureStore.focusDirectRequest(requestKey))
        precondition(
            failureStore.selectApprovalChoice(
                fixture.allowOnce,
                for: fixture.request
            )
        )
        precondition(failureStore.confirmApproval(for: fixture.request))
        let failureReported = await waitUntil {
            failureStore.decisionDelivery.errorMessage(for: requestKey) != nil
        }
        precondition(failureReported)
        precondition(
            failureStore.decisionDelivery.errorMessage(for: requestKey) != nil
        )
        precondition(!failureStore.openInCodex(for: .approval(fixture.request)))
        precondition(
            failureStore.decisionDelivery.retryAttempt(for: requestKey) != nil
        )
        precondition(failureStore.retryDecision(for: requestKey))
        precondition(!failureStore.retryDecision(for: requestKey))
        precondition(failureStore.decisionAttemptCount == 2)

        print("CoveStore foundation tests passed")
    }

    static func testWorkspaceArtifactMutations() {
        let root = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "workspace-root"
        )!
        let child = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "workspace-child"
        )!
        var workspace = CoveWorkspaceState(gridOrder: [root, child])
        workspace.setLinks([
            .init(label: "Root", url: URL(string: "https://example.com/root")!),
        ], for: root)
        workspace.setLinks([
            .init(label: "Child", url: URL(string: "https://example.org/child")!),
        ], for: child)
        let now = Date(timeIntervalSince1970: 2_000)
        let snapshots = [
            CoveSessionSnapshot(
                snapshotId: root.sessionId,
                status: .idle,
                priority: 5,
                title: "Root",
                timestamp: now,
                sessionId: root.sessionId,
                source: .localCli,
                liveness: .live
            ),
            CoveSessionSnapshot(
                snapshotId: child.sessionId,
                status: .idle,
                priority: 5,
                title: "Child",
                timestamp: now,
                sessionId: child.sessionId,
                source: .localCli,
                parentSessionId: root.sessionId,
                liveness: .live
            ),
        ]
        workspace.observe(snapshots)
        let store = CoveWorkspaceStore(
            initialState: workspace,
            writesEnabled: false,
            openArtifactURL: { _ in true }
        )
        let projection = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: store.state
        )
        var artifacts = store.artifacts(for: root, projection: projection)
        precondition(artifacts.map(\.link.label) == ["Root", "Child"])
        let originalOrder = store.artifactOrder
        let childArtifact = artifacts[1]
        let childID = childArtifact.link.id
        let childURL = childArtifact.link.url
        store.renameArtifact(childArtifact, label: "  Renamed child  ")
        artifacts = store.artifacts(for: root, projection: projection)
        precondition(artifacts[1].link.label == "Renamed child")
        precondition(artifacts[1].link.id == childID)
        precondition(artifacts[1].link.url == childURL)
        store.renameArtifact(artifacts[1], label: "   ")
        precondition(store.artifacts(for: root, projection: projection)[1].link.label == "Renamed child")
        store.renameArtifact(
            artifacts[1],
            label: String(repeating: "é", count: 65)
        )
        precondition(
            store.artifacts(for: root, projection: projection)[1].link.label
                == "Renamed child"
        )
        store.moveArtifact(artifacts[1], before: artifacts[0])
        precondition(
            store.artifacts(for: root, projection: projection).map(\.link.label)
                == ["Renamed child", "Root"]
        )
        store.restoreArtifactOrder(originalOrder)
        precondition(
            store.artifacts(for: root, projection: projection).map(\.link.label)
                == ["Root", "Renamed child"]
        )
    }

    static func testFaviconLoader() async {
        let blockedArtifactURLs = [
            "https://localhost/path",
            "https://intranet/path",
            "https://127.0.0.1/path",
            "https://127.1/path",
            "https://127.0.1/path",
            "https://127.000.000.001/path",
            "https://0177.0.0.1/path",
            "https://0x7f.0.0.1/path",
            "https://2130706433/path",
            "https://0x7f000001/path",
            "https://8.8.2056/path",
            "https://[::1]/path",
            "https://[::ffff:127.0.0.1]/path",
            "https://service.local/path",
            "https://home.arpa/path",
            "https://HOME.ARPA./path",
            "https://service.home.arpa/path",
        ].map { URL(string: $0)! }
        precondition(
            CoveFaviconLoader.faviconURL(
                for: URL(string: "https://Example.COM/private/path?token=secret")!
            ) == URL(string: "https://example.com/favicon.ico")!
        )
        precondition(
            CoveFaviconLoader.faviconURL(
                for: URL(string: "http://example.com:8080/path")!
            ) == URL(string: "https://example.com/favicon.ico")!
        )
        precondition(
            CoveFaviconLoader.faviconURL(
                for: URL(string: "https://127.0.0.1.example.com/path")!
            ) == URL(string: "https://127.0.0.1.example.com/favicon.ico")!
        )
        for url in blockedArtifactURLs {
            precondition(CoveFaviconLoader.faviconURL(for: url) == nil)
        }

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        FaviconURLProtocol.configure(data: png)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconURLProtocol.self]
        let loader = CoveFaviconLoader(configuration: configuration)
        for url in blockedArtifactURLs { loader.load(for: url) }
        precondition(FaviconURLProtocol.capturedRequests().isEmpty)
        let artifactURL = URL(string: "https://example.com/private?token=secret")!
        loader.load(for: artifactURL)
        loader.load(for: artifactURL)
        let loaded = await waitUntil {
            loader.image(for: artifactURL) != nil
        }
        precondition(loaded)
        let requests = FaviconURLProtocol.capturedRequests()
        precondition(requests.count == 1)
        precondition(requests[0].url == URL(string: "https://example.com/favicon.ico"))
        precondition(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
        precondition(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        loader.load(for: artifactURL)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(FaviconURLProtocol.capturedRequests().count == 1)

        func littleEndianBytes(_ value: Int) -> [UInt8] {
            let value = UInt32(value)
            return [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 24),
            ]
        }
        var ico = Data([0, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 32, 0])
        ico.append(contentsOf: littleEndianBytes(48))
        ico.append(contentsOf: littleEndianBytes(22))
        ico.append(contentsOf: littleEndianBytes(40))
        ico.append(contentsOf: littleEndianBytes(1))
        ico.append(contentsOf: littleEndianBytes(2))
        ico.append(contentsOf: [1, 0, 32, 0])
        ico.append(contentsOf: littleEndianBytes(0))
        ico.append(contentsOf: littleEndianBytes(4))
        for _ in 0..<4 { ico.append(contentsOf: littleEndianBytes(0)) }
        ico.append(contentsOf: [0, 0, 255, 255, 0, 0, 0, 0])
        FaviconURLProtocol.configure(data: ico)
        let icoLoader = CoveFaviconLoader(configuration: configuration)
        let icoURL = URL(string: "https://ico.example.com/artifact")!
        icoLoader.load(for: icoURL)
        let icoLoaded = await waitUntil { icoLoader.image(for: icoURL) != nil }
        precondition(icoLoaded)

        func assertRejected(
            _ host: String,
            data: Data = Data(),
            status: Int = 200,
            error: Error? = nil
        ) async {
            FaviconURLProtocol.configure(
                data: data,
                status: status,
                error: error
            )
            let rejectedLoader = CoveFaviconLoader(configuration: configuration)
            let url = URL(string: "https://\(host)/artifact")!
            let initial = rejectedLoader.revision
            rejectedLoader.load(for: url)
            let completed = await waitUntil {
                rejectedLoader.revision != initial
            }
            precondition(completed)
            precondition(rejectedLoader.image(for: url) == nil)
        }

        await assertRejected("missing.example.com", status: 404)
        await assertRejected("redirect.example.com", status: 302)
        await assertRejected(
            "invalid-image.example.com",
            data: Data("not an image".utf8)
        )
        await assertRejected(
            "timeout.example.com",
            error: URLError(.timedOut)
        )

        FaviconURLProtocol.configure(data: Data(repeating: 0, count: 256 * 1_024 + 1))
        let oversizedLoader = CoveFaviconLoader(configuration: configuration)
        let initialRevision = oversizedLoader.revision
        oversizedLoader.load(for: URL(string: "https://oversized.example.com/x")!)
        let rejectedOversized = await waitUntil {
            oversizedLoader.revision != initialRevision
        }
        precondition(rejectedOversized)
        precondition(
            oversizedLoader.image(for: URL(string: "https://oversized.example.com/x")!) == nil
        )
    }

    static func testSessionOpenFailureFeedback() {
        let snapshot = CoveSessionSnapshot(
            snapshotId: "open-feedback-snapshot",
            status: .working,
            priority: 40,
            title: "Open feedback fixture",
            timestamp: Date(timeIntervalSince1970: 1),
            sessionId: "open-feedback-session",
            launchId: "open-feedback-launch",
            source: .remoteCli,
            hostId: "fixture-remote",
            unread: true
        )
        let store = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    isExpanded: true,
                    snapshots: [snapshot]
                )
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: []
        )
        var markedRead: [String] = []
        store.onMarkRead = { markedRead.append($0.sessionId) }
        store.onJumpToSession = { _ in
            CoveJumpResult(
                focusedExactLocation: false,
                message: "The exact originating remote terminal is not currently available."
            )
        }

        precondition(!store.open(snapshot))
        precondition(
            store.sessionOpenFailureMessage
                == "The exact originating remote terminal is not currently available."
        )
        precondition(store.state.session.snapshots[0].unread)
        precondition(markedRead.isEmpty)

        store.onJumpToSession = { _ in
            CoveJumpResult(
                focusedExactLocation: true,
                message: "Focused the originating remote Codex terminal."
            )
        }
        precondition(store.open(snapshot))
        precondition(store.sessionOpenFailureMessage == nil)
        precondition(!store.state.session.snapshots[0].unread)
        precondition(markedRead == ["open-feedback-session"])
    }

    static func testCustomThemeSaveAndExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let themeStorage = CoveThemeFileStore(
            directoryURL: directory.appendingPathComponent("Themes")
        )
        let store = CoveStore(
            storage: MemoryStorage(),
            themeStorage: themeStorage,
            initialState: CoveState(
                settings: CoveSettings(
                    blurStyle: .thick,
                    collapsedOpacity: 0.55,
                    expandedOpacity: 0.66
                )
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: []
        )

        var draft = store.state.theme
        draft.backgroundHex = "#123456"
        draft.accentHex = "#ABCDEF"
        draft.surfaceFill = .solid
        store.previewTheme(draft)
        precondition(store.themePreview?.backgroundHex == "#123456")
        precondition(store.themePreview?.surfaceFill == .solid)
        let saved = try store.saveCustomTheme(draft, named: "My Theme")
        precondition(!saved.isBuiltIn)
        precondition(saved.name == "My Theme")
        precondition(saved.backgroundHex == "#123456")
        precondition(saved.accentHex == "#ABCDEF")
        precondition(saved.surfaceFill == .solid)
        precondition(saved.collapsedOpacity == 0.55)
        precondition(saved.expandedOpacity == 0.66)
        precondition(saved.blurStyle == .thick)
        precondition(store.state.settings.customThemeID == saved.identifier)
        let loadedThemes = try themeStorage.loadCustomThemes()
        precondition(loadedThemes == [saved])

        let exportURL = directory.appendingPathComponent("export.json")
        try store.exportTheme(saved, to: exportURL)
        let exported = try CoveThemeDocument.decodeAndValidate(
            Data(contentsOf: exportURL)
        )
        precondition(exported.id == saved.identifier)
        precondition(exported.collapsedOpacity == 0.55)
        precondition(exported.expandedOpacity == 0.66)
        precondition(exported.blur == .thick)
        precondition(exported.surfaceFill == .solid)

        var updated = saved
        updated.surfaceHex = "#654321"
        let resaved = try store.saveCustomTheme(updated, named: "My Theme 2")
        precondition(resaved.identifier == saved.identifier)
        precondition(resaved.name == "My Theme 2")
        precondition(resaved.surfaceHex == "#654321")
        precondition(store.customThemes == [resaved])
    }

    static func testCustomThemeDraftPersistsWhenSettingsCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CoveFileStateStorage(
            url: directory.appendingPathComponent("settings.json")
        )
        let themeStorage = CoveThemeFileStore(
            directoryURL: directory.appendingPathComponent("Themes")
        )
        let store = CoveStore(
            storage: storage,
            themeStorage: themeStorage,
            initialState: CoveState(),
            persistenceWritesEnabledOverride: true,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: []
        )

        var draft = store.state.theme
        draft.name = "Close Saved Theme"
        draft.backgroundHex = "#123456"
        draft.surfaceFill = .solid
        store.previewTheme(draft)
        store.endSettingsPresentation()

        precondition(store.themePreview == nil)
        precondition(store.customThemes.count == 1)
        let saved = store.customThemes[0]
        precondition(saved.name == "Close Saved Theme")
        precondition(saved.backgroundHex == "#123456")
        precondition(saved.surfaceFill == .solid)
        precondition(saved.identifier != draft.identifier)
        let persistedState = try storage.load()
        precondition(
            persistedState?.settings.customThemeID == saved.identifier
        )

        let reloaded = CoveStore(
            storage: storage,
            themeStorage: themeStorage,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false
        )
        precondition(reloaded.state.settings.customThemeID == saved.identifier)
        precondition(reloaded.state.theme == saved)
    }

    static func testRecoverableIdleAutoHide() async {
        let store = CoveStore(
            storage: MemoryStorage(),
            initialState: CoveState(
                settings: CoveSettings(idleAutoHideSeconds: 0.05)
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: []
        )
        store.dispatch(.boot)
        let collapsedToCue = await waitUntil {
            store.state.settings.minimalIslandMode
        }
        precondition(collapsedToCue)
        precondition(store.state.session.isVisible)
        precondition(!store.state.session.isExpanded)

        store.dispatch(.setMinimalIslandMode(false))
        precondition(store.state.session.isVisible)
        precondition(!store.state.settings.minimalIslandMode)
    }

    static func testDirectRequestOriginRouting() {
        func request(
            _ requestID: String,
            sessionID: String,
            launchID: String?,
            source: CoveWireSource? = nil,
            hostID: String? = nil
        ) -> CoveDirectRequest {
            .approval(
                CoveApprovalRequest(
                    schemaVersion: 1,
                    category: .command,
                    requestId: CoveRequestID(requestID),
                    launchId: launchID,
                    sessionId: sessionID,
                    source: source,
                    hostId: hostID,
                    title: "Fixture",
                    detail: nil,
                    choices: [],
                    amendments: [],
                    permissionProfile: nil,
                    decisionSocket: nil
                )
            )
        }

        func snapshot(
            sessionID: String,
            launchID: String?,
            source: CoveWireSource?,
            hostID: String? = nil,
            snapshotID: String? = nil
        ) -> CoveSessionSnapshot {
            CoveSessionSnapshot(
                snapshotId: snapshotID ?? sessionID,
                status: .waitingApproval,
                priority: 100,
                title: "Fixture",
                timestamp: Date(timeIntervalSince1970: 10),
                sessionId: sessionID,
                launchId: launchID,
                source: source,
                hostId: hostID
            )
        }

        let local = request(
            "local-request",
            sessionID: "local-session",
            launchID: "local-launch",
            source: .localCli
        )
        let remote = request(
            "remote-request",
            sessionID: "remote-session",
            launchID: "remote-launch",
            source: .remoteCli,
            hostID: "remote-fixture"
        )
        var fallbackURLs: [URL] = []
        let store = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    isExpanded: true,
                    snapshots: [
                        snapshot(
                            sessionID: local.sessionId,
                            launchID: local.launchId,
                            source: .localCli
                        ),
                        snapshot(
                            sessionID: remote.sessionId,
                            launchID: remote.launchId,
                            source: .remoteCli,
                            hostID: "remote-fixture"
                        ),
                    ]
                ),
                pendingDirectRequests: [local, remote]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            openExternalURL: {
                fallbackURLs.append($0)
                return true
            }
        )
        var routedSources: [CoveWireSource?] = []
        var routedLaunchIDs: [String?] = []
        store.onOpenDirectRequest = { origin in
            routedSources.append(origin.source)
            routedLaunchIDs.append(origin.launchId)
            return CoveJumpResult(
                focusedExactLocation: true,
                message: "Focused exact fixture origin"
            )
        }
        precondition(store.openInCodex(for: local))
        precondition(store.openInCodex(for: remote))
        precondition(routedSources == [.localCli, .remoteCli])
        precondition(routedLaunchIDs == ["local-launch", "remote-launch"])
        precondition(fallbackURLs.isEmpty)

        let desktop = request(
            "desktop-request",
            sessionID: "desktop-session",
            launchID: nil,
            source: .codexDesktop
        )
        var desktopURLs: [URL] = []
        let desktopStore = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    isExpanded: true,
                    snapshots: [
                        snapshot(
                            sessionID: desktop.sessionId,
                            launchID: nil,
                            source: .codexDesktop
                        )
                    ]
                ),
                pendingDirectRequests: [desktop]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            openExternalURL: {
                desktopURLs.append($0)
                return true
            }
        )
        precondition(desktopStore.openInCodex(for: desktop))
        precondition(
            desktopURLs.map(\.absoluteString)
                == ["codex://threads/desktop-session"]
        )

        // Source is part of the request identity even when every opaque ID is
        // reused. Exact routing selects the matching card and never whichever
        // source happened to be inserted first.
        let sharedLocal = request(
            "shared-request",
            sessionID: "shared-session",
            launchID: "shared-launch",
            source: .localCli
        )
        let sharedDesktop = request(
            "shared-request",
            sessionID: "shared-session",
            launchID: "shared-launch",
            source: .codexDesktop
        )
        let remoteA = request(
            "shared-request",
            sessionID: "shared-session",
            launchID: "shared-launch",
            source: .remoteCli,
            hostID: "remote-a"
        )
        let remoteB = request(
            "shared-request",
            sessionID: "shared-session",
            launchID: "shared-launch",
            source: .remoteCli,
            hostID: "remote-b"
        )
        let collisionStore = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    snapshots: [
                        snapshot(
                            sessionID: "shared-session",
                            launchID: "shared-launch",
                            source: .localCli,
                            snapshotID: "shared-local"
                        ),
                        snapshot(
                            sessionID: "shared-session",
                            launchID: "shared-launch",
                            source: .codexDesktop,
                            snapshotID: "shared-desktop"
                        ),
                        snapshot(
                            sessionID: "shared-session",
                            launchID: "shared-launch",
                            source: .remoteCli,
                            hostID: "remote-a",
                            snapshotID: "shared-remote-a"
                        ),
                        snapshot(
                            sessionID: "shared-session",
                            launchID: "shared-launch",
                            source: .remoteCli,
                            hostID: "remote-b",
                            snapshotID: "shared-remote-b"
                        ),
                    ]
                ),
                pendingDirectRequests: [
                    sharedLocal,
                    sharedDesktop,
                    remoteA,
                    remoteB,
                ]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: []
        )
        var routedOrigins: [CoveOriginScope] = []
        collisionStore.onOpenDirectRequest = { origin in
            guard let origin = origin.originScope else {
                return CoveJumpResult(
                    focusedExactLocation: false,
                    message: "Missing origin"
                )
            }
            routedOrigins.append(origin)
            return CoveJumpResult(
                focusedExactLocation: true,
                message: "Focused exact fixture origin"
            )
        }
        precondition(collisionStore.openInCodex(for: sharedLocal))
        precondition(collisionStore.openInCodex(for: sharedDesktop))
        precondition(collisionStore.openInCodex(for: remoteA))
        precondition(collisionStore.openInCodex(for: remoteB))
        precondition(
            routedOrigins == [
                CoveOriginScope(source: .localCli, hostId: nil)!,
                CoveOriginScope(source: .codexDesktop, hostId: nil)!,
                CoveOriginScope(source: .remoteCli, hostId: "remote-a")!,
                CoveOriginScope(source: .remoteCli, hostId: "remote-b")!,
            ]
        )

        var emptyDesktopURLs: [URL] = []
        let emptyDesktop = request(
            "empty-desktop-request",
            sessionID: "",
            launchID: nil,
            source: .codexDesktop
        )
        let emptyDesktopStore = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    snapshots: [
                        snapshot(
                            sessionID: "",
                            launchID: nil,
                            source: .codexDesktop,
                            snapshotID: "empty-desktop"
                        )
                    ]
                ),
                pendingDirectRequests: [emptyDesktop]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            openExternalURL: {
                emptyDesktopURLs.append($0)
                return true
            }
        )
        precondition(!emptyDesktopStore.openInCodex(for: emptyDesktop))
        precondition(emptyDesktopURLs.isEmpty)

        let unverified = request(
            "unverified-request",
            sessionID: "unverified-session",
            launchID: nil
        )
        let unverifiedStore = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    isExpanded: true,
                    snapshots: [
                        snapshot(
                            sessionID: unverified.sessionId,
                            launchID: nil,
                            source: nil
                        )
                    ]
                ),
                pendingDirectRequests: [unverified]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            openExternalURL: { _ in
                fatalError("An unverified source must not open a Desktop URL")
            }
        )
        precondition(!unverifiedStore.openInCodex(for: unverified))
    }

    static func testDirectRequestDecisionOriginIsolation() async {
        let allow = CoveChoice(
            identifier: CoveApprovalDecision.accept.rawValue,
            label: "Allow once"
        )
        func request(hostID: String, socketPath: String) -> CoveApprovalRequest {
            CoveApprovalRequest(
                schemaVersion: 1,
                category: .command,
                requestId: "shared-request",
                launchId: "shared-launch",
                sessionId: "shared-session",
                turnId: "shared-turn",
                source: .remoteCli,
                hostId: hostID,
                title: "Fixture",
                detail: nil,
                choices: [allow],
                amendments: [],
                permissionProfile: nil,
                decisionSocket: socketPath
            )
        }

        let remoteA = request(
            hostID: "remote-a",
            socketPath: "/tmp/remote-a-decision.sock"
        )
        let remoteB = request(
            hostID: "remote-b",
            socketPath: "/tmp/remote-b-decision.sock"
        )
        let sender = ProbeSender()
        let store = CoveStore(
            storage: MemoryStorage(),
            decisionSender: sender,
            initialState: CoveState(
                pendingDirectRequests: [
                    .approval(remoteA),
                    .approval(remoteB),
                ]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            decisionSuccessFeedbackDuration: .milliseconds(10)
        )
        precondition(store.selectApprovalChoice(allow, for: remoteA))
        precondition(store.confirmApproval(for: remoteA))
        let isolatedCompletion = await waitUntil {
            await sender.paths() == ["/tmp/remote-a-decision.sock"]
                && store.state.pendingDirectRequests == [.approval(remoteB)]
        }
        precondition(isolatedCompletion)
        let sentPaths = await sender.paths()
        precondition(sentPaths == ["/tmp/remote-a-decision.sock"])
        precondition(
            store.state.pendingDirectRequests == [.approval(remoteB)]
        )
    }

    static func testMissingExactOriginDoesNotUseCurrentLocation() {
        var openedURLs: [URL] = []
        let service = CoveSystemTerminalJumpService(openExternalURL: {
            openedURLs.append($0)
            return true
        })
        service.observe(
            CoveWireEnvelope(
                eventId: "unrelated-desktop",
                kind: .sessionSnapshot,
                timestamp: Date(timeIntervalSince1970: 1),
                source: .codexDesktop,
                sessionId: "unrelated-desktop",
                payload: .object([:])
            )
        )
        let missing = CoveSessionSnapshot(
            snapshotId: "missing-local",
            status: .waitingApproval,
            priority: 100,
            title: "Missing local origin",
            timestamp: Date(timeIntervalSince1970: 2),
            sessionId: "missing-local",
            launchId: "missing-launch",
            source: .localCli
        )
        precondition(!service.canJump(to: missing))
        let result = service.jump(to: missing)
        precondition(!result.focusedExactLocation)
        precondition(openedURLs.isEmpty)

        let desktop = CoveSessionSnapshot(
            snapshotId: "verified-desktop",
            status: .waitingInput,
            priority: 95,
            title: "Verified Desktop",
            timestamp: Date(timeIntervalSince1970: 3),
            sessionId: "verified-desktop",
            source: .codexDesktop
        )
        precondition(service.canJump(to: desktop))
        precondition(service.jump(to: desktop).focusedExactLocation)
        precondition(
            openedURLs.map(\.absoluteString)
                == ["codex://threads/verified-desktop"]
        )
        let emptyDesktop = CoveSessionSnapshot(
            snapshotId: "empty-desktop",
            status: .waitingInput,
            priority: 95,
            title: "Empty Desktop identifier",
            timestamp: Date(timeIntervalSince1970: 3),
            sessionId: "",
            source: .codexDesktop
        )
        precondition(!service.canJump(to: emptyDesktop))
        precondition(!service.jump(to: emptyDesktop).focusedExactLocation)
        precondition(
            openedURLs.map(\.absoluteString)
                == ["codex://threads/verified-desktop"]
        )

        let missingRequest = CoveDirectRequest.approval(
            CoveApprovalRequest(
                schemaVersion: 1,
                category: .command,
                requestId: "missing-request",
                launchId: "missing-launch",
                sessionId: "missing-session",
                source: .localCli,
                title: "Missing",
                detail: nil,
                choices: [],
                amendments: [],
                permissionProfile: nil,
                decisionSocket: nil
            )
        )
        var callbackCount = 0
        let store = CoveStore(
            storage: MemoryStorage(),
            decisionSender: ProbeSender(),
            initialState: CoveState(
                session: CoveSessionState(
                    isExpanded: true,
                    snapshots: [
                        CoveSessionSnapshot(
                            snapshotId: "current-unrelated",
                            status: .working,
                            priority: 40,
                            title: "Unrelated",
                            timestamp: Date(timeIntervalSince1970: 4),
                            sessionId: "current-unrelated",
                            launchId: "current-launch",
                            source: .localCli
                        )
                    ]
                ),
                pendingDirectRequests: [missingRequest]
            ),
            persistenceWritesEnabledOverride: false,
            initialSoundPreferences: CoveSoundPreferences(),
            soundWritesEnabled: false,
            initialCustomThemes: [],
            openExternalURL: { _ in
                fatalError("A missing exact target must not open a fallback URL")
            }
        )
        store.onOpenDirectRequest = { _ in
            callbackCount += 1
            return CoveJumpResult(
                focusedExactLocation: true,
                message: "Unexpected"
            )
        }
        precondition(!store.openInCodex(for: missingRequest))
        precondition(callbackCount == 0)
        precondition(
            store.decisionDelivery.errorMessage(for: missingRequest.key)
                == "The exact originating Codex location is not currently available."
        )
        precondition(store.state.pendingDirectRequests.contains(missingRequest))
    }

    static func testNotificationOriginResolution() {
        func snapshot(
            id: String,
            sessionID: String?,
            launchID: String?,
            source: CoveWireSource = .localCli,
            hostID: String? = nil,
            seconds: TimeInterval = 0
        ) -> CoveSessionSnapshot {
            CoveSessionSnapshot(
                snapshotId: id,
                status: .waitingInput,
                priority: 95,
                title: id,
                timestamp: Date(timeIntervalSince1970: seconds),
                sessionId: sessionID,
                launchId: launchID,
                source: source,
                hostId: hostID
            )
        }

        let exact = snapshot(
            id: "exact",
            sessionID: "session-a",
            launchID: "launch-a"
        )
        let sameSessionWrongLaunch = snapshot(
            id: "same-session-wrong-launch",
            sessionID: "session-a",
            launchID: "launch-b"
        )
        let sameLaunchWrongSession = snapshot(
            id: "same-launch-wrong-session",
            sessionID: "session-b",
            launchID: "launch-a"
        )
        let unrelatedCurrent = snapshot(
            id: "unrelated-current",
            sessionID: "current-session",
            launchID: "current-launch",
            seconds: 100
        )
        let snapshots = [
            unrelatedCurrent,
            sameSessionWrongLaunch,
            sameLaunchWrongSession,
            exact,
        ]

        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "session-a",
                launchID: "launch-a",
                source: .localCli,
                hostID: nil,
                in: snapshots
            ) == exact
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "missing-session",
                launchID: "missing-launch",
                source: .localCli,
                hostID: nil,
                in: snapshots
            ) == nil
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "session-a",
                launchID: "missing-launch",
                source: .localCli,
                hostID: nil,
                in: snapshots
            ) == nil
        )

        let desktop = snapshot(
            id: "desktop-session",
            sessionID: nil,
            launchID: nil,
            source: .codexDesktop
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "desktop-session",
                launchID: nil,
                source: .codexDesktop,
                hostID: nil,
                in: [unrelatedCurrent, desktop]
            ) == desktop
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "session-a",
                launchID: nil,
                source: .localCli,
                hostID: nil,
                in: snapshots
            ) == nil
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "session-a",
                launchID: "launch-a",
                source: .localCli,
                hostID: nil,
                in: snapshots + [exact]
            ) == nil
        )

        let desktopCollision = snapshot(
            id: "desktop-collision",
            sessionID: "session-a",
            launchID: "launch-a",
            source: .codexDesktop
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "session-a",
                launchID: "launch-a",
                source: .codexDesktop,
                hostID: nil,
                in: snapshots + [desktopCollision]
            ) == desktopCollision
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "session-a",
                launchID: "launch-a",
                source: .localCli,
                hostID: nil,
                in: snapshots + [desktopCollision]
            ) == exact
        )

        let remoteA = snapshot(
            id: "remote-a",
            sessionID: "remote-session",
            launchID: "remote-launch",
            source: .remoteCli,
            hostID: "remote-a"
        )
        let remoteB = snapshot(
            id: "remote-b",
            sessionID: "remote-session",
            launchID: "remote-launch",
            source: .remoteCli,
            hostID: "remote-b"
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "remote-session",
                launchID: "remote-launch",
                source: .remoteCli,
                hostID: "remote-a",
                in: [remoteB, remoteA]
            ) == remoteA
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "remote-session",
                launchID: "remote-launch",
                source: .remoteCli,
                hostID: "remote-b",
                in: [remoteA, remoteB]
            ) == remoteB
        )
        precondition(
            CoveNotificationOriginResolver.snapshot(
                sessionID: "remote-session",
                launchID: "remote-launch",
                source: .remoteCli,
                hostID: nil,
                in: [remoteA, remoteB]
            ) == nil
        )
    }

    static func testMetadataOriginCollisionFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CoveSQLiteSessionMetadataStorage(
            url: directory.appendingPathComponent("sessions.sqlite3")
        )
        let bridge = CoveMetadataBridge(
            storage: storage,
            pinStoreURL: directory.appendingPathComponent("pins.json")
        )
        bridge.initialize()

        func statusEnvelope(
            eventID: String,
            source: CoveWireSource,
            hostID: String? = nil,
            timestamp: TimeInterval
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventID,
                kind: .sessionStatus,
                timestamp: Date(timeIntervalSince1970: timestamp),
                source: source,
                sessionId: "shared-metadata-session",
                launchId: "shared-metadata-launch",
                hostId: hostID,
                payload: .object([
                    "status": .string(CoveSessionStatus.working.rawValue),
                    "priority": .number(40),
                ])
            )
        }

        bridge.record(
            statusEnvelope(
                eventID: "local-metadata",
                source: .localCli,
                timestamp: 1
            ),
            state: CoveState()
        )
        bridge.record(
            statusEnvelope(
                eventID: "desktop-collision",
                source: .codexDesktop,
                timestamp: 2
            ),
            state: CoveState()
        )
        let localIdentity = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "shared-metadata-session"
        )!
        let desktopIdentity = CoveSessionIdentity(
            source: .codexDesktop,
            hostId: nil,
            sessionId: "shared-metadata-session"
        )!
        let ambiguousLocal = try storage.metadata(
            sessionId: "shared-metadata-session"
        )
        precondition(ambiguousLocal == nil)
        let retainedLocal = try storage.metadata(identity: localIdentity)
        precondition(retainedLocal?.source == .localCli)
        precondition(
            retainedLocal?.updatedAt == Date(timeIntervalSince1970: 1)
        )
        let retainedDesktop = try storage.metadata(identity: desktopIdentity)
        precondition(
            retainedDesktop?.updatedAt == Date(timeIntervalSince1970: 2)
        )

        bridge.remove(
            sessionID: "shared-metadata-session",
            source: .codexDesktop,
            hostID: nil
        )
        let localAfterWrongOriginRemoval = try storage.metadata(
            sessionId: "shared-metadata-session"
        )
        precondition(
            localAfterWrongOriginRemoval?.originScope
                == CoveOriginScope(source: .localCli, hostId: nil)
        )
        bridge.remove(
            sessionID: "shared-metadata-session",
            source: .localCli,
            hostID: nil
        )
        let localAfterExactRemoval = try storage.metadata(
            sessionId: "shared-metadata-session"
        )
        precondition(localAfterExactRemoval == nil)
        bridge.record(
            statusEnvelope(
                eventID: "remote-a-metadata",
                source: .remoteCli,
                hostID: "remote-a",
                timestamp: 3
            ),
            state: CoveState()
        )
        bridge.record(
            statusEnvelope(
                eventID: "remote-b-collision",
                source: .remoteCli,
                hostID: "remote-b",
                timestamp: 4
            ),
            state: CoveState()
        )
        let remoteAIdentity = CoveSessionIdentity(
            source: .remoteCli,
            hostId: "remote-a",
            sessionId: "shared-metadata-session"
        )!
        let remoteBIdentity = CoveSessionIdentity(
            source: .remoteCli,
            hostId: "remote-b",
            sessionId: "shared-metadata-session"
        )!
        let ambiguousRemote = try storage.metadata(
            sessionId: "shared-metadata-session"
        )
        precondition(ambiguousRemote == nil)
        let retainedRemote = try storage.metadata(identity: remoteAIdentity)
        precondition(retainedRemote?.source == .remoteCli)
        precondition(retainedRemote?.hostId == "remote-a")
        precondition(
            retainedRemote?.updatedAt == Date(timeIntervalSince1970: 3)
        )
        let retainedRemoteB = try storage.metadata(identity: remoteBIdentity)
        precondition(
            retainedRemoteB?.updatedAt == Date(timeIntervalSince1970: 4)
        )
        bridge.remove(
            sessionID: "shared-metadata-session",
            source: .remoteCli,
            hostID: "remote-b"
        )
        let remoteAfterWrongHostRemoval = try storage.metadata(
            sessionId: "shared-metadata-session"
        )
        precondition(remoteAfterWrongHostRemoval?.hostId == "remote-a")
        bridge.remove(
            sessionID: "shared-metadata-session",
            source: .remoteCli,
            hostID: "remote-a"
        )
        let remoteAfterExactRemoval = try storage.metadata(
            sessionId: "shared-metadata-session"
        )
        precondition(remoteAfterExactRemoval == nil)

        let sparseIdentity = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "sparse-metadata-session"
        )!
        bridge.record(
            CoveWireEnvelope(
                eventId: "sparse-metadata-initial",
                kind: .sessionStatus,
                timestamp: Date(timeIntervalSince1970: 5),
                source: .localCli,
                sessionId: sparseIdentity.sessionId,
                launchId: "sparse-launch",
                payload: .object([
                    "status": .string(CoveSessionStatus.working.rawValue),
                    "parentThreadId": .string("sparse-parent"),
                ])
            ),
            state: CoveState()
        )
        guard let omitted = CoveEventDecoder.decodeLine(
            #"{"schemaVersion":1,"eventId":"sparse-metadata-omitted","kind":"sessionStatus","timestamp":"1970-01-01T00:00:06Z","source":"localCli","sessionId":"sparse-metadata-session","payload":{"status":"working"}}"#
        ) else { fatalError("Expected omitted metadata envelope") }
        bridge.record(omitted, state: CoveState())
        let retained = try storage.metadata(identity: sparseIdentity)
        precondition(retained?.launchId == "sparse-launch")
        precondition(retained?.parentSessionId == "sparse-parent")

        guard let cleared = CoveEventDecoder.decodeLine(
            #"{"schemaVersion":1,"eventId":"sparse-metadata-cleared","kind":"sessionStatus","timestamp":"1970-01-01T00:00:07Z","source":"localCli","sessionId":"sparse-metadata-session","launchId":null,"payload":{"status":"working","parentThreadId":null}}"#
        ) else { fatalError("Expected explicit-null metadata envelope") }
        bridge.record(cleared, state: CoveState())
        let clearedMetadata = try storage.metadata(identity: sparseIdentity)
        precondition(clearedMetadata?.launchId == nil)
        precondition(clearedMetadata?.parentSessionId == nil)
    }

    static func testEditorFocusResponseContract() {
        func encoded(_ object: Any) -> Data {
            try! JSONSerialization.data(withJSONObject: object)
        }

        let prepareResponse = encoded([
            "ok": true,
            "terminalSelected": true,
        ])
        precondition(
            CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                prepareResponse,
                phase: "prepare"
            )
        )
        precondition(
            !CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                prepareResponse,
                phase: "focus"
            )
        )
        precondition(
            CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                encoded([
                    "ok": true,
                    "terminalSelected": true,
                    "windowFocused": true,
                ]),
                phase: "focus"
            )
        )

        let rejectedResponses: [Data] = [
            Data("not-json".utf8),
            encoded(["not-an-object"]),
            Data("{\"ok\":true,\"terminalSelected\":true}\n{\"ok\":true}".utf8),
            encoded(["ok": true]),
            encoded(["ok": true, "terminalSelected": false]),
            encoded(["ok": false, "terminalSelected": true]),
            encoded(["ok": "true", "terminalSelected": true]),
            encoded(["ok": 1, "terminalSelected": true]),
            encoded(["ok": true, "terminalSelected": "true"]),
            encoded(["ok": true, "terminalSelected": 1]),
        ]
        for response in rejectedResponses {
            precondition(
                !CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                    response,
                    phase: "prepare"
                )
            )
        }
        precondition(
            !CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                encoded([
                    "ok": true,
                    "terminalSelected": true,
                    "windowFocused": false,
                ]),
                phase: "focus"
            )
        )
        precondition(
            !CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                encoded([
                    "ok": true,
                    "terminalSelected": true,
                    "windowFocused": 1,
                ]),
                phase: "focus"
            )
        )
        precondition(
            !CoveSystemTerminalJumpService.acceptsEditorFocusResponse(
                prepareResponse,
                phase: "unexpected"
            )
        )
    }

    static func testEditorFocusSocketTransport() {
        let fragmented = Data(
            "{\"ok\":true,\"terminalSelected\":true,\"windowFocused\":true}\n".utf8
        )
        let fragmentedResult = runEditorFocusTransportProbe(
            response: fragmented,
            fragmentSize: 1,
            fragmentDelayMicroseconds: 500,
            clientTimeout: 5
        )
        precondition(fragmentedResult.accepted)

        let eofDelimited = Data(
            "{\"ok\":true,\"terminalSelected\":true,\"windowFocused\":true}".utf8
        )
        let eofResult = runEditorFocusTransportProbe(
            response: eofDelimited,
            fragmentSize: 2,
            fragmentDelayMicroseconds: 500,
            clientTimeout: 5
        )
        precondition(eofResult.accepted)

        let dripResult = runEditorFocusTransportProbe(
            response: fragmented,
            fragmentSize: 1,
            fragmentDelayMicroseconds: 30_000,
            clientTimeout: 0.12
        )
        precondition(!dripResult.accepted)
        precondition(dripResult.duration < 0.4)

        var oversized = Data(repeating: 0x20, count: 4_097)
        oversized.append(0x0a)
        let oversizedResult = runEditorFocusTransportProbe(
            response: oversized,
            fragmentSize: 512,
            clientTimeout: 0.5
        )
        precondition(!oversizedResult.accepted)

        let noDataResult = runEditorFocusTransportProbe(
            response: nil,
            holdOpenMicroseconds: 300_000,
            clientTimeout: 0.12
        )
        precondition(!noDataResult.accepted)
        precondition(noDataResult.duration >= 0.08)
        precondition(noDataResult.duration < 0.4)
    }

    static func runEditorFocusTransportProbe(
        response: Data?,
        fragmentSize: Int = 512,
        fragmentDelayMicroseconds: useconds_t = 0,
        holdOpenMicroseconds: useconds_t = 0,
        clientTimeout: TimeInterval
    ) -> (accepted: Bool, duration: TimeInterval) {
        precondition(fragmentSize > 0)
        let socketPath = "/tmp/cove-focus-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { source -> Bool in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, capacity) < capacity
            }
        }
        precondition(copied)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        precondition(bound == 0)
        precondition(Darwin.listen(listener, 1) == 0)

        let serverFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                close(listener)
                serverFinished.signal()
            }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }

            var suppressSigPipe: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &suppressSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            var requestChunk = [UInt8](repeating: 0, count: 512)
            while true {
                let count = requestChunk.withUnsafeMutableBytes { bytes in
                    Darwin.read(client, bytes.baseAddress, bytes.count)
                }
                if count <= 0 || requestChunk.prefix(count).contains(0x0a) {
                    break
                }
            }

            if let response {
                response.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        let fragmentEnd = min(offset + fragmentSize, bytes.count)
                        while offset < fragmentEnd {
                            let count = Darwin.write(
                                client,
                                baseAddress.advanced(by: offset),
                                fragmentEnd - offset
                            )
                            if count > 0 {
                                offset += count
                            } else if count < 0, errno == EINTR {
                                continue
                            } else {
                                return
                            }
                        }
                        if fragmentDelayMicroseconds > 0,
                           offset < bytes.count {
                            usleep(fragmentDelayMicroseconds)
                        }
                    }
                }
            } else if holdOpenMicroseconds > 0 {
                usleep(holdOpenMicroseconds)
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        let accepted = CoveSystemTerminalJumpService.performEditorFocusRequest(
            terminalID: "transport-probe-terminal",
            phase: "focus",
            focusSocket: socketPath,
            timeout: clientTimeout
        )
        let duration = ProcessInfo.processInfo.systemUptime - started
        precondition(
            serverFinished.wait(timeout: .now() + 2) == .success
        )
        precondition(Darwin.unlink(socketPath) == 0)
        return (accepted, duration)
    }

    static func testEditorExactOriginBinding() {
        let editorID = "cove-editor-11111111-2222-4333-8444-555555555555"
        let otherEditorID = "cove-editor-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        precondition(
            CoveEditorWindowFocusMarker.make(
                focusSocketIdentifier: "111111111111"
            ) == "Codex Cove editor window 111111111111"
        )
        precondition(
            CoveEditorWindowFocusMarker.make(
                focusSocketIdentifier: "not-an-opaque-id"
            ) == nil
        )

        func focusSocketPath(_ identifier: String) -> String {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Codex Cove/run",
                    isDirectory: true
                )
                .appendingPathComponent("editor-\(identifier).sock")
                .path
        }

        func launch(
            eventID: String,
            sessionID: String,
            launchID: String,
            parentPID: Int,
            source: CoveWireSource = .localCli,
            hostID: String? = nil,
            oscMarker: String? = nil,
            tmuxPane: String? = nil
        ) -> CoveWireEnvelope {
            var payload: [String: CoveJSONValue] = [
                "parentPid": .number(Double(parentPID)),
                "termProgram": .string("vscode"),
            ]
            if let oscMarker {
                payload["oscMarker"] = .string(oscMarker)
            }
            if let tmuxPane {
                payload["tmuxPane"] = .string(tmuxPane)
            }
            return CoveWireEnvelope(
                eventId: eventID,
                kind: .launch,
                timestamp: Date(timeIntervalSince1970: 10),
                source: source,
                sessionId: sessionID,
                launchId: launchID,
                hostId: hostID,
                payload: .object(payload)
            )
        }

        func registration(
            eventID: String,
            terminalID: String,
            registrationLaunchID: String?,
            envelopeLaunchID: String?,
            processID: Int,
            focusSocket: String? = nil,
            focusSocketID: String = "111111111111",
            source: CoveWireSource = .localCli,
            hostID: String? = nil
        ) -> CoveWireEnvelope {
            var terminal: [String: CoveJSONValue] = [
                "terminalId": .string(terminalID),
                "terminalName": .string("Fixture Integrated Terminal"),
                "processId": .number(Double(processID)),
            ]
            if let registrationLaunchID {
                terminal["launchId"] = .string(registrationLaunchID)
            }
            return CoveWireEnvelope(
                eventId: eventID,
                kind: CoveWireEventKind(rawValue: "terminal.registered"),
                timestamp: Date(timeIntervalSince1970: 9),
                source: source,
                sessionId: "editor-host-session",
                launchId: envelopeLaunchID,
                hostId: hostID,
                payload: .object([
                    "terminal": .object(terminal),
                    "focusSocket": .string(
                        focusSocket ?? focusSocketPath(focusSocketID)
                    ),
                    "focusSocketId": .string(focusSocketID),
                    "editorHost": .object([
                        "applicationName": .string("Fixture Editor"),
                    ]),
                ])
            )
        }

        func snapshot(
            sessionID: String,
            launchID: String?,
            source: CoveWireSource = .localCli,
            hostID: String? = nil
        ) -> CoveSessionSnapshot {
            CoveSessionSnapshot(
                snapshotId: "snapshot-\(sessionID)",
                status: .waitingInput,
                priority: 95,
                title: "Fixture",
                timestamp: Date(timeIntervalSince1970: 11),
                sessionId: sessionID,
                launchId: launchID,
                source: source,
                hostId: hostID
            )
        }

        // A live registration is trusted only when its strict opaque socket ID
        // and absolute socket path describe the same Cove-owned endpoint.
        let rejectedSocketRegistration = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { _, _ in
                fatalError("A non-canonical editor socket must not be focused")
            }
        )
        let rejectedSocketLaunch = launch(
            eventID: "rejected-socket-launch",
            sessionID: "rejected-socket-session",
            launchID: editorID,
            parentPID: 9_000
        )
        rejectedSocketRegistration.observe(rejectedSocketLaunch)
        rejectedSocketRegistration.observe(
            registration(
                eventID: "mismatched-socket-registration",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 9_000,
                focusSocket: focusSocketPath("222222222222"),
                focusSocketID: "111111111111"
            )
        )
        rejectedSocketRegistration.observe(
            registration(
                eventID: "invalid-socket-id-registration",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 9_000,
                focusSocket: focusSocketPath("ABCDEF123456"),
                focusSocketID: "ABCDEF123456"
            )
        )
        precondition(
            rejectedSocketRegistration.terminalLocationMetadata(
                for: rejectedSocketLaunch
            )?.editorTerminalIdentifier == nil
        )
        precondition(
            !rejectedSocketRegistration.jump(
                to: snapshot(
                    sessionID: "rejected-socket-session",
                    launchID: editorID
                )
            ).focusedExactLocation
        )

        // Registration before launch binds by the shared opaque identifier,
        // even though editor and Codex wrapper PIDs do not match.
        var registrationFirstFocuses: [String] = []
        var registrationFirstActions: [String] = []
        var registrationFirstSelectedWindow: String?
        let registrationFirst = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { terminalID, phase in
                registrationFirstFocuses.append(terminalID)
                registrationFirstActions.append("\(phase):\(terminalID)")
                registrationFirstSelectedWindow = terminalID
                return true
            },
            focusEditorWindowOverride: { bundleIdentifier, applicationName, focusSocketID in
                precondition(bundleIdentifier == nil)
                precondition(
                    focusSocketID == "111111111111"
                        || focusSocketID == "222222222222"
                )
                registrationFirstActions.append("window:\(applicationName)")
                registrationFirstSelectedWindow = editorID
                return true
            }
        )
        registrationFirst.observe(
            registration(
                eventID: "registered-first",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 9_001
            )
        )
        let firstLaunch = launch(
            eventID: "launch-after-registration",
            sessionID: "editor-session-old",
            launchID: editorID,
            parentPID: 8_001
        )
        registrationFirst.observe(firstLaunch)
        precondition(
            registrationFirst.terminalLocationMetadata(for: firstLaunch)?
                .editorTerminalIdentifier == editorID
        )
        precondition(
            registrationFirst.jump(
                to: snapshot(
                    sessionID: "editor-session-old",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(registrationFirstFocuses == [editorID, editorID])
        precondition(
            registrationFirstActions == [
                "prepare:\(editorID)",
                "window:Fixture Editor",
                "focus:\(editorID)",
            ]
        )
        precondition(registrationFirstSelectedWindow == editorID)

        // A second Codex task in the same terminal reuses the routed ID. The
        // first task remains exactly focusable instead of being overwritten.
        let secondLaunch = launch(
            eventID: "launch-second-session",
            sessionID: "editor-session-new",
            launchID: editorID,
            parentPID: 8_002
        )
        registrationFirst.observe(secondLaunch)
        precondition(
            registrationFirst.jump(
                to: snapshot(
                    sessionID: "editor-session-old",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(
            registrationFirst.jump(
                to: snapshot(
                    sessionID: "editor-session-new",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(
            registrationFirstFocuses
                == [editorID, editorID, editorID, editorID, editorID, editorID]
        )
        precondition(
            registrationFirstActions == [
                "prepare:\(editorID)", "window:Fixture Editor", "focus:\(editorID)",
                "prepare:\(editorID)", "window:Fixture Editor", "focus:\(editorID)",
                "prepare:\(editorID)", "window:Fixture Editor", "focus:\(editorID)",
            ]
        )
        precondition(registrationFirstSelectedWindow == editorID)

        // Reloading the same editor window rotates its process-local focus
        // socket. The new registration replaces the stale location instead of
        // making exact lookup ambiguous, while both sequential tasks retain
        // their terminal membership.
        registrationFirst.observe(
            registration(
                eventID: "registration-after-socket-rotation",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 9_002,
                focusSocket: focusSocketPath("222222222222"),
                focusSocketID: "222222222222"
            )
        )
        precondition(
            registrationFirst.terminalLocationMetadata(for: secondLaunch)?
                .focusSocketIdentifier == "222222222222"
        )
        precondition(
            registrationFirst.jump(
                to: snapshot(
                    sessionID: "editor-session-old",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(
            registrationFirst.jump(
                to: snapshot(
                    sessionID: "editor-session-new",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(
            registrationFirstFocuses
                == Array(repeating: editorID, count: 10)
        )
        precondition(
            registrationFirstActions.suffix(6) == [
                "prepare:\(editorID)", "window:Fixture Editor", "focus:\(editorID)",
                "prepare:\(editorID)", "window:Fixture Editor", "focus:\(editorID)",
            ]
        )
        precondition(registrationFirstSelectedWindow == editorID)

        let focusCountBeforeMismatch = registrationFirstFocuses.count
        precondition(
            !registrationFirst.jump(
                to: snapshot(
                    sessionID: "editor-session-old",
                    launchID: otherEditorID
                )
            ).focusedExactLocation
        )
        precondition(registrationFirstFocuses.count == focusCountBeforeMismatch)

        // Exact native-window activation is mandatory. Selecting only the
        // terminal in a background editor window must fail closed.
        var activationFailureActions: [String] = []
        let activationFailure = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { terminalID, phase in
                activationFailureActions.append("\(phase):\(terminalID)")
                return true
            },
            focusEditorWindowOverride: { _, applicationName, _ in
                activationFailureActions.append("window:\(applicationName)")
                return false
            }
        )
        activationFailure.observe(
            registration(
                eventID: "activation-failure-registration",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 8_101
            )
        )
        let activationFailureLaunch = launch(
            eventID: "activation-failure-launch",
            sessionID: "activation-failure-session",
            launchID: editorID,
            parentPID: 8_102
        )
        activationFailure.observe(activationFailureLaunch)
        precondition(
            !activationFailure.jump(
                to: snapshot(
                    sessionID: "activation-failure-session",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(
            activationFailureActions == [
                "prepare:\(editorID)",
                "window:Fixture Editor",
            ]
        )

        var focusFailureActions: [String] = []
        var focusFailureAttempt = 0
        let focusFailure = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { terminalID, phase in
                focusFailureActions.append("\(phase):\(terminalID)")
                focusFailureAttempt += 1
                return focusFailureAttempt == 1
            },
            focusEditorWindowOverride: { _, applicationName, _ in
                focusFailureActions.append("window:\(applicationName)")
                return true
            }
        )
        focusFailure.observe(
            registration(
                eventID: "focus-failure-registration",
                terminalID: otherEditorID,
                registrationLaunchID: otherEditorID,
                envelopeLaunchID: otherEditorID,
                processID: 8_201
            )
        )
        let focusFailureLaunch = launch(
            eventID: "focus-failure-launch",
            sessionID: "focus-failure-session",
            launchID: otherEditorID,
            parentPID: 8_202
        )
        focusFailure.observe(focusFailureLaunch)
        precondition(
            !focusFailure.jump(
                to: snapshot(
                    sessionID: "focus-failure-session",
                    launchID: otherEditorID
                )
            ).focusedExactLocation
        )
        precondition(
            focusFailureActions == [
                "prepare:\(otherEditorID)",
                "window:Fixture Editor",
                "focus:\(otherEditorID)",
            ]
        )

        // Selecting a tmux pane is not an exact editor jump when the target
        // window's focus socket rejects the request.
        var tmuxFailureActions: [String] = []
        var tmuxFailureArguments: [String] = []
        let tmuxFocusFailure = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { terminalID, phase in
                tmuxFailureActions.append("\(phase):\(terminalID)")
                return false
            },
            focusEditorWindowOverride: { _, applicationName, _ in
                tmuxFailureActions.append("window:\(applicationName)")
                return true
            },
            runFirstAvailableOverride: { _, arguments in
                tmuxFailureArguments = arguments
                return true
            }
        )
        tmuxFocusFailure.observe(
            registration(
                eventID: "tmux-focus-failure-registration",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 8_301
            )
        )
        let tmuxFocusFailureLaunch = launch(
            eventID: "tmux-focus-failure-launch",
            sessionID: "tmux-focus-failure-session",
            launchID: editorID,
            parentPID: 8_302,
            tmuxPane: "%99"
        )
        tmuxFocusFailure.observe(tmuxFocusFailureLaunch)
        precondition(
            !tmuxFocusFailure.jump(
                to: snapshot(
                    sessionID: "tmux-focus-failure-session",
                    launchID: editorID
                )
            ).focusedExactLocation
        )
        precondition(tmuxFailureArguments == ["select-pane", "-t", "%99"])
        precondition(
            tmuxFailureActions == [
                "prepare:\(editorID)",
            ]
        )

        // Launch before registration converges on the same exact binding and
        // likewise ignores the wrapper PID mismatch.
        var launchFirstFocuses: [String] = []
        let launchFirst = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { terminalID, _ in
                launchFirstFocuses.append(terminalID)
                return true
            },
            focusEditorWindowOverride: { _, _, focusSocketID in
                precondition(focusSocketID == "111111111111")
                return true
            }
        )
        let unboundLaunch = launch(
            eventID: "launch-first",
            sessionID: "launch-first-session",
            launchID: otherEditorID,
            parentPID: 7_001
        )
        launchFirst.observe(unboundLaunch)
        precondition(
            launchFirst.terminalLocationMetadata(for: unboundLaunch)?
                .editorTerminalIdentifier == nil
        )
        launchFirst.observe(
            registration(
                eventID: "registration-after-launch",
                terminalID: otherEditorID,
                registrationLaunchID: otherEditorID,
                envelopeLaunchID: otherEditorID,
                processID: 7_999
            )
        )
        precondition(
            launchFirst.terminalLocationMetadata(for: unboundLaunch)?
                .editorTerminalIdentifier == otherEditorID
        )
        precondition(
            launchFirst.jump(
                to: snapshot(
                    sessionID: "launch-first-session",
                    launchID: otherEditorID
                )
            ).focusedExactLocation
        )
        precondition(launchFirstFocuses == [otherEditorID, otherEditorID])

        // All three routed identifier fields must agree and use the editor
        // namespace. Arbitrary or mismatched IDs never create a direct link.
        let mismatched = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { _, _ in
                fatalError("A mismatched editor registration must not focus")
            }
        )
        let mismatchedLaunch = launch(
            eventID: "mismatched-launch",
            sessionID: "mismatched-session",
            launchID: editorID,
            parentPID: 6_001
        )
        mismatched.observe(mismatchedLaunch)
        mismatched.observe(
            registration(
                eventID: "mismatched-registration",
                terminalID: editorID,
                registrationLaunchID: otherEditorID,
                envelopeLaunchID: editorID,
                processID: 6_001
            )
        )
        precondition(
            mismatched.terminalLocationMetadata(for: mismatchedLaunch)?
                .editorTerminalIdentifier == nil
        )
        precondition(
            !mismatched.jump(
                to: snapshot(
                    sessionID: "mismatched-session",
                    launchID: editorID
                )
            ).focusedExactLocation
        )

        let nonEditorID = "cove-terminal-12345678-1234-4234-8234-123456789abc"
        let nonEditor = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { _, _ in
                fatalError("A non-editor identifier must not focus by ID")
            }
        )
        let nonEditorLaunch = launch(
            eventID: "non-editor-launch",
            sessionID: "non-editor-session",
            launchID: nonEditorID,
            parentPID: 5_001
        )
        nonEditor.observe(nonEditorLaunch)
        nonEditor.observe(
            registration(
                eventID: "non-editor-registration",
                terminalID: nonEditorID,
                registrationLaunchID: nonEditorID,
                envelopeLaunchID: nonEditorID,
                processID: 5_999
            )
        )
        precondition(
            nonEditor.terminalLocationMetadata(for: nonEditorLaunch)?
                .editorTerminalIdentifier == nil
        )
        precondition(
            !nonEditor.jump(
                to: snapshot(
                    sessionID: "non-editor-session",
                    launchID: nonEditorID
                )
            ).focusedExactLocation
        )

        // Registrations are local-only evidence; a remote launch with the same
        // opaque text cannot inherit an editor focus route.
        let remote = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { _, _ in
                fatalError("A remote launch must not inherit a local editor route")
            }
        )
        remote.observe(
            registration(
                eventID: "local-registration-for-remote-check",
                terminalID: editorID,
                registrationLaunchID: editorID,
                envelopeLaunchID: editorID,
                processID: 4_001
            )
        )
        let remoteLaunch = launch(
            eventID: "remote-launch",
            sessionID: "remote-session",
            launchID: editorID,
            parentPID: 4_001,
            source: .remoteCli,
            hostID: "remote-fixture"
        )
        remote.observe(remoteLaunch)
        precondition(
            remote.terminalLocationMetadata(for: remoteLaunch)?
                .editorTerminalIdentifier == nil
        )
        precondition(
            !remote.jump(
                to: snapshot(
                    sessionID: "remote-session",
                    launchID: editorID,
                    source: .remoteCli,
                    hostID: "remote-fixture"
                )
            ).focusedExactLocation
        )

        // A remote registration must not become local PID-routing evidence.
        // Otherwise a colliding remote process ID could redirect a local task
        // to an unrelated editor focus socket.
        let remoteRegistration = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false },
            focusEditorOverride: { _, _ in
                fatalError("Remote editor evidence must not focus a local task")
            }
        )
        remoteRegistration.observe(
            registration(
                eventID: "remote-registration-for-local-check",
                terminalID: "cove-terminal-12345678-1234-4234-8234-123456789abc",
                registrationLaunchID: nil,
                envelopeLaunchID: nil,
                processID: 4_050,
                source: .remoteCli,
                hostID: "remote-fixture"
            )
        )
        let localPIDCollision = launch(
            eventID: "local-pid-collision",
            sessionID: "local-pid-collision-session",
            launchID: "local-pid-collision-launch",
            parentPID: 4_050
        )
        remoteRegistration.observe(localPIDCollision)
        precondition(
            remoteRegistration.terminalLocationMetadata(for: localPIDCollision)?
                .editorTerminalIdentifier == nil
        )
        precondition(
            !remoteRegistration.jump(
                to: snapshot(
                    sessionID: "local-pid-collision-session",
                    launchID: "local-pid-collision-launch"
                )
            ).focusedExactLocation
        )

        // A launch/session tuple can be reused independently by remote hosts.
        // Cove retains both composite records, but a shared OSC marker is not
        // sufficient proof of which host owns the visible terminal, so both
        // focus attempts fail closed before invoking Automation.
        let remoteCollision = CoveSystemTerminalJumpService(
            openExternalURL: { _ in false }
        )
        let remoteA = launch(
            eventID: "remote-a-collision",
            sessionID: "remote-shared-session",
            launchID: "remote-shared-launch",
            parentPID: 4_101,
            source: .remoteCli,
            hostID: "remote-a",
            oscMarker: "shared-marker"
        )
        let remoteB = launch(
            eventID: "remote-b-collision",
            sessionID: "remote-shared-session",
            launchID: "remote-shared-launch",
            parentPID: 4_102,
            source: .remoteCli,
            hostID: "remote-b",
            oscMarker: "shared-marker"
        )
        remoteCollision.observe(remoteA)
        remoteCollision.observe(remoteB)
        precondition(
            remoteCollision.terminalLocationMetadata(for: remoteA)?
                .oscMarkerIdentifier == "shared-marker"
        )
        precondition(
            remoteCollision.terminalLocationMetadata(for: remoteB)?
                .oscMarkerIdentifier == "shared-marker"
        )
        precondition(
            !remoteCollision.jump(
                to: snapshot(
                    sessionID: "remote-shared-session",
                    launchID: "remote-shared-launch",
                    source: .remoteCli,
                    hostID: "remote-a"
                )
            ).focusedExactLocation
        )
        precondition(
            !remoteCollision.jump(
                to: snapshot(
                    sessionID: "remote-shared-session",
                    launchID: "remote-shared-launch",
                    source: .remoteCli,
                    hostID: "remote-b"
                )
            ).focusedExactLocation
        )

        let legacyRemote = launch(
            eventID: "remote-missing-host",
            sessionID: "legacy-remote-session",
            launchID: "legacy-remote-launch",
            parentPID: 4_103,
            source: .remoteCli
        )
        remoteCollision.observe(legacyRemote)
        precondition(
            !remoteCollision.jump(
                to: snapshot(
                    sessionID: "legacy-remote-session",
                    launchID: "legacy-remote-launch",
                    source: .remoteCli
                )
            ).focusedExactLocation
        )

        // Session-only fallback remains fail-closed when more than one launch
        // could be the origin.
        let ambiguous = CoveSystemTerminalJumpService(openExternalURL: { _ in false })
        ambiguous.observe(
            launch(
                eventID: "ambiguous-one",
                sessionID: "shared-session",
                launchID: "launch-one",
                parentPID: 3_001
            )
        )
        ambiguous.observe(
            launch(
                eventID: "ambiguous-two",
                sessionID: "shared-session",
                launchID: "launch-two",
                parentPID: 3_002
            )
        )
        let ambiguousResult = ambiguous.jump(
            to: snapshot(sessionID: "shared-session", launchID: nil)
        )
        precondition(!ambiguousResult.focusedExactLocation)
        precondition(
            ambiguousResult.message
                == "The exact originating Codex location is not currently available."
        )
    }

    static func testUITestTemporaryDirectoryPolicy() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "CoveUITestPathPolicy-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: testRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: testRoot) }

        let hostTemporaryRoot = testRoot.appendingPathComponent(
            "host-temporary",
            isDirectory: true
        )
        let fakeHome = testRoot.appendingPathComponent(
            "home",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: hostTemporaryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: fakeHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Normal host-temporary descendants may be created and are tightened
        // to the current user with mode 0700.
        let hostRequested = hostTemporaryRoot
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        let preparedHost = CoveUITestConfiguration.prepareTemporaryDirectory(
            requestedDirectory: hostRequested,
            fileManager: fileManager,
            temporaryRootOverride: hostTemporaryRoot,
            homeDirectoryOverride: fakeHome
        )
        precondition(
            preparedHost == hostRequested.resolvingSymlinksInPath()
                .standardizedFileURL
        )
        let hostAttributes = try fileManager.attributesOfItem(
            atPath: hostRequested.path
        )
        precondition(
            ((hostAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)
                & 0o777 == 0o700
        )

        let runnerRoot = fakeHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(
                CoveUITestConfiguration.runnerBundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(
            at: runnerRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runnerRequested = runnerRoot.appendingPathComponent(
            "\(CoveUITestConfiguration.fixtureDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: runnerRequested,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        // The exact pre-created xctrunner direct child is accepted.
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: runnerRequested,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome
            ) == runnerRequested.standardizedFileURL
        )

        // Ownership and mode are validation, not mutations, for the runner.
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: runnerRequested,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome,
                effectiveUserID: getuid() &+ 1
            ) == nil
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runnerRequested.path
        )
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: runnerRequested,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome
            ) == nil
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runnerRequested.path
        )

        let invalidUUID = runnerRoot.appendingPathComponent(
            "\(CoveUITestConfiguration.fixtureDirectoryPrefix)not-a-uuid",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: invalidUUID,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: invalidUUID,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome
            ) == nil
        )

        let missingRunnerChild = runnerRoot.appendingPathComponent(
            "\(CoveUITestConfiguration.fixtureDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: missingRunnerChild,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome
            ) == nil
        )

        let nestedRunnerChild = runnerRequested.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: nestedRunnerChild,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome
            ) == nil
        )

        let arbitraryDirectory = fakeHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support/CodexCove",
                isDirectory: true
            )
        precondition(
            CoveUITestConfiguration.prepareTemporaryDirectory(
                requestedDirectory: arbitraryDirectory,
                fileManager: fileManager,
                temporaryRootOverride: hostTemporaryRoot,
                homeDirectoryOverride: fakeHome
            ) == nil
        )

        // Existing symbolic links are rejected in both accepted boundaries.
        let outside = testRoot.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: outside,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let hostLink = hostTemporaryRoot.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        let symlinkResult = outside.path.withCString { source in
            hostLink.path.withCString { destination in
                Darwin.symlink(source, destination)
            }
        }
        if symlinkResult == 0 {
            precondition(
                CoveUITestConfiguration.prepareTemporaryDirectory(
                    requestedDirectory: hostLink.appendingPathComponent(
                        "state",
                        isDirectory: true
                    ),
                    fileManager: fileManager,
                    temporaryRootOverride: hostTemporaryRoot,
                    homeDirectoryOverride: fakeHome
                ) == nil
            )
        } else {
            precondition(errno == EPERM)
        }

        // The bundle gate remains mandatory even for an otherwise valid path.
        precondition(
            CoveUITestConfiguration.detect(
                arguments: [
                    "CodexCove",
                    "--ui-test-fixture", "empty-queue",
                    "--ui-test-state-dir", runnerRequested.path,
                ],
                bundleIdentifier: "local.chris.codexcove"
            ) == nil
        )
    }
}
