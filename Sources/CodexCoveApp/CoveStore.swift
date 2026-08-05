import AppKit
import Foundation
import Combine
import CoveCore

@MainActor
final class CoveStore: ObservableObject {
    var onJumpToSession: ((CoveSessionSnapshot) -> Void)?
    var onOpenDirectRequest: ((CoveSessionSnapshot) -> CoveJumpResult)?
    var onMarkRead: ((String) -> Void)?
    var onDismissSession: ((String) -> Bool)?
    var onDismissSessions: (([String]) -> Bool)?
    var onSetPinned: ((String, Bool) -> Bool)?
    var onScheduleFollowUp: ((String, Date) -> Bool)?
    var onCancelFollowUp: ((String) -> Bool)?
    var onDecisionAttempt: ((CoveDecisionAttempt) -> Void)?

    @Published private(set) var state: CoveState
    @Published private(set) var overlayPresentation: CoveOverlayPresentation = .collapsed
    @Published private(set) var pendingDirtyExitConfirmation:
        CovePendingDirtyExitConfirmation?
    @Published private(set) var actionDrafts = CoveActionDraftState()
    @Published private(set) var decisionDelivery = CoveDecisionDeliveryState()
    @Published private(set) var decisionAttemptCount = 0
    @Published private(set) var fixtureRecordedDecisionCount = 0
    @Published private(set) var fixtureRecordedJumpCount = 0
    @Published private(set) var soundPreferences: CoveSoundPreferences
    @Published private(set) var customThemes: [CoveThemePalette] = []
    @Published private(set) var themePreview: CoveThemePalette?
    @Published private(set) var persistenceWarning: String?
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var reminders: [String: Date] = [:]

    private let storage: CoveStateStorage
    private let themeStorage: CoveThemeFileStore
    private let decisionSender: any CoveDecisionSending
    private let soundPreferencesStorage: CoveSoundPreferencesStorage
    private let persistenceWritesEnabled: Bool
    private let soundWritesEnabled: Bool
    private let decisionSuccessFeedbackDuration: Duration
    private let openExternalURL: (URL) -> Bool
    private var lastPersistedSettings: CoveSettings? = nil
    private var decisionTasks: [
        CoveDirectRequestKey: Task<Void, Never>
    ] = [:]
    private var hoverExpansionTask: Task<Void, Never>?
    private var autoCollapseTask: Task<Void, Never>?
    private var idleAutoHideTask: Task<Void, Never>?
    private var interactionReleaseTask: Task<Void, Never>?
    private var isOverlayHovered = false
    private var isOverlayFocused = false
    private var isDirectInteractionActive = false
    private var isSettingsPresented = false

    init(
        storage: CoveStateStorage,
        decisionSender: any CoveDecisionSending = CoveDecisionSocketClient(),
        soundPreferencesStorage: CoveSoundPreferencesStorage = .init(),
        themeStorage: CoveThemeFileStore = .applicationSupportStore(),
        initialState: CoveState? = nil,
        persistenceWritesEnabledOverride: Bool? = nil,
        initialSoundPreferences: CoveSoundPreferences? = nil,
        soundWritesEnabled: Bool = true,
        initialCustomThemes: [CoveThemePalette]? = nil,
        decisionSuccessFeedbackDuration: Duration = .milliseconds(700),
        openExternalURL: @escaping (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) {
        self.storage = storage
        self.themeStorage = themeStorage
        self.decisionSender = decisionSender
        self.soundPreferencesStorage = soundPreferencesStorage
        self.soundWritesEnabled = soundWritesEnabled
        self.decisionSuccessFeedbackDuration = decisionSuccessFeedbackDuration
        self.openExternalURL = openExternalURL
        self.soundPreferences = initialSoundPreferences
            ?? (initialState == nil
                ? soundPreferencesStorage.load()
                : CoveSoundPreferences())

        if let initialState {
            self.state = initialState
            self.persistenceWritesEnabled = persistenceWritesEnabledOverride
                ?? false
            self.persistenceWarning = nil
        } else {
            do {
                self.state = try storage.load() ?? CoveState()
                self.persistenceWritesEnabled =
                    persistenceWritesEnabledOverride ?? true
                self.persistenceWarning = nil
            } catch {
                self.state = CoveState()
                self.persistenceWritesEnabled = false
                let warning = [
                    "Settings could not be loaded and were left untouched.",
                    "Persistence is disabled until Codex Cove is explicitly repaired.",
                    error.localizedDescription
                ].joined(separator: " ")
                self.persistenceWarning = warning
                NSLog("Codex Cove: \(warning)")
            }
        }
        self.lastPersistedSettings = self.state.settings
        self.overlayPresentation = self.state.session.isExpanded
            ? .queue
            : .collapsed

        if let initialCustomThemes {
            self.customThemes = initialCustomThemes
        } else if initialState != nil {
            // Fixture/preview state must not read normal Application Support.
            self.customThemes = []
        } else {
            do {
                self.customThemes = try themeStorage.loadCustomThemes()
            } catch {
                self.customThemes = []
                NSLog(
                    "Codex Cove: custom themes could not be loaded and were left untouched: \(error.localizedDescription)"
                )
            }
        }
        if initialState == nil {
            if let customThemeID = self.state.settings.customThemeID,
               let selectedTheme = self.customThemes.first(where: {
                   $0.identifier == customThemeID
               }) {
                self.state.theme = selectedTheme
            } else {
                self.state.settings.customThemeID = nil
                self.state.theme = CoveThemeCatalog.palette(
                    for: self.state.settings.themeFamily,
                    palette: self.state.settings.palette
                )
            }
        }
    }

    func dispatch(_ action: CoveAction) {
        if isSettingsPresented, actionRequestsExpansion(action) {
            return
        }
        if actionRequestsCollapse(action),
           let requestKey = focusedDirtyRequestKey {
            pendingDirtyExitConfirmation = .init(
                requestKey: requestKey,
                destination: .collapsed
            )
            return
        }
        let previousRequestKeys = Set(
            state.pendingDirectRequests.map(\.key)
        )
        CoveReducer.reduce(&state, action)
        let currentRequestKeys = Set(
            state.pendingDirectRequests.map(\.key)
        )
        actionDrafts.retain(keys: currentRequestKeys)
        decisionDelivery.retain(keys: currentRequestKeys)
        for removedKey in previousRequestKeys.subtracting(currentRequestKeys) {
            decisionTasks.removeValue(forKey: removedKey)?.cancel()
        }
        if let pendingDirtyExitConfirmation,
           !currentRequestKeys.contains(pendingDirtyExitConfirmation.requestKey) {
            self.pendingDirtyExitConfirmation = nil
        }
        reconcileOverlayPresentation(requestKeys: currentRequestKeys)
        if !previousRequestKeys.isEmpty,
           !isOverlayHovered,
           !isOverlayFocused,
           !isDirectInteractionActive {
            scheduleAutoCollapse()
        }
        normalizeSelectedSession()
        scheduleIdleAutoHide()
        flush()
    }

    func showQueue() {
        pendingDirtyExitConfirmation = nil
        applyOverlayPresentation(.queue)
    }

    func collapseForSettings() {
        isSettingsPresented = true
        themePreview = nil
        cancelInteractionTimers()
        isOverlayHovered = false
        isOverlayFocused = false
        isDirectInteractionActive = false
        pendingDirtyExitConfirmation = nil
        applyOverlayPresentation(.collapsed)
    }

    func endSettingsPresentation() {
        isSettingsPresented = false
        themePreview = nil
    }

    func previewTheme(_ theme: CoveThemePalette) {
        themePreview = configuredTheme(theme)
    }

    func clearThemePreview() {
        themePreview = nil
    }

    /// Test-host-only observation of frames actually received by the injected
    /// in-memory sender. Production never installs the recorder callback.
    func recordFixtureDecisionReceipt(count: Int) {
        fixtureRecordedDecisionCount = max(0, count)
    }

    func recordFixtureJump() {
        fixtureRecordedJumpCount += 1
    }

    @discardableResult
    func focusDirectRequest(_ requestKey: CoveDirectRequestKey) -> Bool {
        guard state.pendingDirectRequests.contains(where: {
            $0.key == requestKey
        }) else { return false }
        pendingDirtyExitConfirmation = nil
        applyOverlayPresentation(.focused(.directRequest(requestKey)))
        return true
    }

    @discardableResult
    func focusSession(_ sessionID: String) -> Bool {
        guard state.session.snapshots.contains(where: {
            ($0.sessionId ?? $0.snapshotId) == sessionID
        }) else { return false }
        pendingDirtyExitConfirmation = nil
        applyOverlayPresentation(.focused(.session(sessionID)))
        return true
    }

    func dirtyExitDisposition(
        for requestKey: CoveDirectRequestKey?
    ) -> CoveDirtyExitDisposition {
        CoveDirtyExitDisposition.resolve(
            requestKey: requestKey,
            drafts: actionDrafts
        )
    }

    var currentDirtyExitDisposition: CoveDirtyExitDisposition {
        dirtyExitDisposition(for: focusedDirectRequestKey)
    }

    /// Implements focused -> queue -> collapsed. A dirty focused request stays
    /// focused until the UI resolves `pendingDirtyExitConfirmation`.
    @discardableResult
    func requestPresentationBack() -> CoveDirtyExitDisposition {
        switch overlayPresentation {
        case .collapsed:
            return .exit
        case .queue:
            applyOverlayPresentation(.collapsed)
            return .exit
        case let .focused(.directRequest(requestKey)):
            let disposition = dirtyExitDisposition(for: requestKey)
            if case .confirmDiscard = disposition {
                pendingDirtyExitConfirmation = .init(
                    requestKey: requestKey,
                    destination: .queue
                )
            } else {
                applyOverlayPresentation(.queue)
            }
            return disposition
        case .focused(.session):
            applyOverlayPresentation(.queue)
            return .exit
        }
    }

    /// Explicit collapse follows the same dirty guard but targets collapsed
    /// rather than the intermediate queue state.
    @discardableResult
    func requestPresentationCollapse() -> CoveDirtyExitDisposition {
        let disposition = currentDirtyExitDisposition
        if case let .confirmDiscard(requestKey) = disposition {
            pendingDirtyExitConfirmation = .init(
                requestKey: requestKey,
                destination: .collapsed
            )
        } else {
            applyOverlayPresentation(.collapsed)
        }
        return disposition
    }

    func keepEditingPendingDirtyExit() {
        pendingDirtyExitConfirmation = nil
    }

    func discardPendingDirtyExit() {
        guard let confirmation = pendingDirtyExitConfirmation else { return }
        discardDraft(for: confirmation.requestKey)
        pendingDirtyExitConfirmation = nil
        applyOverlayPresentation(confirmation.destination)
    }

    func setOverlayHovered(_ hovered: Bool) {
        guard !isSettingsPresented else {
            isOverlayHovered = false
            return
        }
        isOverlayHovered = hovered
        hoverExpansionTask?.cancel()
        hoverExpansionTask = nil

        if hovered {
            autoCollapseTask?.cancel()
            autoCollapseTask = nil
            guard !state.session.isExpanded else { return }
            hoverExpansionTask = Task { [weak self] in
                try? await Task.sleep(
                    for: .seconds(self?.state.settings.hoverDelaySeconds ?? 0.25)
                )
                guard !Task.isCancelled,
                      let self,
                      self.isOverlayHovered
                else {
                    return
                }
                self.dispatch(.setExpanded(true))
            }
        } else {
            scheduleAutoCollapse()
            scheduleIdleAutoHide()
        }
    }

    func setOverlayFocused(_ focused: Bool) {
        guard !isSettingsPresented else {
            isOverlayFocused = false
            return
        }
        isOverlayFocused = focused
        if focused {
            isDirectInteractionActive = false
            interactionReleaseTask?.cancel()
            interactionReleaseTask = nil
            autoCollapseTask?.cancel()
            autoCollapseTask = nil
        } else {
            isDirectInteractionActive = false
            scheduleAutoCollapse()
        }
    }

    func beginOverlayInteraction(releaseAfterMilliseconds: UInt64 = 750) {
        guard !state.settings.minimalIslandMode,
              !isSettingsPresented
        else { return }
        isDirectInteractionActive = true
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        idleAutoHideTask?.cancel()
        idleAutoHideTask = nil
        if overlayPresentation == .collapsed {
            overlayPresentation = .queue
        }
        dispatch(.setExpanded(true))
        interactionReleaseTask?.cancel()
        interactionReleaseTask = Task { [weak self] in
            try? await Task.sleep(
                for: .milliseconds(releaseAfterMilliseconds)
            )
            guard !Task.isCancelled, let self else { return }
            self.isDirectInteractionActive = false
            if !self.isOverlayHovered && !self.isOverlayFocused {
                self.scheduleAutoCollapse()
            }
        }
    }

    /// Ends any interaction state that can be left stale when another app
    /// becomes active. The configured delay still controls the collapse.
    func endOverlayInteraction() {
        isOverlayHovered = false
        isOverlayFocused = false
        isDirectInteractionActive = false
        hoverExpansionTask?.cancel()
        hoverExpansionTask = nil
        interactionReleaseTask?.cancel()
        interactionReleaseTask = nil
        scheduleAutoCollapse()
        scheduleIdleAutoHide()
    }

    func cancelInteractionTimers() {
        hoverExpansionTask?.cancel()
        hoverExpansionTask = nil
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        idleAutoHideTask?.cancel()
        idleAutoHideTask = nil
        interactionReleaseTask?.cancel()
        interactionReleaseTask = nil
    }

    func setSoundEnabled(_ enabled: Bool, for event: CoveSoundEvent) {
        soundPreferences.setEnabled(enabled, for: event)
        if soundWritesEnabled {
            soundPreferencesStorage.save(enabled, for: event)
        }
    }

    func updateSoundPreferences(_ preferences: CoveSoundPreferences) {
        soundPreferences = preferences
        if soundWritesEnabled {
            soundPreferencesStorage.save(preferences)
        }
    }

    @discardableResult
    func importCustomTheme(from url: URL) throws -> CoveThemePalette {
        let theme = try themeStorage.importTheme(from: url)
        themePreview = nil
        upsertCustomTheme(theme)
        dispatch(.selectCustomTheme(theme))
        return theme
    }

    @discardableResult
    func saveCustomTheme(
        _ draft: CoveThemePalette,
        named rawName: String
    ) throws -> CoveThemePalette {
        var theme = configuredTheme(draft)
        themePreview = nil
        theme.name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if theme.isBuiltIn {
            theme.identifier = "custom.\(UUID().uuidString.lowercased())"
        }
        let saved = try themeStorage.importTheme(data: theme.document.encoded())
        upsertCustomTheme(saved)
        dispatch(.selectCustomTheme(saved))
        return saved
    }

    func exportTheme(_ theme: CoveThemePalette, to url: URL) throws {
        try themeStorage.exportTheme(configuredTheme(theme), to: url)
    }

    func removeCustomTheme(_ theme: CoveThemePalette) throws {
        guard !theme.isBuiltIn else { return }
        themePreview = nil
        try themeStorage.removeCustomTheme(identifier: theme.identifier)
        customThemes.removeAll { $0.identifier == theme.identifier }
        if state.settings.customThemeID == theme.identifier {
            dispatch(.clearCustomTheme)
        }
    }

    func selectCustomTheme(identifier: String?) {
        themePreview = nil
        guard let identifier else {
            dispatch(.clearCustomTheme)
            return
        }
        guard let theme = customThemes.first(where: {
            $0.identifier == identifier
        }) else {
            return
        }
        dispatch(.selectCustomTheme(theme))
    }

    private func upsertCustomTheme(_ theme: CoveThemePalette) {
        if let index = customThemes.firstIndex(where: {
            $0.identifier == theme.identifier
        }) {
            customThemes[index] = theme
        } else {
            customThemes.append(theme)
        }
        customThemes.sort {
            if $0.name == $1.name {
                return $0.identifier < $1.identifier
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private func configuredTheme(
        _ theme: CoveThemePalette
    ) -> CoveThemePalette {
        var theme = theme
        theme.collapsedOpacity = state.settings.collapsedOpacity
        theme.expandedOpacity = state.settings.expandedOpacity
        theme.blurStyle = state.settings.blurStyle
        return theme
    }

    func restore(metadata: [CoveSessionMetadata]) {
        dispatch(.restoreMetadata(metadata))
        reminders = Dictionary(
            uniqueKeysWithValues: metadata.compactMap { record in
                record.reminderAt.map { (record.sessionId, $0) }
            }
        )
    }

    func restorePinnedSessionIDs(_ sessionIDs: [String]) {
        dispatch(.restorePinnedSessionIDs(sessionIDs))
    }

    func togglePinned(_ snapshot: CoveSessionSnapshot) {
        let sessionID = snapshot.sessionId ?? snapshot.snapshotId
        let shouldPin = !state.pinnedSessionIDs.contains(sessionID)
        guard onSetPinned?(sessionID, shouldPin) != false else { return }
        dispatch(.togglePinned(sessionID))
    }

    func scheduleFollowUp(_ snapshot: CoveSessionSnapshot) {
        let sessionID = snapshot.sessionId ?? snapshot.snapshotId
        let reminderAt = Date().addingTimeInterval(
            state.settings.followUpReminderSeconds
        )
        guard onScheduleFollowUp?(sessionID, reminderAt) != false else { return }
        reminders[sessionID] = reminderAt
    }

    func cancelFollowUp(_ snapshot: CoveSessionSnapshot) {
        let sessionID = snapshot.sessionId ?? snapshot.snapshotId
        guard onCancelFollowUp?(sessionID) != false else { return }
        reminders.removeValue(forKey: sessionID)
    }

    func didDeliverFollowUp(sessionID: String) {
        reminders.removeValue(forKey: sessionID)
    }

    func forgetInternalSession(
        _ sessionID: String,
        source: CoveWireSource,
        hostID: String?
    ) {
        dispatch(
            .forgetInternalSession(
                sessionId: sessionID,
                source: source,
                hostId: hostID
            )
        )
        let stillRepresentsSession = state.session.snapshots.contains {
            $0.snapshotId == sessionID || $0.sessionId == sessionID
        } || state.pendingDirectRequests.contains {
            $0.sessionId == sessionID
        }
        if !stillRepresentsSession {
            reminders.removeValue(forKey: sessionID)
            if selectedSessionID == sessionID {
                selectedSessionID = nil
            }
        }
    }

    func selectAdjacentSession(offset: Int) {
        let sessions = state.session.snapshots
        guard !sessions.isEmpty else {
            selectedSessionID = nil
            return
        }
        let currentIndex = selectedSessionID.flatMap { selected in
            sessions.firstIndex {
                ($0.sessionId ?? $0.snapshotId) == selected
            }
        } ?? (offset >= 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + sessions.count) % sessions.count
        selectedSessionID = sessions[nextIndex].sessionId
            ?? sessions[nextIndex].snapshotId
    }

    func openSelectedSession() {
        guard let selectedSessionID,
              let snapshot = state.session.snapshots.first(where: {
                  ($0.sessionId ?? $0.snapshotId) == selectedSessionID
              })
        else { return }
        open(snapshot)
    }

    func refreshQuietEnvironment(
        at date: Date = Date(),
        focusedBundleIdentifier: String?
    ) {
        dispatch(
            .evaluateQuiet(
                date,
                focusedBundleIdentifier: focusedBundleIdentifier
            )
        )
    }

    func shouldSuppressAlerts(
        for envelope: CoveWireEnvelope,
        focusedBundleIdentifier: String?
    ) -> Bool {
        if state.privacyScene == .locked { return true }
        if CoveQuietPolicy.reason(
            settings: state.settings,
            at: Date(),
            focusedBundleIdentifier: focusedBundleIdentifier
        ) != nil {
            return true
        }
        let display = envelope.displayEvent()
        var candidates = [
            envelope.sessionId,
            envelope.launchId ?? "",
            display.title,
            display.body ?? "",
        ]
        if let snapshot = envelope.sessionSnapshot() {
            candidates.append(snapshot.title)
            candidates.append(snapshot.detail ?? "")
        }
        if let existing = state.session.snapshots.first(where: {
            $0.originScope == envelope.originScope
                && ($0.sessionId == envelope.sessionId
                    || ($0.launchId != nil && $0.launchId == envelope.launchId))
        }) {
            candidates.append(existing.title)
            candidates.append(existing.detail ?? "")
        }
        return CoveQuietPolicy.matchesSilencedProject(
            settings: state.settings,
            candidates: candidates
        )
    }

    func shouldSuppressAlerts(
        for snapshot: CoveSessionSnapshot?,
        focusedBundleIdentifier: String?
    ) -> Bool {
        if state.privacyScene == .locked { return true }
        if CoveQuietPolicy.reason(
            settings: state.settings,
            at: Date(),
            focusedBundleIdentifier: focusedBundleIdentifier
        ) != nil {
            return true
        }
        guard let snapshot else { return false }
        return CoveQuietPolicy.matchesSilencedProject(
            settings: state.settings,
            candidates: [
                snapshot.sessionId ?? snapshot.snapshotId,
                snapshot.title,
                snapshot.detail ?? "",
            ]
        )
    }

    func open(_ snapshot: CoveSessionSnapshot) {
        onJumpToSession?(snapshot)
        dispatch(.markRead(snapshot.snapshotId))
        onMarkRead?(snapshot.sessionId ?? snapshot.snapshotId)
    }

    func markRead(_ snapshot: CoveSessionSnapshot) {
        dispatch(.markRead(snapshot.snapshotId))
        onMarkRead?(snapshot.sessionId ?? snapshot.snapshotId)
    }

    func dismiss(_ snapshot: CoveSessionSnapshot) {
        let sessionID = snapshot.sessionId ?? snapshot.snapshotId
        guard onDismissSession?(sessionID) != false else { return }
        if state.pinnedSessionIDs.contains(sessionID) {
            _ = onSetPinned?(sessionID, false)
        }
        if reminders[sessionID] != nil {
            _ = onCancelFollowUp?(sessionID)
            reminders.removeValue(forKey: sessionID)
        }
        dispatch(.dismissSnapshot(snapshot.snapshotId))
    }

    var archivableCompletedCount: Int {
        archivableCompletedSessionIDs.count
    }

    func archiveAllCompleted() {
        let snapshots = archivableCompletedSnapshots
        let sessionIDs = Array(
            Set(snapshots.map { $0.sessionId ?? $0.snapshotId })
        ).sorted()
        guard !sessionIDs.isEmpty,
              onDismissSessions?(sessionIDs) != false
        else { return }

        for sessionID in sessionIDs {
            if state.pinnedSessionIDs.contains(sessionID) {
                _ = onSetPinned?(sessionID, false)
            }
            if reminders[sessionID] != nil {
                _ = onCancelFollowUp?(sessionID)
                reminders.removeValue(forKey: sessionID)
            }
        }
        dispatch(.dismissSnapshots(snapshots.map(\.snapshotId)))
    }

    private var archivableCompletedSessionIDs: Set<String> {
        Set(
            archivableCompletedSnapshots.map {
                $0.sessionId ?? $0.snapshotId
            }
        )
    }

    private var archivableCompletedSnapshots: [CoveSessionSnapshot] {
        let pendingSessionIDs = Set(
            state.pendingDirectRequests.map(\.sessionId)
        )
        let snapshotsBySession = Dictionary(
            grouping: state.session.snapshots,
            by: { $0.sessionId ?? $0.snapshotId }
        )
        let safeSessionIDs = Set<String>(
            snapshotsBySession.compactMap { sessionID, snapshots in
                guard !pendingSessionIDs.contains(sessionID),
                      snapshots.allSatisfy({ $0.status == .completed })
                else { return nil }
                return sessionID
            }
        )
        return state.session.snapshots.filter { snapshot in
            snapshot.status == .completed
                && safeSessionIDs.contains(
                    snapshot.sessionId ?? snapshot.snapshotId
                )
        }
    }

    func actionDraft(for key: CoveDirectRequestKey) -> CoveActionDraft? {
        actionDrafts[key]
    }

    func approvalDraft(for key: CoveDirectRequestKey) -> CoveApprovalDraft? {
        actionDrafts.approval(for: key)
    }

    func questionDraft(for key: CoveDirectRequestKey) -> CoveQuestionDraft? {
        actionDrafts.question(for: key)
    }

    func isActionDirty(_ key: CoveDirectRequestKey) -> Bool {
        actionDrafts.isDirty(key)
    }

    @discardableResult
    func selectApprovalChoice(
        _ choice: CoveChoice,
        for approval: CoveApprovalRequest
    ) -> Bool {
        let request = CoveDirectRequest.approval(approval)
        let requestKey = request.key
        guard state.pendingDirectRequests.contains(request),
              decisionDelivery.canBeginSending(requestKey)
        else { return false }
        guard let decision = approvalDecision(for: choice) else {
            decisionDelivery.setFailed(
                requestKey,
                message: "This response is not supported in Cove. Answer in Codex instead."
            )
            return false
        }

        switch decision {
        case .accept, .acceptForSession:
            actionDrafts.setApproval(
                CoveApprovalDraft(choice: choice, decision: decision),
                for: requestKey
            )
            decisionDelivery.setStaged(requestKey)
            didChangeDraft()
        case .decline, .cancel:
            actionDrafts.clear(requestKey)
            return send(
                CoveDecisionFrame(
                    launchId: approval.launchId,
                    requestId: approval.requestId,
                    result: .approval(decision: decision)
                ),
                for: request
            )
        }
        return true
    }

    @discardableResult
    func confirmApproval(for approval: CoveApprovalRequest) -> Bool {
        let request = CoveDirectRequest.approval(approval)
        let requestKey = request.key
        guard state.pendingDirectRequests.contains(request),
              let draft = actionDrafts.approval(for: requestKey),
              draft.requiresConfirmation,
              decisionDelivery.canBeginSending(requestKey)
        else {
            if !decisionDelivery.isSending(requestKey)
                && !decisionDelivery.isSucceeded(requestKey) {
                decisionDelivery.setFailed(
                    requestKey,
                    message: "Choose an approval scope before confirming."
                )
            }
            return false
        }
        return send(
            CoveDecisionFrame(
                launchId: approval.launchId,
                requestId: approval.requestId,
                result: .approval(decision: draft.decision)
            ),
            for: request
        )
    }

    @discardableResult
    func confirmApproval(for requestKey: CoveDirectRequestKey) -> Bool {
        guard let request = state.pendingDirectRequests.first(where: {
            $0.key == requestKey
        }), case let .approval(approval) = request else { return false }
        return confirmApproval(for: approval)
    }

    @discardableResult
    func setQuestionDraftAnswers(
        _ answers: [String: [String]],
        for question: CoveQuestionRequest
    ) -> Bool {
        let request = CoveDirectRequest.question(question)
        guard state.pendingDirectRequests.contains(request),
              decisionDelivery.canBeginSending(request.key)
        else { return false }
        actionDrafts.setQuestionAnswers(answers, for: request.key)
        synchronizeStagedDelivery(for: request.key)
        didChangeDraft()
        return true
    }

    @discardableResult
    func setQuestionDraftAnswer(
        _ answer: String,
        questionID: String,
        for question: CoveQuestionRequest
    ) -> Bool {
        setQuestionDraftAnswers(
            merging: [answer],
            questionID: questionID,
            for: question
        )
    }

    @discardableResult
    func setQuestionDraftAnswers(
        merging answers: [String],
        questionID: String,
        for question: CoveQuestionRequest
    ) -> Bool {
        let request = CoveDirectRequest.question(question)
        guard state.pendingDirectRequests.contains(request),
              question.questions.contains(where: {
                  $0.questionId == questionID
              }),
              decisionDelivery.canBeginSending(request.key)
        else { return false }
        actionDrafts.setQuestionAnswer(
            answers,
            questionID: questionID,
            for: request.key
        )
        synchronizeStagedDelivery(for: request.key)
        didChangeDraft()
        return true
    }

    @discardableResult
    func confirmQuestionDraft(for question: CoveQuestionRequest) -> Bool {
        let requestKey = CoveDirectRequest.question(question).key
        guard let draft = actionDrafts.question(for: requestKey),
              draft.isDirty,
              decisionDelivery.canBeginSending(requestKey)
        else {
            if !decisionDelivery.isSending(requestKey)
                && !decisionDelivery.isSucceeded(requestKey) {
                decisionDelivery.setFailed(
                    requestKey,
                    message: "Answer every question before sending."
                )
            }
            return false
        }
        return respond(to: question, answers: draft.answers)
    }

    func discardDraft(for requestKey: CoveDirectRequestKey) {
        actionDrafts.clear(requestKey)
        decisionDelivery.clearStaged(requestKey)
        if !isOverlayHovered && !isOverlayFocused {
            scheduleAutoCollapse()
            scheduleIdleAutoHide()
        }
    }

    @discardableResult
    func retryDecision(for requestKey: CoveDirectRequestKey) -> Bool {
        guard let attempt = decisionDelivery.retryAttempt(for: requestKey),
              state.pendingDirectRequests.contains(attempt.request),
              decisionDelivery.canBeginSending(requestKey)
        else { return false }
        return send(attempt.renewed())
    }

    func respond(to request: CoveDirectRequest, with choice: CoveChoice) {
        switch request {
        case let .approval(approval):
            _ = selectApprovalChoice(choice, for: approval)
        case let .question(question):
            guard question.questions.count == 1 else {
                decisionDelivery.setFailed(
                    request.key,
                    message: "Answer every question before sending."
                )
                return
            }
            let answer = questionAnswer(for: choice)
            respond(
                to: question,
                answers: [question.questionId: [answer]]
            )
        case let .planSnapshot(plan):
            openInCodex(for: .planSnapshot(plan))
        }
    }

    func respondFreeform(_ answer: String, to request: CoveQuestionRequest) {
        let requestKey = CoveDirectRequest.question(request).key
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            decisionDelivery.setFailed(
                requestKey,
                message: "Enter an answer before sending."
            )
            return
        }
        guard request.questions.count == 1 else {
            decisionDelivery.setFailed(
                requestKey,
                message: "Answer every question before sending."
            )
            return
        }
        respond(
            to: request,
            answers: [request.questionId: [answer]]
        )
    }

    @discardableResult
    func respond(
        to request: CoveQuestionRequest,
        answers suppliedAnswers: [String: [String]]
    ) -> Bool {
        let requestKey = CoveDirectRequest.question(request).key
        let questionIDs = request.questions.map(\.questionId)
        let expectedIDs = Set(questionIDs)
        guard !questionIDs.isEmpty,
              expectedIDs.count == questionIDs.count,
              Set(suppliedAnswers.keys) == expectedIDs
        else {
            decisionDelivery.setFailed(
                requestKey,
                message: "Answer every question once before sending."
            )
            return false
        }

        var encodedAnswers: [String: CoveQuestionAnswer] = [:]
        for question in request.questions {
            guard let answers = suppliedAnswers[question.questionId],
                  !answers.isEmpty,
                  answers.allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            else {
                decisionDelivery.setFailed(
                    requestKey,
                    message: "Answer every question before sending."
                )
                return false
            }

            if !question.allowsFreeform {
                let advertisedAnswers = Set(question.options.map(questionAnswer(for:)))
                guard !advertisedAnswers.isEmpty,
                      answers.allSatisfy(advertisedAnswers.contains)
                else {
                    decisionDelivery.setFailed(
                        requestKey,
                        message: "Choose one of the supplied options for every question."
                    )
                    return false
                }
            }
            encodedAnswers[question.questionId] = CoveQuestionAnswer(answers: answers)
        }

        return send(
            CoveDecisionFrame(
                launchId: request.launchId,
                requestId: request.requestId,
                result: .question(answers: encodedAnswers)
            ),
            for: .question(request)
        )
    }

    @discardableResult
    func openInCodex(for request: CoveDirectRequest) -> Bool {
        guard let snapshot = exactOriginSnapshot(for: request) else {
            setOpenFailure(
                request.key,
                message: "The exact originating Codex location is not currently available."
            )
            return false
        }

        let result: CoveJumpResult
        if let onOpenDirectRequest {
            result = onOpenDirectRequest(snapshot)
        } else if snapshot.source == .codexDesktop {
            result = openDesktopThread(
                sessionId: request.sessionId
            )
        } else {
            result = CoveJumpResult(
                focusedExactLocation: false,
                message: "The exact originating Codex location is not currently available."
            )
        }
        guard result.focusedExactLocation else {
            setOpenFailure(
                request.key,
                message: result.message
            )
            return false
        }
        return true
    }

    func flush() {
        guard persistenceWritesEnabled else {
            return
        }
        guard state.settings != lastPersistedSettings else {
            return
        }
        do {
            try storage.save(state)
            lastPersistedSettings = state.settings
        } catch {
            NSLog("CoveStore save failed: \(error)")
        }
    }

    @discardableResult
    private func send(
        _ frame: CoveDecisionFrame,
        for request: CoveDirectRequest
    ) -> Bool {
        let requestKey = request.key
        guard state.pendingDirectRequests.first(where: {
            $0.key == requestKey
        }) == request else {
            decisionDelivery.setFailed(
                requestKey,
                message: "This request is no longer pending."
            )
            return false
        }
        guard let socketPath = request.decisionSocket, !socketPath.isEmpty else {
            openInCodex(for: request)
            return false
        }
        guard decisionDelivery.canBeginSending(requestKey) else {
            return false
        }

        return send(
            CoveDecisionAttempt(
                request: request,
                frame: frame,
                socketPath: socketPath
            )
        )
    }

    @discardableResult
    private func send(_ attempt: CoveDecisionAttempt) -> Bool {
        let requestKey = attempt.requestKey
        guard state.pendingDirectRequests.contains(attempt.request) else {
            decisionDelivery.setFailed(
                requestKey,
                message: "This request is no longer pending."
            )
            return false
        }
        guard decisionDelivery.canBeginSending(requestKey) else {
            return false
        }

        decisionDelivery.setSending(attempt)
        decisionAttemptCount += 1
        onDecisionAttempt?(attempt)
        let sender = decisionSender
        let successFeedbackDuration = decisionSuccessFeedbackDuration
        decisionTasks[requestKey]?.cancel()
        decisionTasks[requestKey] = Task { [weak self] in
            do {
                try await sender.send(attempt.frame, to: attempt.socketPath)
                guard !Task.isCancelled,
                      let self,
                      self.state.pendingDirectRequests.contains(attempt.request),
                      self.decisionDelivery.isSending(
                          requestKey,
                          attemptID: attempt.attemptID
                      )
                else { return }
                self.decisionDelivery.setSucceeded(
                    requestKey,
                    attemptID: attempt.attemptID
                )
                self.actionDrafts.clear(requestKey)
                if self.pendingDirtyExitConfirmation?.requestKey == requestKey {
                    self.pendingDirtyExitConfirmation = nil
                }
                try? await Task.sleep(for: successFeedbackDuration)
                guard !Task.isCancelled,
                      self.state.pendingDirectRequests.contains(attempt.request),
                      self.decisionDelivery.isSucceeded(requestKey)
                else { return }
                self.dispatch(.resolveDirectRequest(requestKey))
            } catch {
                guard let self,
                      self.state.pendingDirectRequests.contains(attempt.request),
                      self.decisionDelivery.isSending(
                          requestKey,
                          attemptID: attempt.attemptID
                      )
                else {
                    return
                }
                let message = (error as? CoveDecisionSocketError)?.errorDescription
                    ?? "The response could not be sent. Answer in Codex instead."
                self.decisionDelivery.setFailed(attempt, message: message)
            }
        }
        return true
    }

    private func approvalDecision(for choice: CoveChoice) -> CoveApprovalDecision? {
        let rawDecision = choice.raw?.objectValue?["decision"]?.stringValue
        let identifier = rawDecision ?? choice.identifier
        if let decision = CoveApprovalDecision(rawValue: identifier) {
            return decision
        }

        // Older Cove event producers used "deny" for Codex's "decline"
        // response. Treat it as the protocol value without exposing a fifth
        // decision to the UI.
        if identifier == "deny" {
            return .decline
        }
        return nil
    }

    private func questionAnswer(for choice: CoveChoice) -> String {
        let raw = choice.raw?.objectValue
        return raw?["value"]?.stringValue
            ?? raw?["label"]?.stringValue
            ?? choice.label
    }

    private func openDesktopThread(sessionId: String) -> CoveJumpResult {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(sessionId)"
        guard !sessionId.isEmpty,
              let url = components.url,
              openExternalURL(url)
        else {
            return CoveJumpResult(
                focusedExactLocation: false,
                message: "Codex could not be opened for this Desktop request."
            )
        }
        return CoveJumpResult(
            focusedExactLocation: true,
            message: "Opened the exact Codex Desktop task."
        )
    }

    private func exactOriginSnapshot(
        for request: CoveDirectRequest
    ) -> CoveSessionSnapshot? {
        guard let origin = CoveOriginScope(
            source: request.source,
            hostId: request.hostId
        ) else {
            return nil
        }
        let candidates = state.session.snapshots.filter { snapshot in
            guard snapshot.sessionId == request.sessionId,
                  snapshot.originScope == origin else {
                return false
            }
            if let launchID = request.launchId {
                return snapshot.launchId == launchID
            }
            return true
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func setOpenFailure(
        _ requestKey: CoveDirectRequestKey,
        message: String
    ) {
        decisionDelivery.setFailed(
            requestKey,
            message: message,
            retry: decisionDelivery.retryAttempt(for: requestKey)
        )
    }

    private var focusedDirectRequestKey: CoveDirectRequestKey? {
        guard case let .focused(.directRequest(requestKey)) = overlayPresentation
        else { return nil }
        return requestKey
    }

    private var focusedDirtyRequestKey: CoveDirectRequestKey? {
        guard let requestKey = focusedDirectRequestKey,
              actionDrafts.isDirty(requestKey)
        else { return nil }
        return requestKey
    }

    private func actionRequestsCollapse(_ action: CoveAction) -> Bool {
        switch action {
        case let .setExpanded(expanded):
            return !expanded
        case .toggleExpanded:
            return state.session.isExpanded
        default:
            return false
        }
    }

    private func actionRequestsExpansion(_ action: CoveAction) -> Bool {
        switch action {
        case let .setExpanded(expanded):
            expanded
        case .toggleExpanded:
            !state.session.isExpanded
        default:
            false
        }
    }

    private func applyOverlayPresentation(
        _ presentation: CoveOverlayPresentation
    ) {
        let presentation = isSettingsPresented
            ? CoveOverlayPresentation.collapsed
            : presentation
        overlayPresentation = presentation
        let shouldExpand = presentation.isExpanded
        if state.session.isExpanded != shouldExpand {
            dispatch(.setExpanded(shouldExpand))
        }
    }

    private func reconcileOverlayPresentation(
        requestKeys: Set<CoveDirectRequestKey>
    ) {
        guard state.session.isExpanded else {
            overlayPresentation = .collapsed
            return
        }
        switch overlayPresentation {
        case .collapsed:
            overlayPresentation = .queue
        case .queue:
            break
        case let .focused(.directRequest(requestKey)):
            if !requestKeys.contains(requestKey) {
                overlayPresentation = .queue
            }
        case let .focused(.session(sessionID)):
            if !state.session.snapshots.contains(where: {
                ($0.sessionId ?? $0.snapshotId) == sessionID
            }) {
                overlayPresentation = .queue
            }
        }
    }

    private func synchronizeStagedDelivery(
        for requestKey: CoveDirectRequestKey
    ) {
        if actionDrafts.isDirty(requestKey) {
            decisionDelivery.setStaged(requestKey)
        } else {
            decisionDelivery.clearStaged(requestKey)
        }
    }

    private func didChangeDraft() {
        if actionDrafts.hasDirtyDrafts {
            autoCollapseTask?.cancel()
            autoCollapseTask = nil
            idleAutoHideTask?.cancel()
            idleAutoHideTask = nil
        } else if !isOverlayHovered && !isOverlayFocused {
            scheduleAutoCollapse()
            scheduleIdleAutoHide()
        }
    }

    private func scheduleAutoCollapse() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        guard state.session.isExpanded,
              !isOverlayHovered,
              !isOverlayFocused,
              !isDirectInteractionActive,
              !actionDrafts.hasDirtyDrafts,
              state.settings.autoCollapseSeconds > 0
        else {
            return
        }
        autoCollapseTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(
                    self?.state.settings.autoCollapseSeconds ?? 6
                )
            )
            guard !Task.isCancelled,
                  let self,
                  !self.isOverlayHovered,
                  !self.isOverlayFocused,
                  !self.isDirectInteractionActive,
                  !self.actionDrafts.hasDirtyDrafts
            else {
                return
            }
            self.dispatch(.setExpanded(false))
        }
    }

    private func scheduleIdleAutoHide() {
        idleAutoHideTask?.cancel()
        idleAutoHideTask = nil
        let delay = state.settings.idleAutoHideSeconds
        guard delay > 0,
              state.session.isVisible,
              !state.settings.minimalIslandMode,
              state.pendingDirectRequests.isEmpty,
              !isOverlayHovered,
              !isOverlayFocused,
              !isDirectInteractionActive,
              !actionDrafts.hasDirtyDrafts,
              !state.session.snapshots.contains(where: {
                  [
                      .working,
                      .active,
                      .waitingApproval,
                      .waitingInput,
                      .blocked,
                      .compacting,
                  ].contains($0.status)
              })
        else { return }
        idleAutoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  !self.isOverlayHovered,
                  !self.isOverlayFocused,
                  !self.isDirectInteractionActive,
                  !self.actionDrafts.hasDirtyDrafts,
                  !self.state.settings.minimalIslandMode,
                  self.state.pendingDirectRequests.isEmpty,
                  !self.state.session.snapshots.contains(where: {
                      [.waitingApproval, .waitingInput, .blocked].contains(
                          $0.status
                      )
                  })
            else { return }
            self.dispatch(.setMinimalIslandMode(true))
        }
    }

    private func normalizeSelectedSession() {
        guard let selectedSessionID else { return }
        if !state.session.snapshots.contains(where: {
            ($0.sessionId ?? $0.snapshotId) == selectedSessionID
        }) {
            self.selectedSessionID = nil
        }
    }
}
