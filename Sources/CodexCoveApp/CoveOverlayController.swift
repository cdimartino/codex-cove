import AppKit
import Combine
import QuartzCore
import SwiftUI
import CoveCore

@MainActor
final class CoveOverlayController: NSObject, NSWindowDelegate {
    private var panel: CoveOverlayPanel?
    private var visualEffectView: NSVisualEffectView?
    private weak var store: CoveStore?
    private var pendingState: CoveState?
    private var pendingPresentation: CoveOverlayPresentation?
    private var updateScheduled = false
    private var lastAppliedState: CoveState?
    private var lastAppliedPresentation: CoveOverlayPresentation?
    private var lastTargetFrame: NSRect?
    private var animationGeneration = 0
    private var hasEverBeenShown = false
    private var isManuallyHidden = false
    private var hideInProgress = false
    private var presentationCancellable: AnyCancellable?
    private let presentationMetrics = CoveOverlayPresentationMetrics()

    func attach(
        store: CoveStore,
        onOpenSettings: @escaping @MainActor () -> Void,
        onRestoreArchived: @escaping @MainActor (String?) -> Void,
        fixtureStateDirectory: String? = nil
    ) {
        self.store = store
        if panel == nil {
            let rootView = CoveOverlayRootView(
                onOpenSettings: onOpenSettings,
                onRestoreArchived: onRestoreArchived,
                fixtureStateDirectory: fixtureStateDirectory
            )
                .environmentObject(store)
                .environmentObject(presentationMetrics)
            let hosting = NSHostingView(rootView: rootView)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            let contentView = NSView()
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            let effectView = NSVisualEffectView()
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.blendingMode = .behindWindow
            effectView.material = .hudWindow
            effectView.state = .active
            effectView.wantsLayer = true
            contentView.addSubview(effectView)
            contentView.addSubview(hosting)
            NSLayoutConstraint.activate([
                effectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                effectView.topAnchor.constraint(equalTo: contentView.topAnchor),
                effectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
            let overlayPanel = CoveOverlayPanel(
                contentRect: NSRect(x: 0, y: 0, width: 396, height: 112),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            overlayPanel.delegate = self
            overlayPanel.contentView = contentView
            overlayPanel.isReleasedWhenClosed = false
            overlayPanel.titleVisibility = NSWindow.TitleVisibility.hidden
            overlayPanel.titlebarAppearsTransparent = true
            overlayPanel.isOpaque = false
            overlayPanel.backgroundColor = NSColor.clear
            overlayPanel.hasShadow = true
            overlayPanel.hidesOnDeactivate = false
            overlayPanel.isMovable = false
            overlayPanel.isMovableByWindowBackground = false
            overlayPanel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary
            ]
            overlayPanel.level = NSWindow.Level.statusBar
            overlayPanel.onEscape = { [weak store] in
                _ = store?.requestPresentationBack()
            }
            visualEffectView = effectView
            panel = overlayPanel
            reposition()
        }
        presentationCancellable = store.$overlayPresentation
            .removeDuplicates()
            .sink { [weak self] presentation in
                self?.updatePresentation(presentation)
            }
    }

    func show() {
        guard let panel else { return }
        isManuallyHidden = false
        hideInProgress = false

        guard let state = store?.state,
              let screen = preferredScreen(for: panel)
        else {
            panel.orderFrontRegardless()
            hasEverBeenShown = true
            return
        }

        let presentation = store?.overlayPresentation ?? .collapsed
        let targetFrame = CovePanelSizing.frame(
            for: state,
            presentation: presentation,
            screen: screen
        )
        updatePresentationMetrics(for: screen)
        lastTargetFrame = targetFrame
        updateCornerRadius(for: state, presentation: presentation)
        animationGeneration += 1

        if !hasEverBeenShown || !animationsAreEnabled(for: state) {
            setFrameIfNeeded(targetFrame, on: panel, display: false)
            panel.orderFrontRegardless()
        } else if panel.isVisible {
            panel.orderFrontRegardless()
            animateFrameIfNeeded(targetFrame, on: panel, state: state)
        } else {
            setFrameIfNeeded(hiddenFrame(for: targetFrame), on: panel, display: false)
            panel.orderFrontRegardless()
            animateFrameIfNeeded(targetFrame, on: panel, state: state)
        }
        hasEverBeenShown = true
    }

    func toggleVisibility() {
        guard let panel, let state = store?.state else { return }
        if panel.isVisible && !hideInProgress {
            isManuallyHidden = true
            hide(panel: panel, state: state)
        } else {
            show()
        }
    }

    func update(with state: CoveState) {
        pendingState = state
        schedulePendingUpdate()
    }

    private func updatePresentation(
        _ presentation: CoveOverlayPresentation
    ) {
        pendingPresentation = presentation
        schedulePendingUpdate()
    }

    private func schedulePendingUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingUpdate()
        }
    }

    /// State and presentation publications are coalesced onto one main-loop
    /// turn so SwiftUI content and the NSPanel frame never show mismatched
    /// queue/focused geometry.
    private func applyPendingUpdate() {
        updateScheduled = false
        guard let panel, let store else { return }
        let state = pendingState ?? store.state
        let presentation = pendingPresentation ?? store.overlayPresentation
        pendingState = nil
        pendingPresentation = nil

        let previousState = lastAppliedState
        lastAppliedState = state
        lastAppliedPresentation = presentation
        applyVisualConfiguration(
            state,
            presentation: presentation,
            to: panel
        )

        guard state.session.isVisible else {
            hide(panel: panel, state: state)
            return
        }

        let becameVisible = previousState?.session.isVisible == false
        if becameVisible {
            isManuallyHidden = false
        }

        guard let screen = preferredScreen(for: panel) else { return }
        updatePresentationMetrics(for: screen)
        let targetFrame = CovePanelSizing.frame(
            for: state,
            presentation: presentation,
            screen: screen
        )
        lastTargetFrame = targetFrame
        updateCornerRadius(for: state, presentation: presentation)

        if isManuallyHidden {
            // Menu-bar hiding is independent of reducer visibility. Let its
            // upward transition finish and do not let unrelated session or
            // usage updates resurrect the panel.
            if !panel.isVisible {
                setFrameIfNeeded(targetFrame, on: panel, display: false)
            }
            return
        }

        hideInProgress = false
        if panel.isVisible {
            animateFrameIfNeeded(targetFrame, on: panel, state: state)
        } else if becameVisible && !isManuallyHidden {
            reveal(panel: panel, targetFrame: targetFrame, state: state)
        } else {
            // Keep the hidden window ready on the correct display without
            // resurrecting a menu-bar-hidden panel on unrelated state churn.
            setFrameIfNeeded(targetFrame, on: panel, display: false)
        }

        if pendingState != nil || pendingPresentation != nil {
            schedulePendingUpdate()
        }
    }

    private func applyVisualConfiguration(
        _ state: CoveState,
        presentation: CoveOverlayPresentation,
        to panel: CoveOverlayPanel
    ) {
        if panel.hasShadow != presentation.isExpanded {
            panel.hasShadow = presentation.isExpanded
        }
        // SwiftUI applies the configured alpha to background surfaces. Keep
        // the panel itself opaque so text and controls remain legible and the
        // requested percentage is not multiplied twice.
        if panel.alphaValue != 1 {
            panel.alphaValue = 1
        }
        let hidesVisualEffect = state.settings.minimalIslandMode
            || state.settings.blurStyle == .off
            || state.settings.privacyMode == .on
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if visualEffectView?.state != .active {
            visualEffectView?.state = .active
        }
        if visualEffectView?.isHidden != hidesVisualEffect {
            visualEffectView?.isHidden = hidesVisualEffect
        }
        let material: NSVisualEffectView.Material = switch state.settings.blurStyle {
        case .off, .thin:
            .underWindowBackground
        case .regular:
            .hudWindow
        case .thick:
            .popover
        }
        if visualEffectView?.material != material {
            visualEffectView?.material = material
        }
        if visualEffectView?.layer?.masksToBounds != true {
            visualEffectView?.layer?.masksToBounds = true
        }
        if visualEffectView?.layer?.cornerCurve != .continuous {
            visualEffectView?.layer?.cornerCurve = .continuous
        }
        // Privacy redacts sensitive fields in SwiftUI; it must not disable
        // approval, question, hover, or jump interactions.
        if panel.ignoresMouseEvents {
            panel.ignoresMouseEvents = false
        }
    }

    private func reveal(
        panel: CoveOverlayPanel,
        targetFrame: NSRect,
        state: CoveState
    ) {
        animationGeneration += 1
        hideInProgress = false
        if animationsAreEnabled(for: state) {
            setFrameIfNeeded(
                hiddenFrame(for: targetFrame),
                on: panel,
                display: false
            )
        } else {
            setFrameIfNeeded(targetFrame, on: panel, display: false)
        }
        panel.orderFrontRegardless()
        hasEverBeenShown = true
        animateFrameIfNeeded(targetFrame, on: panel, state: state)
    }

    private func hide(panel: CoveOverlayPanel, state: CoveState) {
        guard panel.isVisible, !hideInProgress else { return }
        animationGeneration += 1
        let generation = animationGeneration
        let targetFrame = lastTargetFrame
            ?? preferredScreen(for: panel).map {
                CovePanelSizing.frame(
                    for: state,
                    presentation: store?.overlayPresentation ?? .collapsed,
                    screen: $0
                )
            }
            ?? panel.frame

        guard animationsAreEnabled(for: state) else {
            hideInProgress = false
            panel.orderOut(nil)
            setFrameIfNeeded(targetFrame, on: panel, display: false)
            return
        }

        let hiddenTarget = hiddenFrame(for: targetFrame)
        guard !framesAreEffectivelyEqual(panel.frame, hiddenTarget) else {
            hideInProgress = false
            panel.orderOut(nil)
            return
        }

        hideInProgress = true
        NSAnimationContext.runAnimationGroup { context in
            configure(context: context, for: state)
            panel.animator().setFrame(hiddenTarget, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self,
                      let panel,
                      self.animationGeneration == generation
                else { return }
                self.hideInProgress = false
                panel.orderOut(nil)
            }
        }
    }

    private func animateFrameIfNeeded(
        _ targetFrame: NSRect,
        on panel: CoveOverlayPanel,
        state: CoveState
    ) {
        guard !framesAreEffectivelyEqual(panel.frame, targetFrame) else { return }
        animationGeneration += 1
        guard animationsAreEnabled(for: state), panel.isVisible else {
            setFrameIfNeeded(targetFrame, on: panel, display: panel.isVisible)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            configure(context: context, for: state)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func configure(
        context: NSAnimationContext,
        for state: CoveState
    ) {
        context.duration = state.settings.panelAnimationDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
    }

    private func animationsAreEnabled(for state: CoveState) -> Bool {
        state.settings.panelAnimationEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func hiddenFrame(for targetFrame: NSRect) -> NSRect {
        // A one-point frame at the same screen-top edge makes the lower edge
        // travel upward on hide and downward on reveal. The panel never gains
        // a top margin and its width stays unchanged throughout the motion.
        NSRect(
            x: targetFrame.minX,
            y: targetFrame.maxY - 1,
            width: targetFrame.width,
            height: 1
        )
    }

    private func setFrameIfNeeded(
        _ frame: NSRect,
        on panel: CoveOverlayPanel,
        display: Bool
    ) {
        guard !framesAreEffectivelyEqual(panel.frame, frame) else { return }
        panel.setFrame(frame, display: display)
    }

    private func framesAreEffectivelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5
            && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func updateCornerRadius(
        for state: CoveState,
        presentation: CoveOverlayPresentation
    ) {
        let cornerRadius: CGFloat
        if state.settings.minimalIslandMode {
            cornerRadius = 12
        } else if presentation.isExpanded {
            cornerRadius = CGFloat(state.theme.cornerRadius)
        } else {
            cornerRadius = 16
        }
        if visualEffectView?.layer?.cornerRadius != cornerRadius {
            visualEffectView?.layer?.cornerRadius = cornerRadius
        }
        let roundsOnlyBottomCorners = state.settings.squareTopCorners
            && !state.settings.minimalIslandMode
        let maskedCorners: CACornerMask = roundsOnlyBottomCorners
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        if visualEffectView?.layer?.maskedCorners != maskedCorners {
            visualEffectView?.layer?.maskedCorners = maskedCorners
        }
    }

    private func preferredScreen(for panel: CoveOverlayPanel) -> NSScreen? {
        panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func reposition() {
        guard let panel, let screen = preferredScreen(for: panel), let store else { return }
        updatePresentationMetrics(for: screen)
        let presentation = store.overlayPresentation
        let frame = CovePanelSizing.frame(
            for: store.state,
            presentation: presentation,
            screen: screen
        )
        lastTargetFrame = frame
        updateCornerRadius(for: store.state, presentation: presentation)
        setFrameIfNeeded(frame, on: panel, display: false)
    }

    private func updatePresentationMetrics(for screen: NSScreen) {
        let menuBarInset = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        let obstructionWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea
        {
            obstructionWidth = max(
                0,
                screen.frame.width - left.width - right.width
            )
        } else {
            obstructionWidth = 0
        }
        presentationMetrics.set(
            topContentInset: menuBarInset,
            topObstructionWidth: obstructionWidth
        )
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store?.setOverlayFocused(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        store?.setOverlayFocused(false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        reposition()
    }

}

@MainActor
final class CoveOverlayPresentationMetrics: ObservableObject {
    @Published private(set) var topContentInset: CGFloat = 0
    @Published private(set) var topObstructionWidth: CGFloat = 0

    func set(topContentInset: CGFloat, topObstructionWidth: CGFloat) {
        let normalizedInset = max(0, topContentInset)
        let normalizedObstruction = max(0, topObstructionWidth)
        if abs(self.topContentInset - normalizedInset) >= 0.5 {
            self.topContentInset = normalizedInset
        }
        if abs(self.topObstructionWidth - normalizedObstruction) >= 0.5 {
            self.topObstructionWidth = normalizedObstruction
        }
    }
}

final class CoveOverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
