import SwiftUI
import CoveCore

private struct CoveTextScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue = CoveSettings.defaultTextScale
}

extension EnvironmentValues {
    var coveTextScale: Double {
        get { self[CoveTextScaleEnvironmentKey.self] }
        set {
            self[CoveTextScaleEnvironmentKey.self] =
                CoveSettings.validatedTextScale(newValue)
        }
    }
}

extension View {
    /// Injects Cove's persisted macOS text-size preference. macOS does not
    /// provide a user-adjustable SwiftUI Dynamic Type value, so Cove owns this
    /// scale and applies it to both custom-theme and Settings typography.
    func coveTextScale(_ value: Double) -> some View {
        environment(\.coveTextScale, CoveSettings.validatedTextScale(value))
    }

    func coveThemeFont(
        _ theme: CoveThemePalette,
        size: Double,
        weight: Font.Weight? = nil
    ) -> some View {
        modifier(
            CoveScaledThemeFontModifier(
                theme: theme,
                size: size,
                weight: weight
            )
        )
    }

    func coveOverlayFont(
        _ theme: CoveThemePalette,
        _ role: CoveTextRole,
        weight: Font.Weight? = nil
    ) -> some View {
        modifier(
            CoveScaledOverlayFontModifier(
                theme: theme,
                role: role,
                weight: weight
            )
        )
    }

    func coveSystemFont(
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(
            CoveScaledSystemFontModifier(
                size: size,
                weight: weight,
                design: design
            )
        )
    }
}

private struct CoveScaledThemeFontModifier: ViewModifier {
    @Environment(\.coveTextScale) private var textScale
    let theme: CoveThemePalette
    let size: Double
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(
            theme.coveFont(
                size: size,
                weight: weight,
                textScale: textScale
            )
        )
    }
}

private struct CoveScaledOverlayFontModifier: ViewModifier {
    @Environment(\.coveTextScale) private var textScale
    let theme: CoveThemePalette
    let role: CoveTextRole
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        let resolvedWeight: Font.Weight = switch theme.fontWeight(for: role) {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        content.font(
            .custom(
                theme.fontName,
                size: theme.pointSize(for: role) * textScale
            )
            .weight(weight ?? resolvedWeight)
        )
    }
}

private struct CoveScaledSystemFontModifier: ViewModifier {
    @Environment(\.coveTextScale) private var textScale
    let size: Double
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: max(
                    CoveSemanticTypography.informativeTextFloor,
                    size
                ) * textScale,
                weight: weight,
                design: design
            )
        )
    }
}
