import CoveCore

/// The transient surface currently presented by Cove's single overlay panel.
///
/// Presentation is deliberately app-local. It is never encoded or written to
/// Cove's settings store; `CoveSessionState.isExpanded` remains only a legacy
/// compatibility signal for core behavior while the app migrates to this
/// three-state model.
enum CoveOverlayPresentation: Equatable, Sendable {
    case collapsed
    case queue
    case focused(CoveFocusTarget)

    var isExpanded: Bool {
        self != .collapsed
    }

    var focusTarget: CoveFocusTarget? {
        guard case let .focused(target) = self else { return nil }
        return target
    }
}

/// Stable identity for content shown in the focused action surface.
enum CoveFocusTarget: Equatable, Hashable, Sendable {
    case directRequest(CoveDirectRequestKey)
    case session(String)
}

/// Pure navigation rules for the overlay's forward and Escape/back paths.
enum CoveOverlayPresentationPolicy {
    /// Advances toward the queue or a supplied focus target.
    ///
    /// Supplying a target is an explicit request to focus it, regardless of the
    /// current surface. Without one, only the collapsed surface advances.
    static func forward(
        from presentation: CoveOverlayPresentation,
        focusing target: CoveFocusTarget? = nil
    ) -> CoveOverlayPresentation {
        if let target {
            return .focused(target)
        }
        switch presentation {
        case .collapsed:
            return .queue
        case .queue, .focused:
            return presentation
        }
    }

    /// Implements the locked Escape sequence: focused -> queue -> collapsed.
    static func back(
        from presentation: CoveOverlayPresentation
    ) -> CoveOverlayPresentation {
        switch presentation {
        case .focused:
            return .queue
        case .queue:
            return .collapsed
        case .collapsed:
            return .collapsed
        }
    }
}
