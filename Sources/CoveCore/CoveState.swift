import Foundation

public enum CoveSessionStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case listening
    case active
    case blocked
    case quiet
    case hidden
    case working
    case waitingApproval
    case waitingInput
    case compacting
    case completed
    case failed
    case interrupted
}

public extension CoveSessionStatus {
    /// States that should become unread when they are first observed or change.
    var requiresUnreadAcknowledgement: Bool {
        switch self {
        case .waitingApproval, .waitingInput, .blocked, .completed, .failed,
             .interrupted:
            true
        case .idle, .listening, .active, .quiet, .hidden, .working,
             .compacting:
            false
        }
    }
}

public enum CovePrivacyScene: String, Codable, CaseIterable, Sendable {
    case normal
    case redacted
    case locked

    public func resolvingCapturePrivacy(
        isCapturePrivacyActive: Bool,
        allowLockedExit: Bool = false
    ) -> CovePrivacyScene {
        if self == .locked && !allowLockedExit {
            return .locked
        }
        return isCapturePrivacyActive ? .redacted : .normal
    }
}

public struct CoveQuietHours: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var startMinute: Int
    public var endMinute: Int

    public init(
        enabled: Bool = false,
        startMinute: Int = 22 * 60,
        endMinute: Int = 7 * 60
    ) {
        self.enabled = enabled
        self.startMinute = min(1_439, max(0, startMinute))
        self.endMinute = min(1_439, max(0, endMinute))
    }

    public func contains(
        _ date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard enabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinute == endMinute { return true }
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, startMinute, endMinute
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled)
                ?? false,
            startMinute: try values.decodeIfPresent(Int.self, forKey: .startMinute)
                ?? 22 * 60,
            endMinute: try values.decodeIfPresent(Int.self, forKey: .endMinute)
                ?? 7 * 60
        )
    }
}

public enum CoveQuietReason: String, Codable, Equatable, Sendable {
    case quietHours
    case focusedApp
}

public enum CoveQuietPolicy {
    public static func reason(
        settings: CoveSettings,
        at date: Date,
        focusedBundleIdentifier: String?,
        calendar: Calendar = .current
    ) -> CoveQuietReason? {
        if settings.quietHours.contains(date, calendar: calendar) {
            return .quietHours
        }
        if settings.followFocusedApp,
           let focusedBundleIdentifier,
           !focusedBundleIdentifier.isEmpty,
           focusedBundleIdentifier != "local.chris.codexcove"
        {
            return .focusedApp
        }
        return nil
    }

    public static func matchesSilencedProject(
        settings: CoveSettings,
        candidates: [String]
    ) -> Bool {
        let normalizedCandidates = candidates.map {
            $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }
        return settings.silencedProjectRules.contains { rawRule in
            let rule = rawRule
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
            return !rule.isEmpty
                && normalizedCandidates.contains { $0.contains(rule) }
        }
    }
}

public enum CoveFollowUpReminderPolicy {
    public static func isDue(reminderAt: Date?, now: Date) -> Bool {
        guard let reminderAt else { return false }
        return reminderAt <= now
    }
}

public enum CoveOverlayGeometry {
    public static let expandedHeight = 520.0
    public static let cueGutterWidth = 30.0
    public static let collapsedDepthRatio = 0.14
    public static let minimumCollapsedDepth = 28.0
    public static let maximumCollapsedDepth = 60.0
    public static let defaultTopContentInset = 32.0

    public static var collapsedHeight: Double {
        collapsedHeight(
            forWidth: CoveSettings.defaultCollapsedWidth,
            topContentInset: defaultTopContentInset
        )
    }

    public static func collapsedDepth(forWidth width: Double) -> Double {
        let proportionalDepth = max(0, width) * collapsedDepthRatio
        return min(
            maximumCollapsedDepth,
            max(minimumCollapsedDepth, proportionalDepth)
        )
    }

    public static func collapsedHeight(
        forWidth width: Double,
        topContentInset: Double
    ) -> Double {
        max(0, topContentInset) + collapsedDepth(forWidth: width)
    }

    public static func topGap(expanded: Bool) -> Double {
        0
    }

    public static func size(
        expanded: Bool,
        privacyMode: CovePrivacyMode,
        minimalIslandMode: Bool,
        collapsedWidth: Double = CoveSettings.defaultCollapsedWidth,
        topContentInset: Double = defaultTopContentInset
    ) -> (width: Double, height: Double) {
        if minimalIslandMode {
            return (126, max(24, topContentInset))
        }
        if expanded {
            return (
                CoveSettings.validatedCollapsedWidth(collapsedWidth),
                expandedHeight
            )
        }
        let width = CoveSettings.validatedCollapsedWidth(collapsedWidth)
        return (width, collapsedHeight(
            forWidth: width,
            topContentInset: topContentInset
        ))
    }

    public static func resolvedWidth(
        screen: CoveScreenMetrics,
        desiredWidth: Double
    ) -> Double {
        let notchSafeWidth = screen.topObstructionWidth > 0
            ? screen.topObstructionWidth + cueGutterWidth * 2
            : 0
        return min(
            max(desiredWidth, notchSafeWidth),
            screen.availableTopWidth
        )
    }

    public static func layout(
        screen: CoveScreenMetrics,
        desiredWidth: Double,
        desiredHeight: Double,
        expanded: Bool
    ) -> CoveNotchLayout {
        let width = resolvedWidth(
            screen: screen,
            desiredWidth: desiredWidth
        )
        let originX = max(
            screen.safeAreaLeft,
            screen.safeAreaLeft + (screen.availableTopWidth - width) / 2
        )
        return CoveNotchLayout(
            originX: originX,
            originY: max(0, screen.screenHeight - desiredHeight),
            width: width,
            height: desiredHeight,
            insetFromTop: 0
        )
    }
}

public enum CoveSessionVisualCuePolicy {
    public static func visibleSnapshots(
        in snapshots: [CoveSessionSnapshot]
    ) -> [CoveSessionSnapshot] {
        snapshots.filter { snapshot in
            switch snapshot.status {
            case .working, .active, .compacting,
                 .waitingApproval, .waitingInput, .blocked:
                return true
            case .completed, .failed, .interrupted:
                return snapshot.unread
            case .idle, .listening, .quiet, .hidden:
                return false
            }
        }
    }

    public static func distinctVisibleStatuses(
        in snapshots: [CoveSessionSnapshot]
    ) -> [CoveSessionStatus] {
        var seen = Set<CoveSessionStatus>()
        return visibleSnapshots(in: snapshots).compactMap { snapshot in
            seen.insert(snapshot.status).inserted ? snapshot.status : nil
        }
    }
}

public struct CoveSessionTokenMetrics: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var totalTokens: Int?
    public var contextWindow: Int?
    public var capturedAt: Date

    public init(
        inputTokens: Int?,
        cachedInputTokens: Int?,
        outputTokens: Int?,
        reasoningOutputTokens: Int?,
        totalTokens: Int?,
        contextWindow: Int?,
        capturedAt: Date
    ) {
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.cachedInputTokens = cachedInputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
        self.reasoningOutputTokens = reasoningOutputTokens.map { max(0, $0) }
        self.totalTokens = totalTokens.map { max(0, $0) }
        self.contextWindow = contextWindow.map { max(0, $0) }
        self.capturedAt = capturedAt
    }

    public func isStale(
        at date: Date = Date(),
        after interval: TimeInterval = 5 * 60
    ) -> Bool {
        date.timeIntervalSince(capturedAt) > interval
    }
}

public struct CoveSessionSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var snapshotId: String
    public var status: CoveSessionStatus
    public var priority: Int
    public var title: String
    public var detail: String?
    public var latestOutput: String?
    public var timestamp: Date
    public var sessionId: String?
    public var launchId: String?
    public var source: CoveWireSource?
    public var hostId: String?
    public var parentSessionId: String?
    /// `true` means the event made conflicting parent claims; never inherit a
    /// previous relationship in that case.
    public var parentProvenanceConflict: Bool?
    /// Public app-server/broker liveness, kept separate from turn status.
    /// Nil denotes a legacy event that did not advertise liveness.
    public var liveness: CoveSessionLiveness?
    /// Exact active turn required by `turn/steer`; never inferred.
    public var activeTurnId: String?
    /// The currently authoritative route for bounded prompt control.
    public var controlRoute: CoveThreadControlRoute?
    public var unread: Bool

    public init(
        schemaVersion: Int = 1,
        snapshotId: String,
        status: CoveSessionStatus,
        priority: Int,
        title: String,
        detail: String? = nil,
        latestOutput: String? = nil,
        timestamp: Date,
        sessionId: String? = nil,
        launchId: String? = nil,
        source: CoveWireSource? = nil,
        hostId: String? = nil,
        parentSessionId: String? = nil,
        parentProvenanceConflict: Bool? = nil,
        liveness: CoveSessionLiveness? = nil,
        activeTurnId: String? = nil,
        controlRoute: CoveThreadControlRoute? = nil,
        unread: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotId = snapshotId
        self.status = status
        self.priority = priority
        self.title = title
        self.detail = detail
        self.latestOutput = latestOutput
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.launchId = launchId
        self.source = source
        self.hostId = hostId
        self.parentSessionId = parentSessionId
        self.parentProvenanceConflict = parentProvenanceConflict
        self.liveness = liveness
        self.activeTurnId = activeTurnId
        self.controlRoute = controlRoute
        self.unread = unread
    }
}

public struct CoveSessionState: Codable, Equatable, Sendable {
    public var isExpanded: Bool
    public var isDocked: Bool
    public var isVisible: Bool
    public var isListening: Bool
    public var activeStatus: CoveSessionStatus
    public var statusPriority: Int
    public var activeSnapshot: CoveSessionSnapshot?
    public var snapshots: [CoveSessionSnapshot]
    public var lastEnvelope: CoveWireEnvelope?

    public init(
        isExpanded: Bool = false,
        isDocked: Bool = false,
        isVisible: Bool = true,
        isListening: Bool = false,
        activeStatus: CoveSessionStatus = .idle,
        statusPriority: Int = 0,
        activeSnapshot: CoveSessionSnapshot? = nil,
        snapshots: [CoveSessionSnapshot] = [],
        lastEnvelope: CoveWireEnvelope? = nil
    ) {
        self.isExpanded = isExpanded
        self.isDocked = isDocked
        self.isVisible = isVisible
        self.isListening = isListening
        self.activeStatus = activeStatus
        self.statusPriority = statusPriority
        self.activeSnapshot = activeSnapshot
        self.snapshots = snapshots
        self.lastEnvelope = lastEnvelope
    }
}

public struct CoveSettings: Codable, Equatable, Sendable {
    public static let collapsedWidthRange: ClosedRange<Double> = 210 ... 420
    public static let defaultCollapsedWidth = 260.0
    public static let textScaleRange: ClosedRange<Double> = 1 ... 2
    public static let defaultTextScale = 1.0

    public static func validatedCollapsedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultCollapsedWidth }
        return min(collapsedWidthRange.upperBound, max(collapsedWidthRange.lowerBound, value))
    }

    public static func validatedTextScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTextScale }
        return min(textScaleRange.upperBound, max(textScaleRange.lowerBound, value))
    }

    public static func validatedQueueSectionOrder(
        _ value: [CoveQueueSection]
    ) -> [CoveQueueSection] {
        var seen = Set<CoveQueueSection>()
        let unique = value.filter { seen.insert($0).inserted }
        return unique + CoveQueueSection.allCases.filter { !seen.contains($0) }
    }

    public var themeFamily: CoveThemeFamily
    public var palette: CovePaletteKind
    public var opacityStyle: CoveOpacityStyle
    public var blurStyle: CoveBlurStyle
    public var textScale: Double
    public var privacyMode: CovePrivacyMode
    public var launchAtLogin: Bool
    public var showNotifications: Bool
    public var notificationPreferences: CoveNotificationPreferences
    public var playSounds: Bool
    public var globalShortcutsEnabled: Bool
    public var autoExpandOnEvent: Bool
    public var collapsedOpacity: Double
    public var expandedOpacity: Double
    public var usageShowsRemaining: Bool
    public var conservativeCapturePrivacy: Bool
    public var customThemeID: String?
    public var residentSet: CoveResidentSet
    public var quietHours: CoveQuietHours
    public var silencedProjectRules: [String]
    public var followFocusedApp: Bool
    public var glanceMode: Bool
    public var hoverDelaySeconds: Double
    public var autoCollapseSeconds: Double
    public var collapsedWidth: Double
    public var squareTopCorners: Bool
    public var panelAnimationEnabled: Bool
    public var panelAnimationDuration: Double
    public var idleAutoHideSeconds: Double
    public var followUpReminderSeconds: Double
    public var minimalIslandMode: Bool
    public var showUsage: Bool
    public var showProfileTokenUsage: Bool
    public var showTokenMetrics: Bool
    public var queueSectionOrder: [CoveQueueSection]
    public var collapsedQueueSections: Set<CoveQueueSection>
    public var workspaceAppearance: CoveWorkspaceAppearance

    public init(
        themeFamily: CoveThemeFamily = .nativeGlass,
        palette: CovePaletteKind = .graphite,
        opacityStyle: CoveOpacityStyle = .balanced,
        blurStyle: CoveBlurStyle = .regular,
        textScale: Double = CoveSettings.defaultTextScale,
        privacyMode: CovePrivacyMode = .auto,
        launchAtLogin: Bool = false,
        showNotifications: Bool = true,
        notificationPreferences: CoveNotificationPreferences = .init(),
        playSounds: Bool = true,
        globalShortcutsEnabled: Bool = true,
        autoExpandOnEvent: Bool = true,
        collapsedOpacity: Double = 0.72,
        expandedOpacity: Double = 0.88,
        usageShowsRemaining: Bool = false,
        conservativeCapturePrivacy: Bool = false,
        customThemeID: String? = nil,
        residentSet: CoveResidentSet = .dungeonAndDragons,
        quietHours: CoveQuietHours = .init(),
        silencedProjectRules: [String] = [],
        followFocusedApp: Bool = false,
        glanceMode: Bool = false,
        hoverDelaySeconds: Double = 0.25,
        autoCollapseSeconds: Double = 6,
        collapsedWidth: Double = CoveSettings.defaultCollapsedWidth,
        squareTopCorners: Bool = true,
        panelAnimationEnabled: Bool = true,
        panelAnimationDuration: Double = 0.24,
        idleAutoHideSeconds: Double = 0,
        followUpReminderSeconds: Double = 10 * 60,
        minimalIslandMode: Bool = false,
        showUsage: Bool = true,
        showProfileTokenUsage: Bool = false,
        showTokenMetrics: Bool = false,
        queueSectionOrder: [CoveQueueSection] = CoveQueueSection.allCases,
        collapsedQueueSections: Set<CoveQueueSection> = [.more],
        workspaceAppearance: CoveWorkspaceAppearance = .system
    ) {
        self.themeFamily = themeFamily
        self.palette = palette
        self.opacityStyle = opacityStyle
        self.blurStyle = blurStyle
        self.textScale = Self.validatedTextScale(textScale)
        self.privacyMode = privacyMode
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
        self.notificationPreferences = notificationPreferences
        self.playSounds = playSounds
        self.globalShortcutsEnabled = globalShortcutsEnabled
        self.autoExpandOnEvent = autoExpandOnEvent
        self.collapsedOpacity = min(1, max(0.35, collapsedOpacity))
        self.expandedOpacity = min(1, max(0.35, expandedOpacity))
        self.usageShowsRemaining = usageShowsRemaining
        self.conservativeCapturePrivacy = conservativeCapturePrivacy
        self.customThemeID = customThemeID
        self.residentSet = residentSet
        self.quietHours = quietHours
        self.silencedProjectRules = CoveSilencedProjectRules.normalize(
            silencedProjectRules
        )
        self.followFocusedApp = followFocusedApp
        self.glanceMode = glanceMode
        self.hoverDelaySeconds = min(3, max(0, hoverDelaySeconds))
        self.autoCollapseSeconds = min(30, max(1, autoCollapseSeconds))
        self.collapsedWidth = Self.validatedCollapsedWidth(collapsedWidth)
        self.squareTopCorners = squareTopCorners
        self.panelAnimationEnabled = panelAnimationEnabled
        self.panelAnimationDuration = min(0.8, max(0.08, panelAnimationDuration))
        self.idleAutoHideSeconds = min(3_600, max(0, idleAutoHideSeconds))
        self.followUpReminderSeconds = min(
            24 * 60 * 60,
            max(60, followUpReminderSeconds)
        )
        self.minimalIslandMode = minimalIslandMode
        self.showUsage = showUsage
        self.showProfileTokenUsage = showProfileTokenUsage
        self.showTokenMetrics = showTokenMetrics
        self.queueSectionOrder = Self.validatedQueueSectionOrder(
            queueSectionOrder
        )
        self.collapsedQueueSections = collapsedQueueSections
        self.workspaceAppearance = workspaceAppearance
    }

    private enum CodingKeys: String, CodingKey {
        case themeFamily, palette, opacityStyle, blurStyle, textScale, privacyMode
        case launchAtLogin, showNotifications, notificationPreferences, playSounds
        case globalShortcutsEnabled, autoExpandOnEvent
        case collapsedOpacity, expandedOpacity, usageShowsRemaining
        case conservativeCapturePrivacy, customThemeID, residentSet
        case quietHours, silencedProjectRules, followFocusedApp, glanceMode
        case hoverDelaySeconds, autoCollapseSeconds, collapsedWidth, squareTopCorners
        case panelAnimationEnabled, panelAnimationDuration, idleAutoHideSeconds
        case followUpReminderSeconds
        case minimalIslandMode
        case showUsage, showProfileTokenUsage, showTokenMetrics
        case queueSectionOrder, collapsedQueueSections
        case workspaceAppearance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            themeFamily: try values.decodeIfPresent(CoveThemeFamily.self, forKey: .themeFamily) ?? .nativeGlass,
            palette: try values.decodeIfPresent(CovePaletteKind.self, forKey: .palette) ?? .graphite,
            opacityStyle: try values.decodeIfPresent(CoveOpacityStyle.self, forKey: .opacityStyle) ?? .balanced,
            blurStyle: try values.decodeIfPresent(CoveBlurStyle.self, forKey: .blurStyle) ?? .regular,
            textScale: try values.decodeIfPresent(Double.self, forKey: .textScale)
                ?? Self.defaultTextScale,
            privacyMode: try values.decodeIfPresent(CovePrivacyMode.self, forKey: .privacyMode) ?? .auto,
            launchAtLogin: try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            showNotifications: try values.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true,
            notificationPreferences: try values.decodeIfPresent(
                CoveNotificationPreferences.self,
                forKey: .notificationPreferences
            ) ?? .init(),
            playSounds: try values.decodeIfPresent(Bool.self, forKey: .playSounds) ?? true,
            globalShortcutsEnabled: try values.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled) ?? true,
            autoExpandOnEvent: try values.decodeIfPresent(Bool.self, forKey: .autoExpandOnEvent) ?? true,
            collapsedOpacity: try values.decodeIfPresent(Double.self, forKey: .collapsedOpacity) ?? 0.72,
            expandedOpacity: try values.decodeIfPresent(Double.self, forKey: .expandedOpacity) ?? 0.88,
            usageShowsRemaining: try values.decodeIfPresent(Bool.self, forKey: .usageShowsRemaining) ?? false,
            conservativeCapturePrivacy: try values.decodeIfPresent(Bool.self, forKey: .conservativeCapturePrivacy) ?? false,
            customThemeID: try values.decodeIfPresent(String.self, forKey: .customThemeID),
            residentSet: try values.decodeIfPresent(
                CoveResidentSet.self,
                forKey: .residentSet
            ) ?? .dungeonAndDragons,
            quietHours: try values.decodeIfPresent(CoveQuietHours.self, forKey: .quietHours) ?? .init(),
            silencedProjectRules: try values.decodeIfPresent([String].self, forKey: .silencedProjectRules) ?? [],
            followFocusedApp: try values.decodeIfPresent(Bool.self, forKey: .followFocusedApp) ?? false,
            glanceMode: try values.decodeIfPresent(Bool.self, forKey: .glanceMode) ?? false,
            hoverDelaySeconds: try values.decodeIfPresent(Double.self, forKey: .hoverDelaySeconds) ?? 0.25,
            autoCollapseSeconds: try values.decodeIfPresent(Double.self, forKey: .autoCollapseSeconds) ?? 6,
            collapsedWidth: try values.decodeIfPresent(Double.self, forKey: .collapsedWidth)
                ?? Self.defaultCollapsedWidth,
            squareTopCorners: try values.decodeIfPresent(
                Bool.self,
                forKey: .squareTopCorners
            ) ?? true,
            panelAnimationEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .panelAnimationEnabled
            ) ?? true,
            panelAnimationDuration: try values.decodeIfPresent(
                Double.self,
                forKey: .panelAnimationDuration
            ) ?? 0.24,
            idleAutoHideSeconds: try values.decodeIfPresent(Double.self, forKey: .idleAutoHideSeconds) ?? 0,
            followUpReminderSeconds: try values.decodeIfPresent(Double.self, forKey: .followUpReminderSeconds) ?? 10 * 60,
            minimalIslandMode: try values.decodeIfPresent(Bool.self, forKey: .minimalIslandMode) ?? false,
            showUsage: try values.decodeIfPresent(Bool.self, forKey: .showUsage) ?? true,
            showProfileTokenUsage: try values.decodeIfPresent(
                Bool.self,
                forKey: .showProfileTokenUsage
            ) ?? false,
            showTokenMetrics: try values.decodeIfPresent(
                Bool.self,
                forKey: .showTokenMetrics
            ) ?? false,
            queueSectionOrder: try values.decodeIfPresent(
                [CoveQueueSection].self,
                forKey: .queueSectionOrder
            ) ?? CoveQueueSection.allCases,
            collapsedQueueSections: try values.decodeIfPresent(
                Set<CoveQueueSection>.self,
                forKey: .collapsedQueueSections
            ) ?? [.more],
            workspaceAppearance: try values.decodeIfPresent(
                CoveWorkspaceAppearance.self,
                forKey: .workspaceAppearance
            ) ?? .system
        )
    }
}

public struct CoveEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case display
        case notification
        case command
    }

    public var kind: Kind
    public var title: String
    public var body: String?
    public var source: String?
    public var hostId: String?
    public var sessionId: String?
    public var turnId: String?
    /// Raw `CoveWireEnvelope.kind` value retained for local presentation logic.
    public var wireKind: String?
    public var timestamp: Date

    public init(
        kind: Kind,
        title: String,
        body: String? = nil,
        source: String? = nil,
        hostId: String? = nil,
        sessionId: String? = nil,
        turnId: String? = nil,
        wireKind: String? = nil,
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.source = source
        self.hostId = hostId
        self.sessionId = sessionId
        self.turnId = turnId
        self.wireKind = wireKind
        self.timestamp = timestamp
    }
}

public struct CoveState: Codable, Equatable, Sendable {
    public var session: CoveSessionState
    public var settings: CoveSettings
    public var theme: CoveThemePalette
    public var lastEvent: CoveEvent?
    public var recentEvents: [CoveEvent]
    public var pendingDirectRequests: [CoveDirectRequest]
    public var processedEventIDs: [String]
    public var usage: CoveUsageSnapshot?
    public var privacyScene: CovePrivacyScene
    public var quietReason: CoveQuietReason?
    public var pinnedSessionIDs: [String]
    public var dismissedSessionIDs: [String]
    public var sessionTokenMetrics: [String: CoveSessionTokenMetrics]

    /// Compatibility view of the oldest pending request.
    ///
    /// New code should use `pendingDirectRequests`; assigning this property is
    /// intentionally a full replacement for callers using the original
    /// single-request API.
    public var pendingDirectRequest: CoveDirectRequest? {
        get { pendingDirectRequests.first }
        set { pendingDirectRequests = newValue.map { [$0] } ?? [] }
    }

    public init(
        session: CoveSessionState = .init(),
        settings: CoveSettings = .init(),
        theme: CoveThemePalette = CoveThemeCatalog.palettes[0],
        lastEvent: CoveEvent? = nil,
        recentEvents: [CoveEvent] = [],
        pendingDirectRequest: CoveDirectRequest? = nil,
        pendingDirectRequests: [CoveDirectRequest] = [],
        processedEventIDs: [String] = [],
        usage: CoveUsageSnapshot? = nil,
        privacyScene: CovePrivacyScene = .normal,
        quietReason: CoveQuietReason? = nil,
        pinnedSessionIDs: [String] = [],
        dismissedSessionIDs: [String] = [],
        sessionTokenMetrics: [String: CoveSessionTokenMetrics] = [:]
    ) {
        self.session = session
        self.settings = settings
        self.theme = theme
        self.lastEvent = lastEvent
        self.recentEvents = recentEvents
        self.pendingDirectRequests = pendingDirectRequests.isEmpty
            ? pendingDirectRequest.map { [$0] } ?? []
            : pendingDirectRequests
        self.processedEventIDs = processedEventIDs
        self.usage = usage
        self.privacyScene = privacyScene
        self.quietReason = quietReason
        self.pinnedSessionIDs = Array(Set(pinnedSessionIDs)).sorted()
        self.dismissedSessionIDs = Array(Set(dismissedSessionIDs)).sorted()
        self.sessionTokenMetrics = sessionTokenMetrics
    }
}

public extension CoveState {
    /// Legacy sidecars stored raw session IDs. Count only values that now map
    /// to more than one live/restored origin; unresolved values remain inert
    /// but are not claimed to be ambiguous.
    var ambiguousLegacySessionIdentityCount: Int {
        let identities = session.snapshots.compactMap(\.sessionIdentity)
        let scopedKeys = Set(identities.map(\.id))
        return Set(pinnedSessionIDs + dismissedSessionIDs).reduce(0) {
            count, value in
            guard !scopedKeys.contains(value) else { return count }
            return identities.lazy.filter { $0.sessionId == value }.prefix(2)
                .count > 1 ? count + 1 : count
        }
    }
}

public enum CoveAction: Equatable, Sendable {
    case boot
    case toggleExpanded
    case setExpanded(Bool)
    case setVisible(Bool)
    case setDocked(Bool)
    case setThemeFamily(CoveThemeFamily)
    case setPalette(CovePaletteKind)
    case selectCustomTheme(CoveThemePalette)
    case clearCustomTheme
    case setResidentSet(CoveResidentSet)
    case setOpacity(CoveOpacityStyle)
    case setCollapsedOpacity(Double)
    case setExpandedOpacity(Double)
    case setTextScale(Double)
    case setWorkspaceAppearance(CoveWorkspaceAppearance)
    case setUsageShowsRemaining(Bool)
    case setConservativeCapturePrivacy(Bool)
    case setPrivacyScene(CovePrivacyScene)
    case setBlur(CoveBlurStyle)
    case setPrivacy(CovePrivacyMode)
    case setLaunchAtLogin(Bool)
    case setNotifications(Bool)
    case setNotificationRule(CoveNotificationEventKind, CoveNotificationRule)
    case setSounds(Bool)
    case setGlobalShortcuts(Bool)
    case setAutoExpand(Bool)
    case setQuietHours(CoveQuietHours)
    case setSilencedProjectRules([String])
    case setFollowFocusedApp(Bool)
    case setGlanceMode(Bool)
    case setHoverDelay(Double)
    case setAutoCollapseDelay(Double)
    case setCollapsedWidth(Double)
    case setSquareTopCorners(Bool)
    case setPanelAnimationEnabled(Bool)
    case setPanelAnimationDuration(Double)
    case setIdleAutoHideDelay(Double)
    case setFollowUpReminderDelay(Double)
    case setMinimalIslandMode(Bool)
    case setShowUsage(Bool)
    case setShowProfileTokenUsage(Bool)
    case setShowTokenMetrics(Bool)
    case setQueueSectionOrder([CoveQueueSection])
    case setQueueSectionCollapsed(CoveQueueSection, Bool)
    case restoreDismissedSessionIDs([String])
    case restoreDismissedSession(String?)
    case evaluateQuiet(Date, focusedBundleIdentifier: String?)
    case restorePinnedSessionIDs([String])
    case togglePinned(CoveSessionIdentity)
    case receivedUsage(CoveUsageSnapshot)
    case receivedEnvelope(CoveWireEnvelope)
    case receivedSnapshot(CoveSessionSnapshot)
    case receivedStatus(CoveSessionStatusUpdate)
    case restoreMetadata([CoveSessionMetadata])
    case setPendingDirectRequest(CoveDirectRequest?)
    case resolveDirectRequest(CoveDirectRequestKey)
    case resolveDirectRequests(
        sessionId: String,
        turnId: String?,
        launchId: String?,
        source: CoveWireSource? = nil,
        hostId: String? = nil
    )
    case forgetInternalSession(
        sessionId: String,
        source: CoveWireSource,
        hostId: String?
    )
    case markRead(CoveSessionIdentity)
    case dismissSnapshot(CoveSessionIdentity)
    case dismissSnapshots([CoveSessionIdentity])
    case clearRecentEvents
}

public enum CoveReducer {
    public static func reduce(_ state: inout CoveState, _ action: CoveAction) {
        switch action {
        case .boot:
            if state.settings.customThemeID == nil {
                state.theme = CoveThemeCatalog.palette(
                    for: state.settings.themeFamily,
                    palette: state.settings.palette
                )
            }
        case .toggleExpanded:
            if !state.settings.minimalIslandMode {
                state.session.isExpanded.toggle()
            }
        case let .setExpanded(value):
            if !value || !state.settings.minimalIslandMode {
                state.session.isExpanded = value
            }
        case let .setVisible(value):
            state.session.isVisible = value
        case let .setDocked(value):
            state.session.isDocked = value
        case let .setThemeFamily(family):
            state.settings.themeFamily = family
            state.settings.customThemeID = nil
            state.theme = CoveThemeCatalog.palette(for: family, palette: state.settings.palette)
        case let .setPalette(palette):
            state.settings.palette = palette
            state.settings.customThemeID = nil
            state.theme = CoveThemeCatalog.palette(for: state.settings.themeFamily, palette: palette)
        case let .selectCustomTheme(theme):
            guard !theme.isBuiltIn else {
                state.settings.customThemeID = nil
                state.settings.themeFamily = theme.family
                state.settings.palette = theme.palette
                state.theme = theme
                break
            }
            state.settings.customThemeID = theme.identifier
            state.theme = theme
            state.settings.collapsedOpacity = min(1, max(0.35, theme.collapsedOpacity))
            state.settings.expandedOpacity = min(1, max(0.35, theme.expandedOpacity))
            state.settings.blurStyle = theme.blurStyle
        case .clearCustomTheme:
            state.settings.customThemeID = nil
            state.theme = CoveThemeCatalog.palette(
                for: state.settings.themeFamily,
                palette: state.settings.palette
            )
        case let .setResidentSet(residentSet):
            state.settings.residentSet = residentSet
        case let .setOpacity(style):
            state.settings.opacityStyle = style
            state.settings.collapsedOpacity = style.collapsedAlpha
            state.settings.expandedOpacity = style.expandedAlpha
        case let .setCollapsedOpacity(value):
            state.settings.collapsedOpacity = min(1, max(0.35, value))
        case let .setExpandedOpacity(value):
            state.settings.expandedOpacity = min(1, max(0.35, value))
        case let .setTextScale(value):
            state.settings.textScale = CoveSettings.validatedTextScale(value)
        case let .setWorkspaceAppearance(appearance):
            state.settings.workspaceAppearance = appearance
        case let .setUsageShowsRemaining(value):
            state.settings.usageShowsRemaining = value
        case let .setConservativeCapturePrivacy(value):
            state.settings.conservativeCapturePrivacy = value
        case let .setPrivacyScene(scene):
            state.privacyScene = scene
        case let .setBlur(style):
            state.settings.blurStyle = style
        case let .setPrivacy(mode):
            state.settings.privacyMode = mode
        case let .setLaunchAtLogin(value):
            state.settings.launchAtLogin = value
        case let .setNotifications(value):
            state.settings.showNotifications = value
        case let .setNotificationRule(kind, rule):
            state.settings.notificationPreferences.set(rule, for: kind)
        case let .setSounds(value):
            state.settings.playSounds = value
        case let .setGlobalShortcuts(value):
            state.settings.globalShortcutsEnabled = value
        case let .setAutoExpand(value):
            state.settings.autoExpandOnEvent = value
        case let .setQuietHours(value):
            state.settings.quietHours = value
        case let .setSilencedProjectRules(rules):
            state.settings.silencedProjectRules =
                CoveSilencedProjectRules.normalize(rules)
        case let .setFollowFocusedApp(value):
            state.settings.followFocusedApp = value
            if !value, state.quietReason == .focusedApp {
                state.quietReason = nil
            }
        case let .setGlanceMode(value):
            state.settings.glanceMode = value
            if value, state.pendingDirectRequests.isEmpty {
                state.session.isExpanded = false
            }
        case let .setHoverDelay(value):
            state.settings.hoverDelaySeconds = min(3, max(0, value))
        case let .setAutoCollapseDelay(value):
            state.settings.autoCollapseSeconds = min(30, max(1, value))
        case let .setCollapsedWidth(value):
            state.settings.collapsedWidth = CoveSettings.validatedCollapsedWidth(value)
        case let .setSquareTopCorners(value):
            state.settings.squareTopCorners = value
        case let .setPanelAnimationEnabled(value):
            state.settings.panelAnimationEnabled = value
        case let .setPanelAnimationDuration(value):
            state.settings.panelAnimationDuration = min(0.8, max(0.08, value))
        case let .setIdleAutoHideDelay(value):
            state.settings.idleAutoHideSeconds = min(3_600, max(0, value))
        case let .setFollowUpReminderDelay(value):
            state.settings.followUpReminderSeconds = min(
                24 * 60 * 60,
                max(60, value)
            )
        case let .setMinimalIslandMode(value):
            state.settings.minimalIslandMode = value
            state.session.isVisible = true
            if value {
                state.session.isExpanded = false
            }
        case let .setShowUsage(value):
            state.settings.showUsage = value
        case let .setShowProfileTokenUsage(value):
            state.settings.showProfileTokenUsage = value
        case let .setShowTokenMetrics(value):
            state.settings.showTokenMetrics = value
        case let .setQueueSectionOrder(order):
            state.settings.queueSectionOrder =
                CoveSettings.validatedQueueSectionOrder(order)
        case let .setQueueSectionCollapsed(section, collapsed):
            if collapsed {
                state.settings.collapsedQueueSections.insert(section)
            } else {
                state.settings.collapsedQueueSections.remove(section)
            }
        case let .restoreDismissedSessionIDs(sessionIDs):
            state.dismissedSessionIDs = migratedPersistedIdentityKeys(
                sessionIDs,
                snapshots: state.session.snapshots
            )
            state.session.snapshots.removeAll { snapshot in
                snapshot.sessionIdentity.map {
                    state.dismissedSessionIDs.contains($0.id)
                } ?? false
            }
            sortSnapshots(in: &state)
            refreshActiveSnapshot(in: &state)
        case let .restoreDismissedSession(sessionID):
            if let sessionID {
                state.dismissedSessionIDs.removeAll { $0 == sessionID }
            } else {
                state.dismissedSessionIDs.removeAll()
            }
        case let .evaluateQuiet(date, focusedBundleIdentifier):
            state.quietReason = CoveQuietPolicy.reason(
                settings: state.settings,
                at: date,
                focusedBundleIdentifier: focusedBundleIdentifier
            )
        case let .restorePinnedSessionIDs(sessionIDs):
            state.pinnedSessionIDs = migratedPersistedIdentityKeys(
                sessionIDs,
                snapshots: state.session.snapshots
            )
            sortSnapshots(in: &state)
            refreshActiveSnapshot(in: &state)
        case let .togglePinned(identity):
            if state.pinnedSessionIDs.contains(identity.id) {
                state.pinnedSessionIDs.removeAll { $0 == identity.id }
            } else {
                state.pinnedSessionIDs.append(identity.id)
            }
            sortSnapshots(in: &state)
            refreshActiveSnapshot(in: &state)
        case let .receivedUsage(snapshot):
            // A full hydration replaces the previous snapshot. Missing fields
            // must remain visibly partial instead of inheriting stale healthy
            // values from an older response. Profile usage is independently
            // optional, though: if only that follow-up request fails, retain
            // its last good payload so the UI can label it refresh-unavailable
            // instead of erasing useful totals and history.
            var hydrated = snapshot
            if hydrated.accountTokenUsage == nil,
               hydrated.accountTokenUsageAvailability == .unavailable
            {
                hydrated.accountTokenUsage = state.usage?.accountTokenUsage
            }
            state.usage = hydrated
        case let .receivedEnvelope(envelope):
            guard !envelope.isPermanentlyHiddenInternalEvent else { break }
            guard !state.processedEventIDs.contains(envelope.processedEventKey)
            else { break }
            state.session.isVisible = true
            state.processedEventIDs.append(envelope.processedEventKey)
            if state.processedEventIDs.count > 1_024 {
                state.processedEventIDs.removeFirst(state.processedEventIDs.count - 1_024)
            }

            if let directRequest = envelope.directRequest() {
                upsert(directRequest: directRequest, into: &state)
            }

            let status = envelope.sessionStatusUpdate()
            if let resolvedID = envelope.resolvedRequestID() {
                let resolutionKey = CoveDirectRequestKey(
                    requestId: resolvedID,
                    launchId: envelope.launchId,
                    sessionId: envelope.sessionId,
                    turnId: envelope.turnId,
                    source: envelope.source,
                    hostId: envelope.hostId
                )
                let resolvedKey = removeDirectRequest(
                    resolvedBy: resolutionKey,
                    from: &state
                )
                if let resolvedKey, status == nil,
                   let index = state.session.snapshots
                    .firstIndex(where: {
                        $0.sessionId == resolvedKey.sessionId
                            && $0.launchId == resolvedKey.launchId
                            && $0.source == resolvedKey.source
                            && normalizedHostId(
                                source: $0.source,
                                hostId: $0.hostId
                            ) == resolvedKey.hostId
                    })
                {
                    var snapshot = state.session.snapshots[index]
                    let remainingStatus = pendingRequestStatus(
                        in: state,
                        sessionId: resolvedKey.sessionId,
                        launchId: resolvedKey.launchId,
                        source: resolvedKey.source,
                        hostId: resolvedKey.hostId
                    )
                    snapshot.status = remainingStatus?.status ?? .working
                    snapshot.priority = remainingStatus?.priority ?? 40
                    snapshot.timestamp = envelope.timestamp
                    _ = accept(snapshot: snapshot, into: &state)
                }
            }

            let decodedSnapshot = envelope.sessionSnapshot()
            let carriesSessionState = decodedSnapshot != nil || status != nil
            var acceptedStatusSnapshot = false
            if status == nil,
               let latestOutput = envelope.latestAssistantOutput(),
               var snapshot = state.session.snapshots.first(where: {
                   $0.sessionId == envelope.sessionId
                       && $0.originScope == envelope.originScope
               }) {
                snapshot.latestOutput = latestOutput
                snapshot.timestamp = envelope.timestamp
                if envelope.advertisesLaunchID {
                    snapshot.launchId = envelope.launchId
                }
                if envelope.advertisesParentSessionID {
                    snapshot.parentSessionId = envelope.parentSessionID()
                    snapshot.parentProvenanceConflict = envelope
                        .hasConflictingParentSessionID
                }
                acceptedStatusSnapshot = accept(
                    snapshot: snapshot,
                    into: &state,
                    preserveOmittedLaunchID: !envelope.advertisesLaunchID,
                    preserveOmittedParentID: !envelope.advertisesParentSessionID
                )
            }
            if var snapshot = decodedSnapshot {
                if snapshot.unread,
                   let existing = state.session.snapshots.first(where: {
                       $0.snapshotId == snapshot.snapshotId
                           && $0.originScope == snapshot.originScope
                   }),
                   !existing.unread,
                   existing.status == snapshot.status,
                   existing.timestamp >= snapshot.timestamp
                {
                    // Reconciliation may repeat the same terminal snapshot.
                    // Preserve an explicit read acknowledgement until a newer
                    // state or timestamp arrives.
                    snapshot.unread = false
                }
                acceptedStatusSnapshot = accept(
                    snapshot: snapshot,
                    into: &state,
                    preserveOmittedLaunchID: !envelope.advertisesLaunchID,
                    preserveOmittedParentID: !envelope.advertisesParentSessionID
                )
            } else if let status {
                let snapshotID = envelope.sessionId == "pending"
                    ? (envelope.launchId ?? envelope.eventId)
                    : envelope.sessionId
                let existing = state.session.snapshots.first(where: {
                    $0.snapshotId == snapshotID
                        && $0.originScope == envelope.originScope
                })
                let payload = envelope.payload.objectValue ?? [:]
                let liveness = payload["liveness"]?.stringValue.flatMap(
                    CoveSessionLiveness.init(rawValue:)
                )
                let controlRoute = payload["controlRoute"]?.stringValue.flatMap(
                    CoveThreadControlRoute.init(rawValue:)
                )
                let activeTurnId = envelope.endsActiveTurn
                    ? nil
                    : envelope.authoritativeStartedTurnID()
                        ?? payload["activeTurnId"]?.scalarStringValue
                let changedSinceAcknowledgement = existing == nil
                    || existing?.status != status.status
                    || (existing?.timestamp ?? .distantPast) < envelope.timestamp
                let display = envelope.displayEvent()
                acceptedStatusSnapshot = accept(
                    snapshot: CoveSessionSnapshot(
                        snapshotId: snapshotID,
                        status: status.status,
                        priority: status.priority,
                        title: display.title,
                        detail: display.body,
                        latestOutput: envelope.latestAssistantOutput()
                            ?? existing?.latestOutput,
                        timestamp: envelope.timestamp,
                        sessionId: envelope.sessionId,
                        launchId: envelope.launchId,
                        source: envelope.source,
                        hostId: envelope.hostId,
                        parentSessionId: envelope.parentSessionID(),
                        parentProvenanceConflict: envelope
                            .hasConflictingParentSessionID,
                        liveness: liveness,
                        activeTurnId: activeTurnId,
                        controlRoute: controlRoute,
                        unread: existing?.unread == true
                            || (
                                status.status.requiresUnreadAcknowledgement
                                    && changedSinceAcknowledgement
                            )
                    ),
                    into: &state,
                    preserveOmittedLaunchID: !envelope.advertisesLaunchID,
                    preserveOmittedParentID: !envelope.advertisesParentSessionID
                )
            }

            // A status event is globally visible only if its per-session
            // snapshot was accepted. This keeps late envelopes from replacing
            // the pill or the most-recent activity after a newer status.
            if !carriesSessionState || acceptedStatusSnapshot {
                record(
                    event: envelope.displayEvent(),
                    envelope: envelope,
                    in: &state
                )
            }

            if let usage = envelope.usageSnapshot() {
                state.usage = state.usage?.merging(usage) ?? usage
            }
            if let metrics = tokenMetrics(from: envelope) {
                state.sessionTokenMetrics[envelope.scopedSessionKey] = metrics
            }
            // Status and direct-request events only update the collapsed cue.
            // Expansion is reserved for deliberate user interaction.
        case let .receivedSnapshot(snapshot):
            _ = accept(snapshot: snapshot, into: &state)
        case .receivedStatus:
            // A status update without session identity cannot be ordered
            // safely. Envelope handling materializes it as a timestamped
            // session snapshot, and only accepted snapshots derive top-level
            // pill and recent state.
            break
        case let .restoreMetadata(records):
            let restoredIdentities = records.compactMap(\.sessionIdentity)
            state.dismissedSessionIDs = migratedPersistedIdentityKeys(
                state.dismissedSessionIDs,
                identities: restoredIdentities
            )
            state.pinnedSessionIDs = migratedPersistedIdentityKeys(
                state.pinnedSessionIDs,
                identities: restoredIdentities
            )
            state.session.snapshots = records.compactMap { metadata in
                guard let identity = metadata.sessionIdentity,
                      !state.dismissedSessionIDs.contains(identity.id)
                else { return nil }
                return CoveSessionSnapshot(
                    snapshotId: metadata.sessionId,
                    status: metadata.status,
                    priority: priority(for: metadata.status, unread: metadata.unread),
                    title: "Codex task",
                    detail: metadata.source.displayName,
                    timestamp: metadata.updatedAt,
                    sessionId: metadata.sessionId,
                    launchId: metadata.launchId,
                    source: metadata.source,
                    hostId: metadata.hostId,
                    parentSessionId: metadata.parentSessionId,
                    unread: metadata.unread
                )
            }
            sortSnapshots(in: &state)
            refreshActiveSnapshot(in: &state)
            state.session.isListening = !records.isEmpty
        case let .setPendingDirectRequest(request):
            state.pendingDirectRequest = request
        case let .resolveDirectRequest(key):
            _ = removeDirectRequest(matching: key, from: &state)
        case let .resolveDirectRequests(
            sessionId,
            turnId,
            launchId,
            source,
            hostId
        ):
            let baseCandidates = state.pendingDirectRequests.indices.filter {
                index in
                let request = state.pendingDirectRequests[index]
                guard request.sessionId == sessionId else { return false }
                if let turnId, request.turnId != turnId { return false }
                if let launchId, request.launchId != launchId { return false }
                return true
            }
            let resolutionKey = CoveDirectRequestKey(
                requestId: .string("bulk-resolution"),
                launchId: launchId,
                sessionId: sessionId,
                turnId: turnId,
                source: source,
                hostId: hostId
            )
            let resolvedIndices = indicesMatchingOrigin(
                baseCandidates,
                resolutionKey: resolutionKey,
                in: state
            )
            let resolvedKeys = resolvedIndices.map {
                state.pendingDirectRequests[$0].key
            }
            let resolvedIndexSet = Set(resolvedIndices)
            state.pendingDirectRequests = state.pendingDirectRequests
                .enumerated()
                .filter { !resolvedIndexSet.contains($0.offset) }
                .map(\.element)

            guard let resolvedKey = resolvedKeys.first else { break }
            if !state.pendingDirectRequests.contains(where: {
                $0.sessionId == sessionId
                    && originsMatch($0.key, resolvedKey)
            }), let index = state.session.snapshots.firstIndex(where: {
                ($0.sessionId ?? $0.snapshotId) == sessionId
                    && (launchId == nil || $0.launchId == launchId)
                    && $0.source == resolvedKey.source
                    && normalizedHostId(
                        source: $0.source,
                        hostId: $0.hostId
                    ) == resolvedKey.hostId
            }), [
                CoveSessionStatus.waitingApproval,
                .waitingInput,
                .blocked,
            ].contains(state.session.snapshots[index].status) {
                state.session.snapshots[index].status = .working
                state.session.snapshots[index].priority = 40
                state.session.snapshots[index].unread = false
                sortSnapshots(in: &state)
                refreshActiveSnapshot(in: &state)
            }
        case let .forgetInternalSession(sessionID, source, hostID):
            guard let origin = CoveOriginScope(source: source, hostId: hostID)
            else { break }
            let forgottenIdentity = CoveSessionIdentity(
                scope: origin,
                sessionId: sessionID
            )
            state.session.snapshots.removeAll {
                ($0.snapshotId == sessionID || $0.sessionId == sessionID)
                    && $0.originScope == origin
            }
            state.pendingDirectRequests.removeAll {
                $0.sessionId == sessionID
                    && CoveOriginScope(
                        source: $0.key.source,
                        hostId: $0.key.hostId
                    ) == origin
            }
            state.sessionTokenMetrics.removeValue(
                forKey: CoveScopedIdentityKey.session(
                    sessionId: sessionID,
                    source: source,
                    hostId: hostID
                )
            )
            if state.session.lastEnvelope?.sessionId == sessionID,
               state.session.lastEnvelope?.originScope == origin {
                state.session.lastEnvelope = nil
            }
            state.recentEvents.removeAll {
                $0.sessionId == sessionID && $0.originScope == origin
            }
            if let forgottenIdentity {
                state.pinnedSessionIDs.removeAll {
                    $0 == forgottenIdentity.id
                }
                state.dismissedSessionIDs.removeAll {
                    $0 == forgottenIdentity.id
                }
            }
            state.lastEvent = state.recentEvents.first
            sortSnapshots(in: &state)
            refreshActiveSnapshot(in: &state)
        case let .markRead(identity):
            if let index = state.session.snapshots.firstIndex(where: {
                $0.sessionIdentity == identity
            }) {
                state.session.snapshots[index].unread = false
                if state.session.snapshots[index].status == .completed {
                    state.session.snapshots[index].priority = priority(
                        for: .completed,
                        unread: false
                    )
                }
                sortSnapshots(in: &state)
                refreshActiveSnapshot(in: &state)
            }
        case let .dismissSnapshot(identity):
            dismissSnapshots(in: &state, identities: [identity])
        case let .dismissSnapshots(identities):
            dismissSnapshots(in: &state, identities: identities)
        case .clearRecentEvents:
            state.recentEvents.removeAll()
            state.lastEvent = nil
        }
    }

    private static func dismissSnapshots(
        in state: inout CoveState,
        identities: [CoveSessionIdentity]
    ) {
        let requested = Set(identities)
        guard !requested.isEmpty else { return }
        state.session.snapshots.removeAll {
            $0.sessionIdentity.map(requested.contains) ?? false
        }
        state.dismissedSessionIDs = Array(
            Set(state.dismissedSessionIDs).union(requested.map(\.id))
        ).sorted()
        let requestedKeys = Set(requested.map(\.id))
        state.pinnedSessionIDs.removeAll(where: requestedKeys.contains)
        sortSnapshots(in: &state)
        refreshActiveSnapshot(in: &state)
    }

    @discardableResult
    private static func accept(
        snapshot: CoveSessionSnapshot,
        into state: inout CoveState,
        preserveOmittedLaunchID: Bool = true,
        preserveOmittedParentID: Bool = true
    ) -> Bool {
        if let identity = snapshot.sessionIdentity,
           state.dismissedSessionIDs.contains(identity.id) {
            return false
        }
        guard upsert(
            snapshot: snapshot,
            into: &state,
            preserveOmittedLaunchID: preserveOmittedLaunchID,
            preserveOmittedParentID: preserveOmittedParentID
        ) else {
            return false
        }
        refreshActiveSnapshot(in: &state)
        state.session.isListening = snapshot.status == .listening
            || state.session.isListening
        return true
    }

    private static func record(
        event: CoveEvent,
        envelope: CoveWireEnvelope,
        in state: inout CoveState
    ) {
        state.recentEvents.append(event)
        state.recentEvents.sort { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
        state.recentEvents = Array(state.recentEvents.prefix(16))
        state.lastEvent = state.recentEvents.first
        if state.session.lastEnvelope == nil
            || state.session.lastEnvelope!.timestamp <= envelope.timestamp
        {
            state.session.lastEnvelope = envelope
        }
    }

    private static func upsert(
        directRequest: CoveDirectRequest,
        into state: inout CoveState
    ) {
        if let index = state.pendingDirectRequests.firstIndex(where: {
            $0.key == directRequest.key
        }) {
            state.pendingDirectRequests[index] = directRequest
        } else {
            state.pendingDirectRequests.append(directRequest)
        }
    }

    @discardableResult
    private static func removeDirectRequest(
        matching key: CoveDirectRequestKey,
        from state: inout CoveState
    ) -> Bool {
        let candidates = state.pendingDirectRequests.indices.filter { index in
            let candidate = state.pendingDirectRequests[index].key
            return candidate.requestId == key.requestId
                && candidate.launchId == key.launchId
                && candidate.sessionId == key.sessionId
                && candidate.turnId == key.turnId
        }
        let matches = indicesMatchingOrigin(
            candidates,
            resolutionKey: key,
            in: state
        )
        guard matches.count == 1, let index = matches.first else {
            return false
        }
        state.pendingDirectRequests.remove(at: index)
        return true
    }

    /// Removes the one live request identified by a broker resolution.
    ///
    /// App-server resolution notifications do not always carry a thread ID;
    /// the broker represents that missing scope as `unknown` or `pending`.
    /// Launch identity still scopes the JSON-RPC ID in that case. An ambiguous
    /// wildcard never removes anything.
    private static func removeDirectRequest(
        resolvedBy resolutionKey: CoveDirectRequestKey,
        from state: inout CoveState
    ) -> CoveDirectRequestKey? {
        let sessionIsUnavailable = resolutionKey.sessionId.isEmpty
            || resolutionKey.sessionId == "unknown"
            || resolutionKey.sessionId == "pending"
        let baseCandidates = state.pendingDirectRequests.indices.filter { index in
            let key = state.pendingDirectRequests[index].key
            return key.requestId == resolutionKey.requestId
                && key.launchId == resolutionKey.launchId
                && (sessionIsUnavailable
                    || key.sessionId == resolutionKey.sessionId)
                && (resolutionKey.turnId == nil
                    || key.turnId == resolutionKey.turnId)
        }
        let matches = indicesMatchingOrigin(
            baseCandidates,
            resolutionKey: resolutionKey,
            in: state
        )
        guard matches.count == 1, let index = matches.first else {
            return nil
        }
        let removedKey = state.pendingDirectRequests[index].key
        state.pendingDirectRequests.remove(at: index)
        return removedKey
    }

    private static func pendingRequestStatus(
        in state: CoveState,
        sessionId: String,
        launchId: String?,
        source: CoveWireSource?,
        hostId: String?
    ) -> (status: CoveSessionStatus, priority: Int)? {
        let scopedRequests = state.pendingDirectRequests.filter {
            $0.sessionId == sessionId
                && $0.launchId == launchId
                && $0.source == source
                && $0.hostId == normalizedHostId(
                    source: source,
                    hostId: hostId
                )
        }
        if scopedRequests.contains(where: {
            if case .approval = $0 { return true }
            return false
        }) {
            return (.waitingApproval, 100)
        }
        if scopedRequests.contains(where: {
            if case .question = $0 { return true }
            return false
        }) {
            return (.waitingInput, 95)
        }
        return nil
    }

    /// Returns only candidates whose origin can be identified without
    /// guessing. Old decoded requests have no source/host fields, so they are
    /// accepted only when the base request scope contains exactly one item.
    private static func indicesMatchingOrigin(
        _ candidates: [Int],
        resolutionKey: CoveDirectRequestKey,
        in state: CoveState
    ) -> [Int] {
        guard !candidates.isEmpty else { return [] }

        switch resolutionKey.source {
        case .localCli?, .codexDesktop?:
            let exact = candidates.filter {
                state.pendingDirectRequests[$0].source == resolutionKey.source
            }
            if !exact.isEmpty { return exact }
            guard candidates.count == 1,
                  state.pendingDirectRequests[candidates[0]].source == nil
            else { return [] }
            return candidates

        case .remoteCli?:
            if let hostId = resolutionKey.hostId {
                let exact = candidates.filter { index in
                    let request = state.pendingDirectRequests[index]
                    return request.source == .remoteCli
                        && request.hostId == hostId
                }
                if !exact.isEmpty { return exact }
                guard candidates.count == 1 else { return [] }
                let legacy = state.pendingDirectRequests[candidates[0]]
                guard legacy.source == nil
                        || (legacy.source == .remoteCli
                            && legacy.hostId == nil)
                else { return [] }
                return candidates
            }

            let compatible = candidates.filter { index in
                let source = state.pendingDirectRequests[index].source
                return source == nil || source == .remoteCli
            }
            return compatible.count == 1 ? compatible : []

        case nil:
            return candidates.count == 1 ? candidates : []
        }
    }

    private static func originsMatch(
        _ lhs: CoveDirectRequestKey,
        _ rhs: CoveDirectRequestKey
    ) -> Bool {
        lhs.source == rhs.source
            && lhs.hostId == rhs.hostId
    }

    private static func normalizedHostId(
        source: CoveWireSource?,
        hostId: String?
    ) -> String? {
        source == .remoteCli ? hostId : nil
    }

    private static func migratedPersistedIdentityKeys(
        _ values: [String],
        snapshots: [CoveSessionSnapshot]
    ) -> [String] {
        migratedPersistedIdentityKeys(
            values,
            identities: snapshots.compactMap(\.sessionIdentity)
        )
    }

    /// Schema-v1 sidecars stored raw IDs. Apply one only when exactly one
    /// current origin owns it; ambiguous and unresolved values are retained
    /// byte-for-byte but intentionally match no scoped task.
    private static func migratedPersistedIdentityKeys(
        _ values: [String],
        identities: [CoveSessionIdentity]
    ) -> [String] {
        let knownKeys = Set(identities.map(\.id))
        return Array(Set(values.map { value in
            if knownKeys.contains(value) { return value }
            let candidates = identities.filter { $0.sessionId == value }
            return candidates.count == 1 ? candidates[0].id : value
        })).sorted()
    }

    @discardableResult
    private static func upsert(
        snapshot: CoveSessionSnapshot,
        into state: inout CoveState,
        preserveOmittedLaunchID: Bool,
        preserveOmittedParentID: Bool
    ) -> Bool {
        // Snapshot IDs are unique only within a composite source/host origin.
        // The complete identity is now carried through every lookup, so a
        // matching opaque ID at another origin is an independent task.
        let existing = state.session.snapshots.first(where: {
            $0.snapshotId == snapshot.snapshotId
                && $0.originScope == snapshot.originScope
        })
        if let existing, existing.timestamp > snapshot.timestamp {
            return false
        }
        if snapshot.sessionId != "pending", let launchID = snapshot.launchId {
            state.session.snapshots.removeAll {
                $0.launchId == launchID
                    && $0.sessionId == "pending"
                    && $0.originScope == snapshot.originScope
            }
        }
        var normalized = snapshot
        if let existing,
           normalized.sessionIdentity == existing.sessionIdentity {
            if normalized.launchId == nil, preserveOmittedLaunchID {
                normalized.launchId = existing.launchId
            }
            if normalized.parentSessionId == nil,
               preserveOmittedParentID,
               normalized.parentProvenanceConflict != true {
                normalized.parentSessionId = existing.parentSessionId
            }
        }
        if normalized.latestOutput == nil {
            normalized.latestOutput = existing?.latestOutput
        }
        if normalized.status == .completed {
            normalized.priority = priority(
                for: .completed,
                unread: normalized.unread
            )
        }
        if let index = state.session.snapshots.firstIndex(where: {
            $0.snapshotId == normalized.snapshotId
                && $0.originScope == normalized.originScope
        }) {
            state.session.snapshots[index] = normalized
        } else {
            state.session.snapshots.append(normalized)
        }
        sortSnapshots(in: &state)
        return true
    }

    private static func sortSnapshots(in state: inout CoveState) {
        state.session.snapshots.sort { lhs, rhs in
            let lhsPinned = lhs.sessionIdentity.map {
                state.pinnedSessionIDs.contains($0.id)
            } ?? false
            let rhsPinned = rhs.sessionIdentity.map {
                state.pinnedSessionIDs.contains($0.id)
            } ?? false
            if lhsPinned != rhsPinned {
                return lhsPinned
            }
            if lhs.priority == rhs.priority {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.priority > rhs.priority
        }
    }

    private static func refreshActiveSnapshot(in state: inout CoveState) {
        // Pinning changes card order, never urgency. The collapsed pill and
        // alert state still derive from the highest-priority live snapshot.
        state.session.activeSnapshot = state.session.snapshots.max { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.priority < rhs.priority
        }
        if let active = state.session.activeSnapshot {
            state.session.activeStatus = active.status
            state.session.statusPriority = active.priority
        } else {
            state.session.activeStatus = .idle
            state.session.statusPriority = 0
        }
    }

    private static func priority(
        for status: CoveSessionStatus,
        unread: Bool = true
    ) -> Int {
        switch status {
        case .blocked, .waitingApproval:
            return 100
        case .waitingInput:
            return 95
        case .failed:
            return 90
        case .interrupted:
            return 85
        case .completed:
            return unread ? 80 : 8
        case .compacting:
            return 60
        case .active, .working:
            return 40
        case .listening:
            return 10
        case .idle:
            return 5
        case .quiet:
            return 2
        case .hidden:
            return 1
        }
    }

    private static func tokenMetrics(
        from envelope: CoveWireEnvelope
    ) -> CoveSessionTokenMetrics? {
        let object = envelope.payload.objectValue ?? [:]
        let message = object["message"]?.objectValue ?? object
        guard message["method"]?.stringValue == "thread/tokenUsage/updated"
        else { return nil }
        let params = message["params"]?.objectValue
            ?? object["params"]?.objectValue
            ?? [:]
        guard let tokenUsage = params["tokenUsage"]?.objectValue,
              let total = tokenUsage["total"]?.objectValue
        else { return nil }
        func optionalInt(_ key: String) -> Int? {
            guard total[key] != nil else { return nil }
            return total[key]?.intValue
        }
        return CoveSessionTokenMetrics(
            inputTokens: optionalInt("inputTokens"),
            cachedInputTokens: optionalInt("cachedInputTokens"),
            outputTokens: optionalInt("outputTokens"),
            reasoningOutputTokens: optionalInt("reasoningOutputTokens"),
            totalTokens: optionalInt("totalTokens"),
            contextWindow: tokenUsage["modelContextWindow"]?.intValue,
            capturedAt: envelope.timestamp
        )
    }
}

public extension CoveWireSource {
    var displayName: String {
        switch self {
        case .localCli:
            return "Local CLI"
        case .codexDesktop:
            return "Codex Desktop"
        case .remoteCli:
            return "Remote CLI"
        }
    }
}

public extension CoveSessionStatus {
    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .listening:
            return "Listening"
        case .active, .working:
            return "Working"
        case .blocked, .waitingApproval:
            return "Waiting for approval"
        case .waitingInput:
            return "Waiting for input"
        case .compacting:
            return "Compacting"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .interrupted:
            return "Interrupted"
        case .quiet:
            return "Quiet"
        case .hidden:
            return "Hidden"
        }
    }
}
