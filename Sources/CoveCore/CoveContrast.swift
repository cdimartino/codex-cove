import Foundation

/// A device-independent sRGB color suitable for deterministic contrast tests.
public struct CoveSRGBColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1
    ) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Accepts RGB, RGBA, RRGGBB, and RRGGBBAA hexadecimal colors, with or
    /// without a leading `#`.
    public init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let expanded: String
        switch cleaned.count {
        case 3, 4:
            expanded = cleaned.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = cleaned
        default:
            return nil
        }
        guard expanded.allSatisfy(\.isHexDigit),
              let raw = UInt64(expanded, radix: 16)
        else {
            return nil
        }

        if expanded.count == 6 {
            self.init(
                red: Double((raw >> 16) & 0xff) / 255,
                green: Double((raw >> 8) & 0xff) / 255,
                blue: Double(raw & 0xff) / 255
            )
        } else {
            self.init(
                red: Double((raw >> 24) & 0xff) / 255,
                green: Double((raw >> 16) & 0xff) / 255,
                blue: Double((raw >> 8) & 0xff) / 255,
                alpha: Double(raw & 0xff) / 255
            )
        }
    }

    public static let black = Self(red: 0, green: 0, blue: 0)
    public static let white = Self(red: 1, green: 1, blue: 1)

    public func withAlpha(_ alpha: Double) -> Self {
        Self(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Alpha-composites this foreground color over a background color.
    public func composited(over background: Self) -> Self {
        let outputAlpha = alpha + background.alpha * (1 - alpha)
        guard outputAlpha > 0 else {
            return Self(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return Self(
            red: (red * alpha + background.red * background.alpha * (1 - alpha))
                / outputAlpha,
            green: (green * alpha + background.green * background.alpha * (1 - alpha))
                / outputAlpha,
            blue: (blue * alpha + background.blue * background.alpha * (1 - alpha))
                / outputAlpha,
            alpha: outputAlpha
        )
    }

    /// WCAG relative luminance for the sRGB channels. Resolve transparency
    /// with `composited(over:)` before using this value.
    public var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    public func contrastRatio(with other: Self) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

public enum CoveContrastRequirement: String, Codable, Sendable {
    case text
    case nonText

    public var minimumRatio: Double {
        switch self {
        case .text:
            return 4.5
        case .nonText:
            return 3
        }
    }
}

public enum CoveSemanticForegroundRole: String, CaseIterable, Codable, Sendable {
    case primaryText
    case mutedText
    case accentControl
    case border
    case focusRing
    case workingStatus
    case waitingApprovalStatus
    case waitingInputStatus
    case compactingStatus
    case completedStatus
    case failedStatus
    case interruptedStatus
    case idleStatus
}

public enum CoveSemanticBackgroundRole: String, CaseIterable, Codable, Sendable {
    case background
    case surface
}

public struct CoveSemanticContrastPair: Equatable, Sendable, Identifiable {
    public var foreground: CoveSemanticForegroundRole
    public var background: CoveSemanticBackgroundRole
    public var requirement: CoveContrastRequirement

    public init(
        foreground: CoveSemanticForegroundRole,
        background: CoveSemanticBackgroundRole,
        requirement: CoveContrastRequirement
    ) {
        self.foreground = foreground
        self.background = background
        self.requirement = requirement
    }

    public var id: String {
        "\(foreground.rawValue).on.\(background.rawValue)"
    }

    public static let overlay: [Self] = {
        var pairs: [Self] = []
        for background in CoveSemanticBackgroundRole.allCases {
            pairs.append(.init(
                foreground: .primaryText,
                background: background,
                requirement: .text
            ))
            pairs.append(.init(
                foreground: .mutedText,
                background: background,
                requirement: .text
            ))
            for foreground in CoveSemanticForegroundRole.allCases where
                foreground != .primaryText && foreground != .mutedText
            {
                pairs.append(.init(
                    foreground: foreground,
                    background: background,
                    requirement: .nonText
                ))
            }
        }
        return pairs
    }()
}

public enum CoveOverlayContrastPresentation: String, CaseIterable, Codable, Sendable {
    case collapsed
    case expanded

    public func themeOpacity(_ theme: CoveThemePalette) -> Double {
        switch self {
        case .collapsed:
            return theme.collapsedOpacity
        case .expanded:
            return theme.expandedOpacity
        }
    }
}

public enum CoveRepresentativeDesktopBackground: String, CaseIterable, Codable, Sendable {
    case light
    case dark

    public var color: CoveSRGBColor {
        switch self {
        case .light:
            return .white
        case .dark:
            return CoveSRGBColor(red: 0.12, green: 0.12, blue: 0.12)
        }
    }
}

public enum CoveContrastState: String, CaseIterable, Codable, Sendable {
    case normal
    case increased
}

/// One deterministic rendered-background condition in the contrast matrix.
/// `usesOpaqueSemanticBacking` models the permitted opaque backing surface;
/// material blur is intentionally absent from this contract.
public struct CoveThemeContrastContext: Equatable, Sendable, Identifiable {
    public var presentation: CoveOverlayContrastPresentation
    public var opacity: Double
    public var desktop: CoveRepresentativeDesktopBackground
    public var contrastState: CoveContrastState
    public var usesOpaqueSemanticBacking: Bool

    public init(
        presentation: CoveOverlayContrastPresentation,
        opacity: Double,
        desktop: CoveRepresentativeDesktopBackground,
        contrastState: CoveContrastState,
        usesOpaqueSemanticBacking: Bool = false
    ) {
        self.presentation = presentation
        self.opacity = min(1, max(0, opacity.isFinite ? opacity : 1))
        self.desktop = desktop
        self.contrastState = contrastState
        self.usesOpaqueSemanticBacking = usesOpaqueSemanticBacking
    }

    public var id: String {
        [
            presentation.rawValue,
            String(format: "%.3f", opacity),
            desktop.rawValue,
            contrastState.rawValue,
            usesOpaqueSemanticBacking ? "opaque" : "translucent",
        ].joined(separator: ".")
    }
}

public struct CoveThemeContrastResult: Equatable, Sendable, Identifiable {
    public var themeIdentifier: String
    public var context: CoveThemeContrastContext
    public var pair: CoveSemanticContrastPair
    public var ratio: Double

    public init(
        themeIdentifier: String,
        context: CoveThemeContrastContext,
        pair: CoveSemanticContrastPair,
        ratio: Double
    ) {
        self.themeIdentifier = themeIdentifier
        self.context = context
        self.pair = pair
        self.ratio = ratio
    }

    public var minimumRatio: Double { pair.requirement.minimumRatio }
    public var passes: Bool { ratio >= minimumRatio }
    public var id: String { "\(themeIdentifier).\(context.id).\(pair.id)" }
}

public enum CoveThemeContrastMatrix {
    /// The built-in theme defaults across both presentation states, desktop
    /// backgrounds, and normal/Increased Contrast states. Semantic content is
    /// backed by an opaque theme surface by default; callers may pass `false`
    /// to audit the unsafe material-only rendering path explicitly.
    public static func defaultContexts(
        for theme: CoveThemePalette,
        usesOpaqueSemanticBacking: Bool = true
    ) -> [CoveThemeContrastContext] {
        CoveOverlayContrastPresentation.allCases.flatMap { presentation in
            CoveRepresentativeDesktopBackground.allCases.flatMap { desktop in
                CoveContrastState.allCases.map { contrastState in
                    CoveThemeContrastContext(
                        presentation: presentation,
                        opacity: presentation.themeOpacity(theme),
                        desktop: desktop,
                        contrastState: contrastState,
                        usesOpaqueSemanticBacking: usesOpaqueSemanticBacking
                    )
                }
            }
        }
    }

    /// Covers the legal minimum and maximum alpha for both presentation
    /// states. This is the strict endpoint matrix used by release tests. Its
    /// default models the required opaque semantic content backing, not blur.
    public static func endpointContexts(
        opacityRange: ClosedRange<Double> = 0.35 ... 1,
        usesOpaqueSemanticBacking: Bool = true
    ) -> [CoveThemeContrastContext] {
        let endpoints = Array(Set([
            min(1, max(0, opacityRange.lowerBound)),
            min(1, max(0, opacityRange.upperBound)),
        ])).sorted()
        return CoveOverlayContrastPresentation.allCases.flatMap { presentation in
            endpoints.flatMap { opacity in
                CoveRepresentativeDesktopBackground.allCases.flatMap { desktop in
                    CoveContrastState.allCases.map { contrastState in
                        CoveThemeContrastContext(
                            presentation: presentation,
                            opacity: opacity,
                            desktop: desktop,
                            contrastState: contrastState,
                            usesOpaqueSemanticBacking: usesOpaqueSemanticBacking
                        )
                    }
                }
            }
        }
    }

    public static func evaluate(
        theme: CoveThemePalette,
        contexts: [CoveThemeContrastContext],
        pairs: [CoveSemanticContrastPair] = CoveSemanticContrastPair.overlay
    ) -> [CoveThemeContrastResult] {
        contexts.flatMap { context in
            pairs.compactMap { pair in
                // A theme with no border does not expose a border control.
                if pair.foreground == .border,
                   theme.borderStyle == .none || theme.borderWidth <= 0 {
                    return nil
                }
                guard let foreground = foregroundColor(
                    pair.foreground,
                    theme: theme
                ), let background = renderedBackgroundColor(
                    pair.background,
                    theme: theme,
                    context: context
                ) else {
                    return CoveThemeContrastResult(
                        themeIdentifier: theme.identifier,
                        context: context,
                        pair: pair,
                        ratio: 0
                    )
                }
                return CoveThemeContrastResult(
                    themeIdentifier: theme.identifier,
                    context: context,
                    pair: pair,
                    ratio: foreground.contrastRatio(with: background)
                )
            }
        }
    }

    public static func violations(
        theme: CoveThemePalette,
        contexts: [CoveThemeContrastContext],
        pairs: [CoveSemanticContrastPair] = CoveSemanticContrastPair.overlay
    ) -> [CoveThemeContrastResult] {
        evaluate(theme: theme, contexts: contexts, pairs: pairs)
            .filter { !$0.passes }
    }

    public static func violationsForBuiltInThemes(
        contexts: (CoveThemePalette) -> [CoveThemeContrastContext] = {
            defaultContexts(for: $0)
        },
        pairs: [CoveSemanticContrastPair] = CoveSemanticContrastPair.overlay
    ) -> [CoveThemeContrastResult] {
        CoveThemeCatalog.palettes.flatMap { theme in
            violations(theme: theme, contexts: contexts(theme), pairs: pairs)
        }
    }

    public static func renderedBackgroundColor(
        _ role: CoveSemanticBackgroundRole,
        theme: CoveThemePalette,
        context: CoveThemeContrastContext
    ) -> CoveSRGBColor? {
        let hex = switch role {
        case .background:
            theme.backgroundHex
        case .surface:
            theme.surfaceHex
        }
        guard let color = CoveSRGBColor(hex: hex) else { return nil }
        let opacity = context.usesOpaqueSemanticBacking ? 1 : context.opacity
        return color.withAlpha(opacity).composited(over: context.desktop.color)
    }

    public static func foregroundColor(
        _ role: CoveSemanticForegroundRole,
        theme: CoveThemePalette
    ) -> CoveSRGBColor? {
        let hex = switch role {
        case .primaryText:
            theme.foregroundHex
        case .mutedText:
            theme.mutedTextHex
        case .accentControl, .focusRing:
            theme.accentHex
        case .border:
            theme.borderHex
        case .workingStatus:
            theme.workingHex
        case .waitingApprovalStatus:
            theme.waitingApprovalHex
        case .waitingInputStatus:
            theme.waitingInputHex
        case .compactingStatus:
            theme.compactingHex
        case .completedStatus:
            theme.completedHex
        case .failedStatus:
            theme.failedHex
        case .interruptedStatus:
            theme.interruptedHex
        case .idleStatus:
            theme.idleHex
        }
        return CoveSRGBColor(hex: hex)
    }
}
