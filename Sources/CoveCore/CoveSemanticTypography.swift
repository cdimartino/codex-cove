import Foundation

/// Semantic typography roles used by informative and actionable Cove UI.
///
/// Themes retain their font family and normal body weight. Role metrics are a
/// legibility contract: a theme may scale text up, but it may not scale a role
/// below its semantic minimum.
public enum CoveTextRole: String, CaseIterable, Codable, Sendable {
    case title
    case body
    case status
    case metadata
    case badge
    case data

    /// The unscaled design size for this role.
    public var basePointSize: Double {
        switch self {
        case .title, .body:
            return 13
        case .status:
            return 12
        case .metadata, .badge, .data:
            return 11
        }
    }

    /// The smallest permitted rendered size for informative text in this role.
    public var minimumPointSize: Double {
        basePointSize
    }

    /// Resolves theme scaling without permitting a role to become illegible.
    public func resolvedPointSize(themeScale: Double) -> Double {
        let finiteScale = themeScale.isFinite ? max(0, themeScale) : 1
        return max(minimumPointSize, basePointSize * finiteScale)
    }

    /// Titles are always semibold. Other roles preserve the theme's weight.
    public func resolvedWeight(
        themeWeight: CoveThemeFontWeight
    ) -> CoveThemeFontWeight {
        self == .title ? .semibold : themeWeight
    }
}

/// Core-only resolved metrics. The app maps these values to SwiftUI `Font`
/// without making CoveCore depend on a UI framework.
public struct CoveSemanticTypography: Equatable, Sendable {
    public static let informativeTextFloor: Double = 11

    public var family: String
    public var themeWeight: CoveThemeFontWeight
    public var themeScale: Double

    public init(
        family: String,
        themeWeight: CoveThemeFontWeight,
        themeScale: Double
    ) {
        self.family = family
        self.themeWeight = themeWeight
        self.themeScale = themeScale
    }

    public init(theme: CoveThemePalette) {
        self.init(
            family: theme.fontName,
            themeWeight: theme.fontWeight,
            themeScale: theme.fontSizeScale
        )
    }

    public func pointSize(for role: CoveTextRole) -> Double {
        role.resolvedPointSize(themeScale: themeScale)
    }

    public func weight(for role: CoveTextRole) -> CoveThemeFontWeight {
        role.resolvedWeight(themeWeight: themeWeight)
    }

    public var satisfiesInformativeTextFloor: Bool {
        CoveTextRole.allCases.allSatisfy {
            pointSize(for: $0) >= Self.informativeTextFloor
        }
    }
}

public extension CoveThemePalette {
    var semanticTypography: CoveSemanticTypography {
        CoveSemanticTypography(theme: self)
    }

    func pointSize(for role: CoveTextRole) -> Double {
        semanticTypography.pointSize(for: role)
    }

    func fontWeight(for role: CoveTextRole) -> CoveThemeFontWeight {
        semanticTypography.weight(for: role)
    }
}
