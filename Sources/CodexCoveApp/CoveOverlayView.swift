import SwiftUI
import CoveCore

struct CoveOverlayRootView: View {
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var presentationMetrics: CoveOverlayPresentationMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenSettings: @MainActor () -> Void
    let onRestoreArchived: @MainActor (String?) -> Void
    let fixtureStateDirectory: String?

    var body: some View {
        let state = store.state
        let redactsSensitiveContent = state.settings.privacyMode == .on
            || state.privacyScene != .normal
            || state.session.activeStatus == .hidden
        let presentation = store.overlayPresentation
        ZStack {
            if state.settings.minimalIslandMode {
                Color(hex: state.theme.backgroundHex).opacity(0.97)
                CoveMinimalIslandView(state: state)
            } else {
                CoveBackdropView(
                    theme: state.theme,
                    opacity: presentation.isExpanded
                        ? state.settings.expandedOpacity
                        : state.settings.collapsedOpacity,
                    blur: state.settings.blurStyle,
                    privacy: state.settings.privacyMode,
                    squareTopCorners: state.settings.squareTopCorners
                )
            }
            if state.settings.minimalIslandMode {
                EmptyView()
            } else {
                switch presentation {
                case .collapsed:
                    CoveCollapsedBubbleView(state: state)
                case .queue:
                    CoveQueueSurfaceView(
                        state: state,
                        redactsSensitiveContent: redactsSensitiveContent,
                        onOpenSettings: onOpenSettings,
                        onRestoreArchived: onRestoreArchived
                    )
                case let .focused(target):
                    CoveFocusedSurfaceView(
                        target: target,
                        state: state,
                        redactsSensitiveContent: redactsSensitiveContent
                    )
                }
            }

            if let fixtureStateDirectory {
                CoveFixtureAccessibilityMarkers(
                    stateDirectory: fixtureStateDirectory,
                    decisionAttemptCount: store.fixtureRecordedDecisionCount,
                    jumpCount: store.fixtureRecordedJumpCount,
                    queueSectionOrder: state.settings.queueSectionOrder,
                    textScale: state.settings.textScale
                )
            }

            if let confirmation = store.pendingDirtyExitConfirmation {
                CoveDirtyExitConfirmationView(
                    confirmation: confirmation,
                    theme: state.theme
                )
            }
        }
        .clipShape(
            CoveOverlayClipShape(
                cornerRadius: state.settings.minimalIslandMode
                    ? 12
                    : presentation.isExpanded
                        ? state.theme.cornerRadius
                        : 16,
                squareTopCorners: state.settings.squareTopCorners
                    && !state.settings.minimalIslandMode
            )
        )
        .coveThemeFont(state.theme, size: 13)
        .coveTextScale(state.settings.textScale)
        .lineSpacing(max(0, (state.theme.lineHeight - 1) * 13))
        .animation(
            reduceMotion || !state.theme.animationEnabled
                ? nil
                : state.theme.coveAnimation,
            value: presentation
        )
        .transaction { transaction in
            if reduceMotion || !state.theme.animationEnabled {
                transaction.animation = nil
            }
        }
        .onHover { hovered in
            store.setOverlayHovered(hovered)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.overlay")
    }
}

struct CoveCollapsedBubbleView: View {
    private static let residentFlowInterval: TimeInterval = 2.4

    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var presentationMetrics: CoveOverlayPresentationMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    let state: CoveState

    var body: some View {
        Button {
            store.beginOverlayInteraction()
        } label: {
            GeometryReader { geometry in
                let availableWidth = max(0, geometry.size.width)
                let availableHeight = max(0, geometry.size.height)
                let topBandHeight = min(
                    availableHeight,
                    max(24, presentationMetrics.topContentInset)
                )
                let lowerBandHeight = max(0, availableHeight - topBandHeight)
                let centerClearance = resolvedCenterClearance(
                    availableWidth: availableWidth,
                    reportedObstructionWidth: presentationMetrics.topObstructionWidth
                )
                let unrestrictedLayout = CoveResidentFlowLayout.resolve(
                    width: Double(availableWidth),
                    height: Double(availableHeight),
                    topBandHeight: Double(topBandHeight),
                    centerClearance: Double(centerClearance)
                )
                let needsOverflow = cues.count > unrestrictedLayout.capacity
                let showsOverflowBadge = needsOverflow
                    && lowerBandHeight >= 14
                    && availableWidth >= 28
                let layout = CoveResidentFlowLayout.resolve(
                    width: Double(availableWidth),
                    height: Double(availableHeight),
                    topBandHeight: Double(topBandHeight),
                    centerClearance: Double(centerClearance),
                    lowerTrailingReservation: showsOverflowBadge ? 36 : 0
                )
                let hiddenCount = CoveResidentFlowSequence.hiddenCount(
                    residentCount: cues.count,
                    slotCount: layout.capacity
                )

                residentFlow(layout: layout, hasOverflow: hiddenCount > 0)
                    .overlay(alignment: .bottomTrailing) {
                        if showsOverflowBadge, hiddenCount > 0 {
                            overflowBadge(
                                hiddenCount: hiddenCount,
                                lowerBandHeight: lowerBandHeight
                            )
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule())
        .accessibilityLabel("Open task queue")
        .accessibilityValue(collapsedAccessibilityValue)
        .accessibilityHint("Click or hover to expand Codex Cove")
        .accessibilityIdentifier(CoveAccessibilityIDs.overlayExpand)
    }

    private var collapsedAccessibilityValue: String {
        let attentionCount = visibleSnapshots.filter {
            [.waitingApproval, .waitingInput, .blocked, .failed].contains(
                $0.status
            )
        }.count
        let activeCount = visibleSnapshots.filter {
            [.working, .active, .compacting].contains($0.status)
        }.count
        return "\(attentionCount) need attention, \(activeCount) active"
    }

    private var visibleSnapshots: [CoveSessionSnapshot] {
        CoveSessionVisualCuePolicy.visibleSnapshots(
            in: state.session.snapshots
        )
    }

    private var unrepresentedRequests: [CoveDirectRequest] {
        let represented = Set(
            visibleSnapshots.map { $0.sessionId ?? $0.snapshotId }
        )
        return state.pendingDirectRequests.filter {
            !represented.contains($0.sessionId)
        }
    }

    private struct CueDescriptor: Identifiable {
        var id: String
        var characterIdentity: String
        var status: CoveSessionStatus
    }

    private struct PlacedCue: Identifiable {
        var descriptor: CueDescriptor
        var slot: CoveResidentFlowLayout.Slot

        var id: String { descriptor.id }
    }

    private var cues: [CueDescriptor] {
        let snapshotCues = visibleSnapshots.map {
            CueDescriptor(
                id: "snapshot:\($0.snapshotId)",
                characterIdentity: $0.sessionId ?? $0.snapshotId,
                status: $0.status
            )
        }
        let requestCues = unrepresentedRequests.map {
            CueDescriptor(
                id: "request:\($0.key)",
                characterIdentity: $0.sessionId,
                status: requestStatus($0)
            )
        }
        return snapshotCues + requestCues
    }

    private func requestStatus(_ request: CoveDirectRequest) -> CoveSessionStatus {
        switch request {
        case .approval:
            return .waitingApproval
        case .question:
            return .waitingInput
        case .planSnapshot:
            return .working
        }
    }

    private func resolvedCenterClearance(
        availableWidth: CGFloat,
        reportedObstructionWidth: CGFloat
    ) -> CGFloat {
        let minimumSideWidth: CGFloat = 26
        let maximumClearance = max(0, availableWidth - minimumSideWidth * 2)
        let fallbackClearance = min(180, max(92, availableWidth * 0.48))
        return min(
            maximumClearance,
            max(0, reportedObstructionWidth > 0
                ? reportedObstructionWidth
                : fallbackClearance)
        )
    }

    @ViewBuilder
    private func residentFlow(
        layout: CoveResidentFlowLayout,
        hasOverflow: Bool
    ) -> some View {
        if hasOverflow, layout.capacity > 0, !reduceMotion {
            TimelineView(
                .periodic(from: .now, by: Self.residentFlowInterval)
            ) { context in
                let step = Int(floor(
                    context.date.timeIntervalSinceReferenceDate
                        / Self.residentFlowInterval
                ))
                residentCanvas(
                    layout: layout,
                    step: step,
                    animatesPlacement: true
                )
            }
        } else {
            residentCanvas(
                layout: layout,
                step: 0,
                animatesPlacement: false
            )
        }
    }

    private func residentCanvas(
        layout: CoveResidentFlowLayout,
        step: Int,
        animatesPlacement: Bool
    ) -> some View {
        let placements = placements(layout: layout, step: step)
        return ZStack(alignment: .topLeading) {
            ForEach(placements) { placement in
                cue(
                    placement.descriptor,
                    size: CGFloat(placement.slot.size)
                )
                .position(
                    x: CGFloat(placement.slot.centerX),
                    y: CGFloat(placement.slot.centerY)
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(
                            with: .scale(scale: 0.65)
                        ),
                        removal: .opacity.combined(
                            with: .scale(scale: 0.85)
                        )
                    )
                )
            }
        }
        .frame(
            width: CGFloat(layout.width),
            height: CGFloat(layout.height),
            alignment: .topLeading
        )
        .animation(
            animatesPlacement
                ? .easeInOut(duration: 0.72)
                : nil,
            value: step
        )
    }

    private func placements(
        layout: CoveResidentFlowLayout,
        step: Int
    ) -> [PlacedCue] {
        CoveResidentFlowSequence.assignments(
            residentCount: cues.count,
            slotCount: layout.capacity,
            step: step
        ).compactMap { assignment in
            guard cues.indices.contains(assignment.residentIndex),
                  layout.slots.indices.contains(assignment.slotIndex)
            else {
                return nil
            }
            return PlacedCue(
                descriptor: cues[assignment.residentIndex],
                slot: layout.slots[assignment.slotIndex]
            )
        }
    }

    @ViewBuilder
    private func overflowBadge(
        hiddenCount: Int,
        lowerBandHeight: CGFloat
    ) -> some View {
        let badgeHeight = min(18, max(14, lowerBandHeight - 4))
        Text("+\(hiddenCount)")
            .coveOverlayFont(state.theme, .badge)
            .foregroundStyle(Color(hex: state.theme.foregroundHex))
            .lineLimit(1)
            .frame(width: 30, height: badgeHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(hex: state.theme.backgroundHex).opacity(0.9))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        Color(hex: state.theme.accentHex).opacity(0.75),
                        lineWidth: 1
                    )
            }
            .padding(.trailing, 4)
            .padding(.bottom, max(0, (lowerBandHeight - badgeHeight) / 2))
            .accessibilityLabel("\(hiddenCount) additional residents")
    }

    private func residentAccessibilityValue(
        visibleCount: Int,
        hiddenCount: Int
    ) -> String {
        let totalCount = visibleCount + hiddenCount
        guard totalCount > 0 else { return "No active residents" }
        let noun = totalCount == 1 ? "resident" : "residents"
        guard hiddenCount > 0 else {
            return "\(totalCount) \(noun), all visible"
        }
        if reduceMotion {
            return "\(totalCount) \(noun), \(visibleCount) visible, "
                + "\(hiddenCount) more indicated; rotation paused for Reduce Motion"
        }
        return "\(totalCount) \(noun), \(visibleCount) visible at a time, "
            + "\(hiddenCount) rotating through the cove"
    }

    private func cue(_ descriptor: CueDescriptor, size: CGFloat) -> some View {
        CovePixelCharacterBubble(
            character: CovePixelCharacter.assigned(
                to: descriptor.characterIdentity,
                set: state.settings.residentSet
            ),
            status: descriptor.status,
            theme: state.theme,
            reduceMotion: reduceMotion,
            size: size
        )
        .frame(width: size, height: size, alignment: .bottom)
        .overlay {
            if differentiateWithoutColor {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        Color(hex: state.theme.statusHex(descriptor.status)),
                        lineWidth: 1
                    )
            }
        }
        .accessibilityLabel(descriptor.status.displayName)
    }
}

private struct CoveOverlayClipShape: InsettableShape {
    let cornerRadius: CGFloat
    let squareTopCorners: Bool
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(
            cornerRadius,
            max(0, min(rect.width, rect.height) / 2)
        )
        let radii = RectangleCornerRadii(
            topLeading: squareTopCorners ? 0 : radius,
            bottomLeading: radius,
            bottomTrailing: radius,
            topTrailing: squareTopCorners ? 0 : radius
        )
        return UnevenRoundedRectangle(
            cornerRadii: radii,
            style: .continuous
        )
        .inset(by: insetAmount)
        .path(in: rect)
    }

    func inset(by amount: CGFloat) -> CoveOverlayClipShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct CoveMinimalIslandView: View {
    let state: CoveState

    var body: some View {
        let snapshotAttentionCount = state.session.snapshots.filter {
            [.waitingApproval, .waitingInput, .blocked, .failed].contains(
                $0.status
            )
        }.count
        let attentionCount = max(
            snapshotAttentionCount,
            state.pendingDirectRequests.count
        )
        let activeCount = state.session.snapshots.filter {
            [.working, .active, .compacting].contains($0.status)
        }.count
        HStack(spacing: 7) {
            ForEach(Array(statuses.prefix(1).enumerated()), id: \.offset) {
                _, status in
                Circle()
                    .fill(Color(hex: state.theme.statusHex(status)))
                    .frame(width: 7, height: 7)
            }
            Color.clear
                .frame(width: 64, height: 1)
                .accessibilityHidden(true)
            if attentionCount > 0 {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(
                        Color(
                            hex: state.theme.waitingApprovalHex
                        )
                    )
            } else {
                Color.clear
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            attentionCount > 0
                ? "\(attentionCount) Codex tasks need attention"
                : "\(activeCount) active Codex tasks"
        )
        .accessibilityHint("Restore the full island from the menu bar")
    }

    private var statuses: [CoveSessionStatus] {
        CoveSessionVisualCuePolicy.distinctVisibleStatuses(
            in: state.session.snapshots
        )
    }
}

struct CoveBackdropView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let theme: CoveThemePalette
    let opacity: Double
    let blur: CoveBlurStyle
    let privacy: CovePrivacyMode
    var squareTopCorners = false

    var body: some View {
        let suppressVisualEffects = privacy.suppressVisualEffects || reduceTransparency
        let baseOpacity = suppressVisualEffects ? 1.0 : min(1, max(0.35, opacity))
        let accent = Color(hex: theme.accentHex)
        let background = Color(hex: theme.backgroundHex, opacity: baseOpacity)
        ZStack {
            // Material belongs behind the palette tint. Drawing it after the
            // tint lets the system material wash the selected theme toward
            // gray, especially at lower expanded opacities.
            if !suppressVisualEffects {
                materialLayer
            }
            LinearGradient(
                colors: [
                    background,
                    accent.opacity(suppressVisualEffects ? 0.12 : 0.20),
                    background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if theme.noiseOpacity > 0, !suppressVisualEffects {
                Canvas { context, size in
                    let dot = Color(hex: theme.foregroundHex)
                        .opacity(min(0.4, theme.noiseOpacity))
                    for x in stride(from: 2.0, through: size.width, by: 8.0) {
                        for y in stride(from: 2.0, through: size.height, by: 8.0) {
                            context.fill(
                                Path(
                                    ellipseIn: CGRect(
                                        x: x,
                                        y: y,
                                        width: 0.7,
                                        height: 0.7
                                    )
                                ),
                                with: .color(dot)
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            CoveOverlayClipShape(
                cornerRadius: theme.cornerRadius,
                squareTopCorners: squareTopCorners
            )
                .strokeBorder(
                    Color(hex: theme.borderHex)
                        .opacity(suppressVisualEffects ? 0.55 : 1),
                    style: StrokeStyle(
                        lineWidth: theme.borderStyle == .none
                            ? 0
                            : max(theme.borderWidth, contrast == .increased ? 2 : 0),
                        dash: theme.borderStyle == .dashed ? [6, 4] : []
                    )
                )
        }
        .background(Color(hex: theme.surfaceHex, opacity: baseOpacity))
        .clipShape(
            CoveOverlayClipShape(
                cornerRadius: theme.cornerRadius,
                squareTopCorners: squareTopCorners
            )
        )
        .shadow(
            color: Color(hex: theme.shadowHex)
                .opacity(suppressVisualEffects ? 0 : theme.shadowOpacity),
            radius: suppressVisualEffects ? 0 : theme.shadowBlur,
            x: theme.shadowX,
            y: theme.shadowY
        )
    }

    @ViewBuilder
    private var materialLayer: some View {
        switch blur {
        case .off:
            EmptyView()
        case .thin:
            Rectangle().fill(.ultraThinMaterial).opacity(0.65)
        case .regular:
            Rectangle().fill(.thinMaterial).opacity(0.82)
        case .thick:
            Rectangle().fill(.regularMaterial)
        }
    }
}

struct CoveExpandedCardView: View {
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var presentationMetrics: CoveOverlayPresentationMetrics

    let state: CoveState
    let redactsSensitiveContent: Bool
    let onOpenSettings: @MainActor () -> Void
    let onRestoreArchived: @MainActor (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let warning = store.persistenceWarning {
                        Label(
                            redactsSensitiveContent
                                ? "Settings could not be loaded. Persistence is disabled."
                                : warning,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .coveThemeFont(
                            state.theme,
                            size: 11,
                            weight: .medium
                        )
                        .foregroundStyle(
                            Color(hex: state.theme.failedHex)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(
                                cornerRadius: max(
                                    4,
                                    state.theme.cornerRadius * 0.5
                                ),
                                style: .continuous
                            )
                            .fill(
                                Color(hex: state.theme.failedHex).opacity(0.12)
                            )
                        )
                    }

                    CoveSessionListView(
                        snapshots: state.session.snapshots,
                        theme: state.theme,
                        redactsSensitiveContent: redactsSensitiveContent
                    )
                    .environmentObject(store)

                    if !state.pendingDirectRequests.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                state.pendingDirectRequests.count == 1
                                    ? "Codex needs attention"
                                    : "\(state.pendingDirectRequests.count) Codex requests need attention",
                                systemImage: "exclamationmark.bubble.fill"
                            )
                            .coveThemeFont(
                                state.theme,
                                size: 12,
                                weight: .semibold
                            )
                            .foregroundStyle(
                                Color(hex: state.theme.waitingApprovalHex)
                            )

                            ForEach(
                                state.pendingDirectRequests,
                                id: \.key
                            ) { request in
                                CoveDirectRequestSummaryView(
                                    request: request,
                                    theme: state.theme,
                                    redactsSensitiveContent: redactsSensitiveContent
                                )
                                .environmentObject(store)
                                .id(request.key)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(
                                cornerRadius: max(
                                    5,
                                    state.theme.cornerRadius * 0.55
                                ),
                                style: .continuous
                            )
                            .stroke(
                                Color(hex: state.theme.waitingApprovalHex),
                                lineWidth: 1.5
                            )
                        )
                    }

                    if state.settings.showProfileTokenUsage {
                        CoveProfileTokenUsageView(
                            usage: state.usage,
                            theme: state.theme
                        )
                    }

                    if state.settings.showUsage {
                        CoveUsageSummaryView(
                            usage: state.usage,
                            theme: state.theme,
                            showsRemaining: state.settings.usageShowsRemaining
                        )
                    }

                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)

            Divider()
                .overlay(
                    Color(hex: state.theme.borderHex).opacity(0.55)
                )

            footer
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .padding(
            .top,
            max(18, presentationMetrics.topContentInset + 8)
        )
        .foregroundStyle(Color(hex: state.theme.foregroundHex))
        .accessibilityLabel("Codex Cove sessions and actions")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onOpenSettings) {
                Label("Settings…", systemImage: "gearshape.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: state.theme.accentHex))

            if !state.dismissedSessionIDs.isEmpty {
                Menu {
                    ForEach(
                        Array(state.dismissedSessionIDs.enumerated()),
                        id: \.element
                    ) { index, sessionID in
                        Button("Restore archived task \(index + 1)") {
                            onRestoreArchived(sessionID)
                        }
                    }
                    Divider()
                    Button("Restore all archived tasks") {
                        onRestoreArchived(nil)
                    }
                } label: {
                    Label(
                        "Archived (\(state.dismissedSessionIDs.count))",
                        systemImage: "archivebox"
                    )
                }
                .menuStyle(.borderlessButton)
            }

            Spacer()

            Button {
                store.dispatch(.setExpanded(false))
            } label: {
                Label("Collapse", systemImage: "chevron.up")
            }
            .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex Cove settings actions")
    }

}

struct CoveSessionListView: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var showCompleted = true
    @State private var showSubagents = true
    @State private var expandedParents = Set<String>()

    let snapshots: [CoveSessionSnapshot]
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .coveThemeFont(theme, size: 12, weight: .semibold)
                Spacer()
                Button {
                    store.selectAdjacentSession(offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: [.command])
                .help("Select previous session (Command-[)")
                Button {
                    store.selectAdjacentSession(offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("]", modifiers: [.command])
                .help("Select next session (Command-])")
                Button {
                    store.openSelectedSession()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Open selected session (Command-Return)")
                Menu {
                    Toggle("Show completed", isOn: $showCompleted)
                    Toggle("Show subagents", isOn: $showSubagents)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            TextField("Search sessions", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .coveThemeFont(theme, size: 11, weight: .regular)

            if roots.isEmpty {
                Text(searchText.isEmpty ? "No Codex sessions yet." : "No matching sessions.")
                    .coveThemeFont(theme, size: 11, weight: .regular)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(roots, id: \.snapshotId) { snapshot in
                            sessionRow(snapshot, isChild: false)
                            let nested = children(of: snapshot)
                            if showSubagents, !nested.isEmpty {
                                Button {
                                    if expandedParents.contains(snapshot.snapshotId) {
                                        expandedParents.remove(snapshot.snapshotId)
                                    } else {
                                        expandedParents.insert(snapshot.snapshotId)
                                    }
                                } label: {
                                    Label(
                                        "\(nested.count) subagent\(nested.count == 1 ? "" : "s")",
                                        systemImage: expandedParents.contains(snapshot.snapshotId)
                                            ? "chevron.down"
                                            : "chevron.right"
                                    )
                                    .coveThemeFont(theme, size: 9, weight: .semibold)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color(hex: theme.mutedTextHex))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 18)

                                if expandedParents.contains(snapshot.snapshotId) {
                                    ForEach(nested, id: \.snapshotId) { child in
                                        sessionRow(child, isChild: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
                .scrollIndicators(.automatic)
            }
        }
    }

    private var filtered: [CoveSessionSnapshot] {
        snapshots.filter { snapshot in
            let completionAllowed = showCompleted
                || ![.completed, .idle, .interrupted].contains(snapshot.status)
            guard completionAllowed else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let haystack = [
                snapshot.title,
                snapshot.detail ?? "",
                snapshot.source?.displayName ?? "",
                snapshot.hostId ?? "",
            ].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private var roots: [CoveSessionSnapshot] {
        let identifiers = Set(filtered.compactMap(\.sessionId))
        return filtered.filter {
            $0.parentSessionId == nil || !identifiers.contains($0.parentSessionId ?? "")
        }
    }

    private func children(of parent: CoveSessionSnapshot) -> [CoveSessionSnapshot] {
        guard let parentID = parent.sessionId else { return [] }
        return filtered.filter { $0.parentSessionId == parentID }
    }

    private func sessionRow(
        _ snapshot: CoveSessionSnapshot,
        isChild: Bool
    ) -> some View {
        Button {
            store.open(snapshot)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                CovePixelCharacterRowAvatar(
                    character: CovePixelCharacter.assigned(
                        to: snapshot.sessionId ?? snapshot.snapshotId,
                        set: store.state.settings.residentSet
                    ),
                    status: snapshot.status,
                    theme: theme,
                    reduceMotion: reduceMotion,
                    size: 34
                )
                .frame(width: 34, height: 34, alignment: .top)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if store.state.pinnedSessionIDs.contains(
                            snapshot.sessionId ?? snapshot.snapshotId
                        ) {
                            Image(systemName: "pin.fill")
                                .coveThemeFont(theme, size: 8, weight: .semibold)
                                .foregroundStyle(Color(hex: theme.accentHex))
                                .accessibilityLabel("Pinned")
                        }
                        Text(redactsSensitiveContent ? "Codex session" : snapshot.title)
                            .coveThemeFont(theme, size: 11, weight: .semibold)
                            .lineLimit(1)
                        if snapshot.unread {
                            Circle()
                                .fill(statusColor(snapshot.status))
                                .frame(width: 6, height: 6)
                                .accessibilityLabel("Unread")
                        }
                    }
                    Text(
                        redactsSensitiveContent
                            ? "Details redacted"
                            : [
                                snapshot.status.displayName,
                                snapshot.source?.displayName,
                                snapshot.hostId,
                                snapshot.detail,
                            ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .coveThemeFont(theme, size: 9, weight: .medium)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
                    .lineLimit(2)
                    if store.state.settings.showTokenMetrics {
                        tokenMetricsView(for: snapshot)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .coveThemeFont(theme, size: 9, weight: .semibold)
                    .foregroundStyle(Color(hex: theme.accentHex))
            }
            .padding(9)
            .background(
                RoundedRectangle(
                    cornerRadius: max(4, theme.cornerRadius * 0.46),
                    style: .continuous
                )
                    .fill(
                        store.selectedSessionID
                            == (snapshot.sessionId ?? snapshot.snapshotId)
                            ? Color(hex: theme.accentHex).opacity(0.2)
                            : Color(hex: theme.surfaceHex).opacity(0.7)
                    )
            )
            .padding(.leading, isChild ? 18 : 0)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(
                store.state.pinnedSessionIDs.contains(
                    snapshot.sessionId ?? snapshot.snapshotId
                ) ? "Unpin" : "Pin"
            ) {
                store.togglePinned(snapshot)
            }
            if store.reminders[snapshot.sessionId ?? snapshot.snapshotId] == nil {
                Button("Remind me once") {
                    store.scheduleFollowUp(snapshot)
                }
            } else {
                Button("Cancel follow-up reminder") {
                    store.cancelFollowUp(snapshot)
                }
            }
            if snapshot.unread {
                Button("Mark read") {
                    store.markRead(snapshot)
                }
            }
            Button("Dismiss") {
                store.dismiss(snapshot)
            }
        }
        .accessibilityLabel(
            "\(snapshot.status.displayName), \(redactsSensitiveContent ? "Codex session" : snapshot.title)"
        )
        .accessibilityHint("Opens the originating Codex location")
    }

    private func statusColor(_ status: CoveSessionStatus) -> Color {
        Color(hex: theme.statusHex(status))
    }

    @ViewBuilder
    private func tokenMetricsView(
        for snapshot: CoveSessionSnapshot
    ) -> some View {
        if let metrics = store.state.sessionTokenMetrics[
            snapshot.scopedSessionKey
        ] {
            let isStale = metrics.isStale()
            let values = [
                metrics.totalTokens.map { "\($0) total" },
                metrics.inputTokens.map { "\($0) in" },
                metrics.outputTokens.map { "\($0) out" },
                metrics.reasoningOutputTokens.map { "\($0) reasoning" },
            ].compactMap { $0 }
            Label(
                isStale
                    ? "Stale · \(values.isEmpty ? "partial official metrics" : values.joined(separator: " · "))"
                    : values.isEmpty
                    ? "Official token metrics partial"
                    : values.joined(separator: " · "),
                systemImage: isStale
                    ? "clock.badge.exclamationmark"
                    : "number.circle"
            )
            .coveThemeFont(theme, size: 8, weight: .medium)
            .foregroundStyle(
                isStale
                    ? Color(hex: theme.waitingApprovalHex)
                    : Color(hex: theme.mutedTextHex)
            )
            .accessibilityLabel(
                isStale ? "Stale official token metrics" : "Official token metrics"
            )
        } else {
            Label("Token metrics unavailable", systemImage: "number.circle")
                .coveThemeFont(theme, size: 8, weight: .medium)
                .foregroundStyle(Color(hex: theme.mutedTextHex))
        }
    }

}

struct CoveUsageSummaryView: View {
    let usage: CoveUsageSnapshot?
    let theme: CoveThemePalette
    let showsRemaining: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("Usage")
                        .coveThemeFont(theme, size: 11, weight: .semibold)
                    Spacer()
                    if let usage {
                        if usage.isStale(at: context.date) {
                            Label("Stale", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(
                                    Color(hex: theme.waitingApprovalHex)
                                )
                        } else if usage.isPartial {
                            Text("Partial data")
                                .foregroundStyle(Color(hex: theme.mutedTextHex))
                        }
                        Text(dataAge(for: usage, now: context.date))
                            .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.62))
                    }
                }
                .coveThemeFont(theme, size: 9, weight: .medium)

                if let usage {
                    HStack(spacing: 10) {
                        windowView(title: "Primary", window: usage.primary, now: context.date)
                        windowView(title: "Secondary", window: usage.secondary, now: context.date)
                    }
                    resetCreditView(usage, now: context.date)
                } else {
                    Label("Usage unavailable", systemImage: "chart.bar.xaxis")
                        .coveThemeFont(theme, size: 10, weight: .medium)
                        .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.68))
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(
                    cornerRadius: max(4, theme.cornerRadius * 0.5),
                    style: .continuous
                )
                .fill(Color(hex: theme.surfaceHex).opacity(0.7))
            )
        }
    }

    @ViewBuilder
    private func resetCreditView(_ usage: CoveUsageSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Reset cards", systemImage: "arrow.clockwise.circle")
                Spacer()
                if let count = usage.resetCreditsAvailable {
                    Text("\(count) available")
                        .monospacedDigit()
                } else {
                    Text("Count unavailable")
                }
            }
            .coveThemeFont(theme, size: 9, weight: .semibold)

            if let credits = usage.resetCredits {
                if credits.isEmpty {
                    Text("No reset-card inventory returned")
                        .foregroundStyle(Color(hex: theme.mutedTextHex))
                } else {
                    ForEach(Array(credits.prefix(2).enumerated()), id: \.offset) { _, credit in
                        HStack {
                            Text(credit.title ?? credit.resetType ?? "Reset card")
                                .lineLimit(1)
                            Spacer()
                            Text(creditExpiry(credit, now: now))
                        }
                    }
                }
            } else {
                Text("Inventory details unavailable")
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
            }
        }
        .coveThemeFont(theme, size: 8)
        .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.72))
    }

    private func creditExpiry(_ credit: CoveRateLimitResetCredit, now: Date) -> String {
        guard let expiresAt = credit.expiresAt else {
            return credit.status?.capitalized ?? "Expiry unavailable"
        }
        let seconds = Int(expiresAt.timeIntervalSince(now))
        guard seconds > 0 else { return "Expired" }
        if seconds >= 86_400 {
            return "Expires in \(seconds / 86_400)d"
        }
        if seconds >= 3_600 {
            return "Expires in \(seconds / 3_600)h"
        }
        return "Expires in \(max(1, seconds / 60))m"
    }

    private func windowView(
        title: String,
        window: CoveRateLimitWindow?,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let window {
                HStack {
                    Text(title)
                    Spacer()
                    Text(
                        showsRemaining
                            ? "\(window.remainingPercent)% remaining"
                            : "\(window.usedPercent)% used"
                    )
                }
                .coveThemeFont(theme, size: 9, weight: .semibold)
                ProgressView(
                    value: Double(showsRemaining ? window.remainingPercent : window.usedPercent),
                    total: 100
                )
                    .tint(Color(hex: theme.accentHex))
                Text(resetCountdown(for: window, now: now))
                    .coveThemeFont(theme, size: 8, weight: .medium)
                    .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.58))
            } else {
                Text("\(title) unavailable")
                    .coveThemeFont(theme, size: 9, weight: .semibold)
                    .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.68))
                ProgressView(value: 0, total: 100)
                    .opacity(0.28)
                Text("Reset unavailable")
                    .coveThemeFont(theme, size: 8, weight: .medium)
                    .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetCountdown(for window: CoveRateLimitWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else {
            return "Reset unavailable"
        }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else {
            return "Reset due"
        }
        if seconds >= 86_400 {
            return "Resets in \(seconds / 86_400)d \((seconds % 86_400) / 3_600)h"
        }
        if seconds >= 3_600 {
            return "Resets in \(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
        return "Resets in \(max(1, seconds / 60))m"
    }

    private func dataAge(for usage: CoveUsageSnapshot, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(usage.capturedAt)))
        if seconds < 60 {
            return "Updated now"
        }
        if seconds < 3_600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "Updated \(seconds / 3_600)h ago"
        }
        return "Updated \(seconds / 86_400)d ago"
    }
}

struct CoveDirectRequestSummaryView: View {
    @EnvironmentObject private var store: CoveStore
    @State private var freeformAnswer = ""
    @State private var questionAnswers: [String: String] = [:]

    let request: CoveDirectRequest
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: redactsSensitiveContent ? "eye.slash" : iconName)
                    .foregroundStyle(Color(hex: theme.accentHex))
                Text(title)
                    .coveThemeFont(theme, size: 12, weight: .semibold)
                Spacer()
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(detail)
                .coveThemeFont(theme, size: 11, weight: .regular)
                .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.74))

            if case let .planSnapshot(plan) = request {
                planPreview(plan)
            }

            if supportsDirectResponse {
                if case let .question(questionRequest) = request,
                   questionRequest.questions.count > 1
                {
                    multiQuestionForm(questionRequest)
                } else {
                    if !choices.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(choices, id: \.identifier) { choice in
                                Button(choice.label) {
                                    store.respond(to: request, with: choice)
                                }
                                .buttonStyle(.bordered)
                                .tint(Color(hex: theme.accentHex))
                                .disabled(isSending)
                            }
                        }
                    }

                    if case let .question(question) = request, question.allowsFreeform {
                        HStack(spacing: 8) {
                            TextField("Type a response", text: $freeformAnswer)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    submitFreeform(question)
                                }
                            Button("Send") {
                                submitFreeform(question)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: theme.accentHex))
                            .disabled(
                                isSending
                                    || freeformAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                }
            } else {
                Button {
                    store.openInCodex(for: request)
                } label: {
                    Label("Open in Codex", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: theme.accentHex))
                Text(fallbackDetail)
                    .coveThemeFont(theme, size: 9, weight: .medium)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
            }

            if let errorMessage = store.decisionDelivery.errorMessage(
                for: request.key
            ) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .coveThemeFont(theme, size: 10, weight: .medium)
                    .foregroundStyle(Color(hex: theme.failedHex))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(
                cornerRadius: max(4, theme.cornerRadius * 0.58),
                style: .continuous
            )
            .fill(Color(hex: theme.surfaceHex).opacity(0.72))
        )
        .onChange(of: request.key) {
            freeformAnswer = ""
            questionAnswers = [:]
        }
    }

    private var title: String {
        if redactsSensitiveContent {
            return "Codex needs attention"
        }
        switch request {
        case let .approval(value):
            return value.title
        case let .question(value):
            if value.questions.count == 1 {
                return value.question
            }
            return "Codex has \(value.questions.count) questions"
        case let .planSnapshot(value):
            return value.title
        }
    }

    private var detail: String {
        if redactsSensitiveContent {
            switch request {
            case .approval:
                return "Approval details redacted by Privacy Mode."
            case .question:
                return "Question details redacted by Privacy Mode."
            case .planSnapshot:
                return "Plan details redacted by Privacy Mode."
            }
        }
        switch request {
        case let .approval(value):
            return value.detail ?? value.category.rawValue.capitalized
        case let .question(value):
            if value.questions.count > 1 {
                return "Answer every question, then send one response"
            }
            return value.allowsFreeform ? "Freeform answer allowed" : "Choose one option"
        case let .planSnapshot(value):
            return "\(value.steps.count) steps"
        }
    }

    private var choices: [CoveChoice] {
        switch request {
        case let .approval(value):
            return value.choices
        case let .question(value):
            return value.options
        case .planSnapshot:
            return []
        }
    }

    private var supportsDirectResponse: Bool {
        guard !redactsSensitiveContent, request.decisionSocket?.isEmpty == false else {
            return false
        }
        switch request {
        case let .approval(approval):
            return !approval.choices.isEmpty
        case let .question(question):
            return !question.questions.isEmpty
                && question.questions.allSatisfy {
                    !$0.options.isEmpty || $0.allowsFreeform
                }
        case .planSnapshot:
            return false
        }
    }

    private var fallbackDetail: String {
        switch request {
        case let .approval(approval) where approval.decisionSocket?.isEmpty != false:
            return "No public hook decision channel was exposed. Answer in Codex."
        case .approval:
            return "This approval shape is not supported by Cove. Answer in Codex."
        case .question:
            return "Desktop input is handled in Codex so every field and validation rule stays intact."
        case .planSnapshot:
            return "Plan feedback stays in Codex."
        }
    }

    private var isSending: Bool {
        store.decisionDelivery.isSending(request.key)
    }

    private var iconName: String {
        switch request {
        case .approval:
            return "checkmark.shield"
        case .question:
            return "questionmark.bubble"
        case .planSnapshot:
            return "list.bullet.clipboard"
        }
    }

    @ViewBuilder
    private func planPreview(_ plan: CovePlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(plan.steps.prefix(4).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .coveThemeFont(theme, size: 9, weight: .bold)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color(hex: theme.accentHex).opacity(0.18)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(redactsSensitiveContent ? "Plan step redacted" : step.title)
                            .coveThemeFont(theme, size: 10, weight: .semibold)
                            .lineLimit(1)
                        Text(step.status.capitalized)
                            .coveThemeFont(theme, size: 9, weight: .medium)
                            .foregroundStyle(Color(hex: theme.foregroundHex).opacity(0.62))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func multiQuestionForm(_ request: CoveQuestionRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(request.questions.enumerated()), id: \.element.questionId) { index, question in
                VStack(alignment: .leading, spacing: 7) {
                    if let header = question.header, !header.isEmpty {
                        Text(header)
                            .coveThemeFont(theme, size: 10, weight: .bold)
                            .foregroundStyle(Color(hex: theme.accentHex))
                    }
                    Text(question.question)
                        .coveThemeFont(theme, size: 11, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.options.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(question.options, id: \.identifier) { choice in
                                let answer = questionAnswer(for: choice)
                                Button {
                                    questionAnswers[question.questionId] = answer
                                } label: {
                                    Label(
                                        choice.label,
                                        systemImage: questionAnswers[question.questionId] == answer
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(Color(hex: theme.accentHex))
                                .disabled(isSending)
                            }
                        }
                    }

                    if question.allowsFreeform {
                        TextField(
                            "Type a response",
                            text: answerBinding(for: question.questionId)
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSending)
                    }
                }

                if index < request.questions.count - 1 {
                    Divider()
                        .overlay(Color(hex: theme.foregroundHex).opacity(0.12))
                }
            }

            Button {
                submitQuestions(request)
            } label: {
                Label("Send answers", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: theme.accentHex))
            .disabled(isSending || !hasEveryAnswer(for: request))
        }
    }

    private func answerBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { questionAnswers[questionId] ?? "" },
            set: { questionAnswers[questionId] = $0 }
        )
    }

    private func hasEveryAnswer(for request: CoveQuestionRequest) -> Bool {
        request.questions.allSatisfy { question in
            guard let answer = questionAnswers[question.questionId],
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return false
            }
            if question.allowsFreeform {
                return true
            }
            return question.options.contains {
                questionAnswer(for: $0) == answer
            }
        }
    }

    private func questionAnswer(for choice: CoveChoice) -> String {
        if let rawString = choice.raw?.stringValue {
            return rawString
        }
        let raw = choice.raw?.objectValue
        return raw?["value"]?.stringValue
            ?? raw?["label"]?.stringValue
            ?? choice.label
    }

    private func submitQuestions(_ request: CoveQuestionRequest) {
        var answers: [String: [String]] = [:]
        for question in request.questions {
            if let answer = questionAnswers[question.questionId] {
                answers[question.questionId] = [answer]
            }
        }
        store.respond(to: request, answers: answers)
    }

    private func submitFreeform(_ question: CoveQuestionRequest) {
        store.respondFreeform(freeformAnswer, to: question)
    }
}

extension CoveThemePalette {
    func statusHex(_ status: CoveSessionStatus) -> String {
        switch status {
        case .waitingApproval, .blocked:
            waitingApprovalHex
        case .waitingInput:
            waitingInputHex
        case .completed:
            completedHex
        case .failed:
            failedHex
        case .interrupted:
            interruptedHex
        case .compacting:
            compactingHex
        case .working, .active:
            workingHex
        case .idle, .listening, .quiet, .hidden:
            idleHex
        }
    }

    func coveFont(
        size: Double,
        weight: Font.Weight? = nil,
        textScale: Double = CoveSettings.defaultTextScale
    ) -> Font {
        let resolvedSize = max(
            CoveSemanticTypography.informativeTextFloor,
            size * max(0, fontSizeScale)
        ) * CoveSettings.validatedTextScale(textScale)
        return Font.custom(
            fontName,
            size: resolvedSize
        )
        .weight(weight ?? coveFontWeight)
    }

    var coveFontWeight: Font.Weight {
        switch fontWeight {
        case .light:
            .light
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        }
    }

    var coveAnimation: Animation {
        let duration = max(0, animationDurationMilliseconds) / 1_000
        switch animationEasing {
        case .linear:
            return Animation.linear(duration: duration)
        case .easeIn:
            return Animation.easeIn(duration: duration)
        case .easeOut:
            return Animation.easeOut(duration: duration)
        case .easeInOut:
            return Animation.easeInOut(duration: duration)
        case .spring:
            return Animation.spring(
                response: max(0.12, duration),
                dampingFraction: 0.82
            )
        }
    }
}
