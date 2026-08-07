import AppKit
import CoreGraphics
import CoveCore

enum CovePanelSizing {
    static let queueSize = CGSize(width: 400, height: 520)
    static let focusedSize = CGSize(width: 520, height: 520)

    static func size(
        for state: CoveState,
        presentation: CoveOverlayPresentation,
        screen: NSScreen
    ) -> CGSize {
        let metrics = screenMetrics(for: screen)
        let menuBarInset = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        let requested: CGSize
        if state.settings.minimalIslandMode {
            requested = CGSize(width: 126, height: max(24, menuBarInset))
        } else {
            requested = switch presentation {
            case .collapsed:
                CGSize(
                    width: CoveSettings.validatedCollapsedWidth(
                        state.settings.collapsedWidth
                    ),
                    height: 0
                )
            case .queue:
                queueSize
            case .focused:
                focusedSize
            }
        }
        let resolvedWidth = CoveOverlayGeometry.resolvedWidth(
            screen: metrics,
            desiredWidth: requested.width
        )
        let resolvedHeight: Double
        if state.settings.minimalIslandMode {
            resolvedHeight = requested.height
        } else if presentation == .collapsed {
            resolvedHeight = CoveOverlayGeometry.collapsedHeight(
                forWidth: resolvedWidth,
                topContentInset: menuBarInset
            )
        } else {
            resolvedHeight = requested.height
        }
        return CGSize(width: resolvedWidth, height: resolvedHeight)
    }

    static func frame(
        for state: CoveState,
        presentation: CoveOverlayPresentation,
        screen: NSScreen
    ) -> NSRect {
        let size = size(
            for: state,
            presentation: presentation,
            screen: screen
        )
        let metrics = screenMetrics(for: screen)
        let layout = CoveOverlayGeometry.layout(
            screen: metrics,
            desiredWidth: size.width,
            desiredHeight: size.height,
            expanded: presentation.isExpanded
        )
        // GeometryResolver operates in screen-local coordinates. AppKit
        // windows use the global display coordinate space, which can include
        // negative X/Y origins for external displays.
        return NSRect(
            x: screen.frame.minX + layout.originX,
            y: screen.frame.minY + layout.originY,
            width: layout.width,
            height: layout.height
        )
    }

    /// Compatibility entry point for callers that have not yet adopted the
    /// transient presentation model. Overlay runtime code must use the
    /// explicit overload above so queue and focused widths cannot diverge.
    static func size(for state: CoveState, screen: NSScreen) -> CGSize {
        size(
            for: state,
            presentation: state.session.isExpanded ? .queue : .collapsed,
            screen: screen
        )
    }

    static func frame(for state: CoveState, screen: NSScreen) -> NSRect {
        frame(
            for: state,
            presentation: state.session.isExpanded ? .queue : .collapsed,
            screen: screen
        )
    }

    private static func screenMetrics(for screen: NSScreen) -> CoveScreenMetrics {
        CoveScreenMetrics(
            screenWidth: screen.frame.width,
            screenHeight: screen.frame.height,
            safeAreaTop: screen.safeAreaInsets.top,
            safeAreaLeft: screen.safeAreaInsets.left,
            safeAreaRight: screen.safeAreaInsets.right,
            auxiliaryTopLeftWidth: Double(screen.auxiliaryTopLeftArea?.width ?? 0),
            auxiliaryTopRightWidth: Double(screen.auxiliaryTopRightArea?.width ?? 0)
        )
    }
}
