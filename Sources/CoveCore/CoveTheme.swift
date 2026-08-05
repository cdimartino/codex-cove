import Foundation

public enum CoveThemeFamily: String, Codable, CaseIterable, Sendable {
    case nativeGlass = "Native Glass"
    case retroTerminal = "Retro Terminal"
    case minimalOled = "Minimal OLED"

    public var token: CoveThemeFamilyToken {
        switch self {
        case .nativeGlass:
            return .nativeGlass
        case .retroTerminal:
            return .retroTerminal
        case .minimalOled:
            return .minimalOLED
        }
    }
}

public enum CoveThemeFamilyToken: String, Codable, CaseIterable, Sendable {
    case nativeGlass
    case retroTerminal
    case minimalOLED

    public var family: CoveThemeFamily {
        switch self {
        case .nativeGlass:
            return .nativeGlass
        case .retroTerminal:
            return .retroTerminal
        case .minimalOLED:
            return .minimalOled
        }
    }
}

public enum CovePaletteKind: String, Codable, CaseIterable, Sendable {
    case graphite = "Graphite"
    case ocean = "Ocean"
    case terminalGreen = "Terminal Green"
    case sunset = "Sunset"
    case highContrast = "High Contrast"

    public var token: String {
        switch self {
        case .graphite:
            return "graphite"
        case .ocean:
            return "ocean"
        case .terminalGreen:
            return "terminalGreen"
        case .sunset:
            return "sunset"
        case .highContrast:
            return "highContrast"
        }
    }

    public init?(themeName: String) {
        if let exact = Self.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(themeName) == .orderedSame
        }) {
            self = exact
            return
        }
        guard let token = Self.allCases.first(where: {
            $0.token.caseInsensitiveCompare(themeName) == .orderedSame
        }) else {
            return nil
        }
        self = token
    }
}

public enum CoveThemeFontWeight: String, Codable, CaseIterable, Sendable {
    case light
    case regular
    case medium
    case semibold
    case bold
}

public enum CoveThemeBorderStyle: String, Codable, CaseIterable, Sendable {
    case solid
    case dashed
    case none
}

public enum CoveThemeAnimationEasing: String, Codable, CaseIterable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring
}

public enum CoveThemeSurfaceFill: String, Codable, CaseIterable, Sendable {
    case solid
    case gradient
}

public struct CoveThemeColors: Codable, Equatable, Sendable {
    public var background: String
    public var surface: String
    public var primaryText: String
    public var mutedText: String
    public var accent: String
    public var working: String
    public var waitingApproval: String
    public var waitingInput: String
    public var compacting: String
    public var completed: String
    public var failed: String
    public var interrupted: String
    public var idle: String

    public init(
        background: String,
        surface: String,
        primaryText: String,
        mutedText: String,
        accent: String,
        working: String,
        waitingApproval: String,
        waitingInput: String,
        compacting: String,
        completed: String,
        failed: String,
        interrupted: String,
        idle: String
    ) {
        self.background = background
        self.surface = surface
        self.primaryText = primaryText
        self.mutedText = mutedText
        self.accent = accent
        self.working = working
        self.waitingApproval = waitingApproval
        self.waitingInput = waitingInput
        self.compacting = compacting
        self.completed = completed
        self.failed = failed
        self.interrupted = interrupted
        self.idle = idle
    }

    private enum CodingKeys: String, CodingKey {
        case background, surface, primaryText, mutedText, accent
        case working, waitingApproval, waitingInput, compacting
        case completed, failed, interrupted, idle
        // Exact keys emitted by the first built-in v1 generator.
        case text, muted, waiting
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        background = try values.decode(String.self, forKey: .background)
        surface = try values.decode(String.self, forKey: .surface)
        primaryText = try values.decodeIfPresent(String.self, forKey: .primaryText)
            ?? values.decode(String.self, forKey: .text)
        mutedText = try values.decodeIfPresent(String.self, forKey: .mutedText)
            ?? values.decode(String.self, forKey: .muted)
        accent = try values.decode(String.self, forKey: .accent)
        working = try values.decode(String.self, forKey: .working)
        let legacyWaiting = try values.decodeIfPresent(String.self, forKey: .waiting)
        waitingApproval = try values.decodeIfPresent(String.self, forKey: .waitingApproval)
            ?? legacyWaiting
            ?? values.decode(String.self, forKey: .waitingApproval)
        waitingInput = try values.decodeIfPresent(String.self, forKey: .waitingInput)
            ?? legacyWaiting
            ?? waitingApproval
        compacting = try values.decodeIfPresent(String.self, forKey: .compacting)
            ?? working
        completed = try values.decode(String.self, forKey: .completed)
        failed = try values.decode(String.self, forKey: .failed)
        interrupted = try values.decodeIfPresent(String.self, forKey: .interrupted)
            ?? failed
        idle = try values.decodeIfPresent(String.self, forKey: .idle)
            ?? mutedText
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(background, forKey: .background)
        try values.encode(surface, forKey: .surface)
        try values.encode(primaryText, forKey: .primaryText)
        try values.encode(mutedText, forKey: .mutedText)
        try values.encode(accent, forKey: .accent)
        try values.encode(working, forKey: .working)
        try values.encode(waitingApproval, forKey: .waitingApproval)
        try values.encode(waitingInput, forKey: .waitingInput)
        try values.encode(compacting, forKey: .compacting)
        try values.encode(completed, forKey: .completed)
        try values.encode(failed, forKey: .failed)
        try values.encode(interrupted, forKey: .interrupted)
        try values.encode(idle, forKey: .idle)
    }
}

public struct CoveThemePaletteDocument: Codable, Equatable, Sendable {
    public var name: String
    public var colors: CoveThemeColors

    public init(name: String, colors: CoveThemeColors) {
        self.name = name
        self.colors = colors
    }
}

public struct CoveThemeTypography: Codable, Equatable, Sendable {
    public var family: String
    public var sizeScale: Double
    public var weight: CoveThemeFontWeight
    public var lineHeight: Double

    public init(
        family: String,
        sizeScale: Double,
        weight: CoveThemeFontWeight,
        lineHeight: Double
    ) {
        self.family = family
        self.sizeScale = sizeScale
        self.weight = weight
        self.lineHeight = lineHeight
    }
}

public struct CoveThemeBorder: Codable, Equatable, Sendable {
    public var color: String
    public var width: Double
    public var style: CoveThemeBorderStyle

    public init(color: String, width: Double, style: CoveThemeBorderStyle) {
        self.color = color
        self.width = width
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case color, width, style
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "#FFFFFF"
        width = try values.decode(Double.self, forKey: .width)
        style = try values.decode(CoveThemeBorderStyle.self, forKey: .style)
    }
}

public struct CoveThemeShadow: Codable, Equatable, Sendable {
    public var color: String
    public var x: Double
    public var y: Double
    public var blur: Double
    public var opacity: Double

    public init(color: String, x: Double, y: Double, blur: Double, opacity: Double) {
        self.color = color
        self.x = x
        self.y = y
        self.blur = blur
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case color, x, y, blur, opacity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "#000000"
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        blur = try values.decode(Double.self, forKey: .blur)
        opacity = try values.decode(Double.self, forKey: .opacity)
    }
}

public struct CoveThemeAnimation: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var durationMs: Double
    public var easing: CoveThemeAnimationEasing

    public init(enabled: Bool, durationMs: Double, easing: CoveThemeAnimationEasing) {
        self.enabled = enabled
        self.durationMs = durationMs
        self.easing = easing
    }
}

public struct CoveThemeDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumImportBytes = 1_048_576

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var family: CoveThemeFamilyToken
    public var palette: CoveThemePaletteDocument
    public var surfaceFill: CoveThemeSurfaceFill
    public var typography: CoveThemeTypography
    public var cornerRadius: Double
    public var border: CoveThemeBorder
    public var shadow: CoveThemeShadow
    public var noise: Double
    public var blur: CoveThemeBlur
    public var collapsedOpacity: Double
    public var expandedOpacity: Double
    public var animation: CoveThemeAnimation

    public init(
        schemaVersion: Int = CoveThemeDocument.currentSchemaVersion,
        id: String,
        name: String,
        family: CoveThemeFamilyToken,
        palette: CoveThemePaletteDocument,
        surfaceFill: CoveThemeSurfaceFill = .gradient,
        typography: CoveThemeTypography,
        cornerRadius: Double,
        border: CoveThemeBorder,
        shadow: CoveThemeShadow,
        noise: Double,
        blur: CoveThemeBlur,
        collapsedOpacity: Double,
        expandedOpacity: Double,
        animation: CoveThemeAnimation
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.family = family
        self.palette = palette
        self.surfaceFill = surfaceFill
        self.typography = typography
        self.cornerRadius = cornerRadius
        self.border = border
        self.shadow = shadow
        self.noise = noise
        self.blur = blur
        self.collapsedOpacity = collapsedOpacity
        self.expandedOpacity = expandedOpacity
        self.animation = animation
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, family, palette, surfaceFill, typography, cornerRadius
        case border, shadow, noise, blur, collapsedOpacity, expandedOpacity, animation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        family = try values.decode(CoveThemeFamilyToken.self, forKey: .family)
        palette = try values.decode(CoveThemePaletteDocument.self, forKey: .palette)
        surfaceFill = try values.decodeIfPresent(
            CoveThemeSurfaceFill.self,
            forKey: .surfaceFill
        ) ?? .gradient
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? "\(family.rawValue).\(CovePaletteKind(themeName: palette.name)?.token ?? "legacy")"
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? "\(family.family.rawValue) · \(palette.name)"
        typography = try values.decode(CoveThemeTypography.self, forKey: .typography)
        cornerRadius = try values.decode(Double.self, forKey: .cornerRadius)
        border = try values.decode(CoveThemeBorder.self, forKey: .border)
        shadow = try values.decode(CoveThemeShadow.self, forKey: .shadow)
        noise = try values.decode(Double.self, forKey: .noise)
        blur = try values.decode(CoveThemeBlur.self, forKey: .blur)
        collapsedOpacity = try values.decode(Double.self, forKey: .collapsedOpacity)
        expandedOpacity = try values.decode(Double.self, forKey: .expandedOpacity)
        animation = try values.decode(CoveThemeAnimation.self, forKey: .animation)
    }

    public static func decodeAndValidate(_ data: Data) throws -> CoveThemeDocument {
        guard data.count <= maximumImportBytes else {
            throw CoveThemeValidationError.fileTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumImportBytes
            )
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CoveThemeValidationError.invalidJSON
        }
        guard let root = json as? [String: Any] else {
            throw CoveThemeValidationError.invalidField("root")
        }
        let isLegacyBuiltIn = root["id"] == nil && root["name"] == nil
        try CoveThemeJSONShapeValidator.validate(root, allowsLegacyBuiltIn: isLegacyBuiltIn)

        let document: CoveThemeDocument
        do {
            document = try JSONDecoder().decode(CoveThemeDocument.self, from: data)
        } catch {
            throw CoveThemeValidationError.invalidJSON
        }
        try document.validate(allowsLegacyBuiltIn: isLegacyBuiltIn)
        return document
    }

    public func validate(allowsLegacyBuiltIn: Bool = false) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CoveThemeValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        try Self.validateIdentifier(id)
        try Self.validateText(name, field: "name", maximumLength: 80)
        try Self.validateText(palette.name, field: "palette.name", maximumLength: 80)
        if allowsLegacyBuiltIn {
            guard CovePaletteKind(themeName: palette.name) != nil,
                  CoveThemeCatalog.isBuiltInIdentifier(id)
            else {
                throw CoveThemeValidationError.invalidField("legacyBuiltIn")
            }
        }

        let colors: [(String, String)] = [
            ("palette.colors.background", palette.colors.background),
            ("palette.colors.surface", palette.colors.surface),
            ("palette.colors.primaryText", palette.colors.primaryText),
            ("palette.colors.mutedText", palette.colors.mutedText),
            ("palette.colors.accent", palette.colors.accent),
            ("palette.colors.working", palette.colors.working),
            ("palette.colors.waitingApproval", palette.colors.waitingApproval),
            ("palette.colors.waitingInput", palette.colors.waitingInput),
            ("palette.colors.compacting", palette.colors.compacting),
            ("palette.colors.completed", palette.colors.completed),
            ("palette.colors.failed", palette.colors.failed),
            ("palette.colors.interrupted", palette.colors.interrupted),
            ("palette.colors.idle", palette.colors.idle),
            ("border.color", border.color),
            ("shadow.color", shadow.color),
        ]
        for (field, color) in colors {
            guard Self.isValidHexColor(color) else {
                throw CoveThemeValidationError.invalidField(field)
            }
        }

        try Self.validateText(
            typography.family,
            field: "typography.family",
            maximumLength: 128
        )
        try Self.validateRange(
            typography.sizeScale,
            range: 0.5 ... 2,
            field: "typography.sizeScale"
        )
        try Self.validateRange(
            typography.lineHeight,
            range: 0.5 ... 3,
            field: "typography.lineHeight"
        )
        try Self.validateRange(cornerRadius, range: 0 ... 64, field: "cornerRadius")
        try Self.validateRange(border.width, range: 0 ... 8, field: "border.width")
        try Self.validateRange(shadow.x, range: -128 ... 128, field: "shadow.x")
        try Self.validateRange(shadow.y, range: -128 ... 128, field: "shadow.y")
        try Self.validateRange(shadow.blur, range: 0 ... 128, field: "shadow.blur")
        try Self.validateRange(shadow.opacity, range: 0 ... 1, field: "shadow.opacity")
        try Self.validateRange(noise, range: 0 ... 1, field: "noise")
        try Self.validateRange(
            collapsedOpacity,
            range: 0.35 ... 1,
            field: "collapsedOpacity"
        )
        try Self.validateRange(
            expandedOpacity,
            range: 0.35 ... 1,
            field: "expandedOpacity"
        )
        try Self.validateRange(
            animation.durationMs,
            range: 0 ... 2_000,
            field: "animation.durationMs"
        )
    }

    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 64,
              !value.contains(".."),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                      return true
                  default:
                      return false
                  }
              })
        else {
            throw CoveThemeValidationError.unsafeIdentifier
        }
    }

    private static func validateText(
        _ value: String,
        field: String,
        maximumLength: Int
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumLength,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CoveThemeValidationError.invalidField(field)
        }
    }

    private static func validateRange(
        _ value: Double,
        range: ClosedRange<Double>,
        field: String
    ) throws {
        guard value.isFinite, range.contains(value) else {
            throw CoveThemeValidationError.invalidField(field)
        }
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        guard value.utf8.count == 7, value.first == "#" else { return false }
        return value.dropFirst().unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 70, 97 ... 102:
                return true
            default:
                return false
            }
        }
    }
}

public typealias CoveThemeDefinition = CoveThemeDocument

public enum CoveThemeValidationError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
    case unsupportedSchema(found: Int, supported: Int)
    case invalidField(String)
    case unsafeIdentifier
    case builtInIdentifier(String)
    case unsafeFilesystemEntry(String)

    public var errorDescription: String? {
        switch self {
        case let .fileTooLarge(actualBytes, maximumBytes):
            return "Theme is \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
        case .invalidJSON:
            return "Theme JSON is malformed or does not match the v1 contract."
        case let .unsupportedSchema(found, supported):
            return "Theme schema \(found) is unsupported; this Cove supports v\(supported)."
        case let .invalidField(field):
            return "Theme field is missing or invalid: \(field)."
        case .unsafeIdentifier:
            return "Theme id must be 1–64 safe filename characters and cannot contain '..'."
        case let .builtInIdentifier(identifier):
            return "Custom theme id '\(identifier)' is reserved by a built-in theme."
        case let .unsafeFilesystemEntry(kind):
            return "Refusing to use an unsafe theme \(kind)."
        }
    }
}

public enum CoveThemeBlur: String, Codable, CaseIterable, Sendable {
    case off
    case thin
    case regular
    case thick

    public var style: CoveBlurStyle {
        switch self {
        case .off:
            return .off
        case .thin:
            return .thin
        case .regular:
            return .regular
        case .thick:
            return .thick
        }
    }

    public init(_ style: CoveBlurStyle) {
        switch style {
        case .off:
            self = .off
        case .thin:
            self = .thin
        case .regular:
            self = .regular
        case .thick:
            self = .thick
        }
    }
}

public struct CoveThemePalette: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var identifier: String
    public var name: String
    public var family: CoveThemeFamily
    public var palette: CovePaletteKind
    public var paletteName: String
    public var accentHex: String
    public var backgroundHex: String
    public var surfaceFill: CoveThemeSurfaceFill
    public var surfaceHex: String
    public var foregroundHex: String
    public var mutedTextHex: String
    public var workingHex: String
    public var waitingApprovalHex: String
    public var waitingInputHex: String
    public var compactingHex: String
    public var completedHex: String
    public var failedHex: String
    public var interruptedHex: String
    public var idleHex: String
    public var shadowHex: String
    public var fontName: String
    public var fontSizeScale: Double
    public var fontWeight: CoveThemeFontWeight
    public var lineHeight: Double
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderStyle: CoveThemeBorderStyle
    public var borderHex: String
    public var shadowX: Double
    public var shadowY: Double
    public var shadowBlur: Double
    public var shadowOpacity: Double
    public var noiseOpacity: Double
    public var blurStyle: CoveBlurStyle
    public var collapsedOpacity: Double
    public var expandedOpacity: Double
    public var animationEnabled: Bool
    public var animationDurationMilliseconds: Double
    public var animationEasing: CoveThemeAnimationEasing

    public var id: String { identifier }
    public var waitingHex: String { waitingApprovalHex }
    public var isBuiltIn: Bool { CoveThemeCatalog.isBuiltInIdentifier(identifier) }

    public init(
        schemaVersion: Int = CoveThemeDocument.currentSchemaVersion,
        identifier: String? = nil,
        name: String,
        family: CoveThemeFamily,
        palette: CovePaletteKind,
        paletteName: String? = nil,
        accentHex: String,
        backgroundHex: String,
        surfaceFill: CoveThemeSurfaceFill = .gradient,
        surfaceHex: String? = nil,
        foregroundHex: String,
        mutedTextHex: String? = nil,
        workingHex: String = "#52B8FF",
        waitingHex: String = "#FFC857",
        waitingApprovalHex: String? = nil,
        waitingInputHex: String = "#FF8AD8",
        compactingHex: String = "#A892FF",
        completedHex: String = "#42E58A",
        failedHex: String = "#FF627D",
        interruptedHex: String? = nil,
        idleHex: String? = nil,
        shadowHex: String,
        fontName: String = "SF Pro Rounded",
        fontSizeScale: Double = 1,
        fontWeight: CoveThemeFontWeight = .medium,
        lineHeight: Double = 1.2,
        cornerRadius: Double = 24,
        borderWidth: Double = 1,
        borderStyle: CoveThemeBorderStyle = .solid,
        borderHex: String = "#FFFFFF",
        shadowX: Double = 0,
        shadowY: Double = 12,
        shadowBlur: Double = 30,
        shadowOpacity: Double = 0.3,
        noiseOpacity: Double = 0.03,
        blurStyle: CoveBlurStyle = .regular,
        collapsedOpacity: Double = 0.72,
        expandedOpacity: Double = 0.88,
        animationEnabled: Bool = true,
        animationDurationMilliseconds: Double = 180,
        animationEasing: CoveThemeAnimationEasing = .easeOut
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier ?? "\(family.token.rawValue).\(palette.token)"
        self.name = name
        self.family = family
        self.palette = palette
        self.paletteName = paletteName ?? palette.rawValue
        self.accentHex = accentHex
        self.backgroundHex = backgroundHex
        self.surfaceFill = surfaceFill
        self.surfaceHex = surfaceHex ?? backgroundHex
        self.foregroundHex = foregroundHex
        self.mutedTextHex = mutedTextHex ?? foregroundHex
        self.workingHex = workingHex
        self.waitingApprovalHex = waitingApprovalHex ?? waitingHex
        self.waitingInputHex = waitingInputHex
        self.compactingHex = compactingHex
        self.completedHex = completedHex
        self.failedHex = failedHex
        self.interruptedHex = interruptedHex ?? failedHex
        self.idleHex = idleHex ?? (mutedTextHex ?? foregroundHex)
        self.shadowHex = shadowHex
        self.fontName = fontName
        self.fontSizeScale = fontSizeScale
        self.fontWeight = fontWeight
        self.lineHeight = lineHeight
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderStyle = borderStyle
        self.borderHex = borderHex
        self.shadowX = shadowX
        self.shadowY = shadowY
        self.shadowBlur = shadowBlur
        self.shadowOpacity = shadowOpacity
        self.noiseOpacity = noiseOpacity
        self.blurStyle = blurStyle
        self.collapsedOpacity = collapsedOpacity
        self.expandedOpacity = expandedOpacity
        self.animationEnabled = animationEnabled
        self.animationDurationMilliseconds = animationDurationMilliseconds
        self.animationEasing = animationEasing
    }

    public init(document: CoveThemeDocument) {
        let paletteKind = CovePaletteKind(themeName: document.palette.name) ?? .graphite
        self.init(
            schemaVersion: document.schemaVersion,
            identifier: document.id,
            name: document.name,
            family: document.family.family,
            palette: paletteKind,
            paletteName: document.palette.name,
            accentHex: document.palette.colors.accent,
            backgroundHex: document.palette.colors.background,
            surfaceFill: document.surfaceFill,
            surfaceHex: document.palette.colors.surface,
            foregroundHex: document.palette.colors.primaryText,
            mutedTextHex: document.palette.colors.mutedText,
            workingHex: document.palette.colors.working,
            waitingApprovalHex: document.palette.colors.waitingApproval,
            waitingInputHex: document.palette.colors.waitingInput,
            compactingHex: document.palette.colors.compacting,
            completedHex: document.palette.colors.completed,
            failedHex: document.palette.colors.failed,
            interruptedHex: document.palette.colors.interrupted,
            idleHex: document.palette.colors.idle,
            shadowHex: document.shadow.color,
            fontName: document.typography.family,
            fontSizeScale: document.typography.sizeScale,
            fontWeight: document.typography.weight,
            lineHeight: document.typography.lineHeight,
            cornerRadius: document.cornerRadius,
            borderWidth: document.border.width,
            borderStyle: document.border.style,
            borderHex: document.border.color,
            shadowX: document.shadow.x,
            shadowY: document.shadow.y,
            shadowBlur: document.shadow.blur,
            shadowOpacity: document.shadow.opacity,
            noiseOpacity: document.noise,
            blurStyle: document.blur.style,
            collapsedOpacity: document.collapsedOpacity,
            expandedOpacity: document.expandedOpacity,
            animationEnabled: document.animation.enabled,
            animationDurationMilliseconds: document.animation.durationMs,
            animationEasing: document.animation.easing
        )
    }

    public var document: CoveThemeDocument {
        CoveThemeDocument(
            schemaVersion: schemaVersion,
            id: identifier,
            name: name,
            family: family.token,
            palette: CoveThemePaletteDocument(
                name: paletteName,
                colors: CoveThemeColors(
                    background: backgroundHex,
                    surface: surfaceHex,
                    primaryText: foregroundHex,
                    mutedText: mutedTextHex,
                    accent: accentHex,
                    working: workingHex,
                    waitingApproval: waitingApprovalHex,
                    waitingInput: waitingInputHex,
                    compacting: compactingHex,
                    completed: completedHex,
                    failed: failedHex,
                    interrupted: interruptedHex,
                    idle: idleHex
                )
            ),
            surfaceFill: surfaceFill,
            typography: CoveThemeTypography(
                family: fontName,
                sizeScale: fontSizeScale,
                weight: fontWeight,
                lineHeight: lineHeight
            ),
            cornerRadius: cornerRadius,
            border: CoveThemeBorder(
                color: borderHex,
                width: borderWidth,
                style: borderStyle
            ),
            shadow: CoveThemeShadow(
                color: shadowHex,
                x: shadowX,
                y: shadowY,
                blur: shadowBlur,
                opacity: shadowOpacity
            ),
            noise: noiseOpacity,
            blur: CoveThemeBlur(blurStyle),
            collapsedOpacity: collapsedOpacity,
            expandedOpacity: expandedOpacity,
            animation: CoveThemeAnimation(
                enabled: animationEnabled,
                durationMs: animationDurationMilliseconds,
                easing: animationEasing
            )
        )
    }
}

public enum CoveThemeCatalog {
    private struct Tokens {
        let background: String
        let surface: String
        let text: String
        let muted: String
        let accent: String
        let working: String
        let waitingApproval: String
        let waitingInput: String
        let compacting: String
        let completed: String
        let failed: String
        let interrupted: String
        let idle: String
        let shadow: String
    }

    private static let tokens: [CovePaletteKind: Tokens] = [
        .graphite: .init(
            background: "#081016", surface: "#13212B", text: "#EDF7F7",
            muted: "#89A2A7", accent: "#55E6D0", working: "#52B8FF",
            waitingApproval: "#FFC857", waitingInput: "#FF8AD8",
            compacting: "#A892FF", completed: "#42E58A", failed: "#FF627D",
            interrupted: "#FF8C69", idle: "#89A2A7", shadow: "#020608"
        ),
        .ocean: .init(
            background: "#031925", surface: "#073348", text: "#E8FBFF",
            muted: "#81ADBB", accent: "#37D9ED", working: "#57A9FF",
            waitingApproval: "#FFD166", waitingInput: "#F4A8FF",
            compacting: "#9E9BFF", completed: "#4DE3A1", failed: "#FF6B7A",
            interrupted: "#FF9D76", idle: "#81ADBB", shadow: "#011017"
        ),
        .terminalGreen: .init(
            background: "#020704", surface: "#07150C", text: "#B9FFD0",
            muted: "#62A878", accent: "#54FF8A", working: "#82FFB0",
            waitingApproval: "#E8FF6A", waitingInput: "#9DFFDF",
            compacting: "#B0FF96", completed: "#35F27A", failed: "#FF667D",
            interrupted: "#FFAD66", idle: "#62A878", shadow: "#010302"
        ),
        .sunset: .init(
            background: "#1A0B1D", surface: "#342035", text: "#FFF1E9",
            muted: "#C49AAF", accent: "#FF9A62", working: "#A892FF",
            waitingApproval: "#FFD166", waitingInput: "#FF91C8",
            compacting: "#C89CFF", completed: "#6EE7A8", failed: "#FF5B77",
            interrupted: "#FFAA73", idle: "#C49AAF", shadow: "#0D050F"
        ),
        .highContrast: .init(
            background: "#000000", surface: "#111111", text: "#FFFFFF",
            muted: "#D0D0D0", accent: "#00FFFF", working: "#66B3FF",
            waitingApproval: "#FFFF00", waitingInput: "#FF66FF",
            compacting: "#CC99FF", completed: "#00FF66", failed: "#FF3355",
            interrupted: "#FF9900", idle: "#D0D0D0", shadow: "#000000"
        ),
    ]

    public static let palettes: [CoveThemePalette] = CoveThemeFamily.allCases.flatMap { family in
        CovePaletteKind.allCases.map { palette in
            make(family: family, palette: palette)
        }
    }

    public static func palette(
        for family: CoveThemeFamily,
        palette: CovePaletteKind? = nil
    ) -> CoveThemePalette {
        if let palette {
            return palettes.first(where: {
                $0.family == family && $0.palette == palette
            }) ?? fallback(for: family)
        }
        return fallback(for: family)
    }

    public static func theme(identifier: String) -> CoveThemePalette? {
        palettes.first { $0.identifier == identifier }
    }

    public static func isBuiltInIdentifier(_ identifier: String) -> Bool {
        CoveThemeFamilyToken.allCases.contains { family in
            CovePaletteKind.allCases.contains { palette in
                identifier == "\(family.rawValue).\(palette.token)"
            }
        }
    }

    private static func fallback(for family: CoveThemeFamily) -> CoveThemePalette {
        make(family: family, palette: .graphite)
    }

    private static func make(
        family: CoveThemeFamily,
        palette: CovePaletteKind
    ) -> CoveThemePalette {
        let token = tokens[palette] ?? tokens[.graphite]!
        let font: String
        let weight: CoveThemeFontWeight
        let scale: Double
        let lineHeight: Double
        let radius: Double
        let borderWidth: Double
        let shadowY: Double
        let shadowBlur: Double
        let shadowOpacity: Double
        let noise: Double
        let blur: CoveBlurStyle
        let collapsedOpacity: Double
        let expandedOpacity: Double
        let duration: Double
        let easing: CoveThemeAnimationEasing
        switch family {
        case .nativeGlass:
            font = "SF Pro Rounded"
            weight = .medium
            scale = 1
            lineHeight = 1.2
            radius = 24
            borderWidth = 1
            shadowY = 12
            shadowBlur = 30
            shadowOpacity = 0.3
            noise = 0.03
            blur = .regular
            collapsedOpacity = 0.72
            expandedOpacity = 0.88
            duration = 180
            easing = .easeOut
        case .retroTerminal:
            font = "SF Mono"
            weight = .medium
            scale = 0.96
            lineHeight = 1.1
            radius = 10
            borderWidth = 1
            shadowY = 6
            shadowBlur = 16
            shadowOpacity = 0.4
            noise = 0.08
            blur = .thin
            collapsedOpacity = 0.86
            expandedOpacity = 0.94
            duration = 120
            easing = .linear
        case .minimalOled:
            font = "SF Pro Text"
            weight = .regular
            scale = 1
            lineHeight = 1.2
            radius = 18
            borderWidth = 0
            shadowY = 0
            shadowBlur = 0
            shadowOpacity = 0
            noise = 0
            blur = .off
            collapsedOpacity = 1
            expandedOpacity = 1
            duration = 140
            easing = .easeInOut
        }
        return CoveThemePalette(
            name: "\(family.rawValue) · \(palette.rawValue)",
            family: family,
            palette: palette,
            accentHex: token.accent,
            backgroundHex: token.background,
            surfaceHex: token.surface,
            foregroundHex: token.text,
            mutedTextHex: token.muted,
            workingHex: token.working,
            waitingApprovalHex: token.waitingApproval,
            waitingInputHex: token.waitingInput,
            compactingHex: token.compacting,
            completedHex: token.completed,
            failedHex: token.failed,
            interruptedHex: token.interrupted,
            idleHex: token.idle,
            shadowHex: token.shadow,
            fontName: font,
            fontSizeScale: scale,
            fontWeight: weight,
            lineHeight: lineHeight,
            cornerRadius: radius,
            borderWidth: borderWidth,
            borderStyle: borderWidth == 0 ? .none : .solid,
            borderHex: palette == .highContrast ? "#FFFFFF" : token.accent,
            shadowY: shadowY,
            shadowBlur: shadowBlur,
            shadowOpacity: shadowOpacity,
            noiseOpacity: noise,
            blurStyle: blur,
            collapsedOpacity: collapsedOpacity,
            expandedOpacity: expandedOpacity,
            animationDurationMilliseconds: duration,
            animationEasing: easing
        )
    }
}

public enum CoveOpacityStyle: String, Codable, CaseIterable, Sendable {
    case shadowed = "Shadowed"
    case balanced = "Balanced"
    case luminous = "Luminous"
    case pristine = "Pristine"

    public var collapsedAlpha: Double {
        switch self {
        case .shadowed:
            return 0.35
        case .balanced:
            return 0.72
        case .luminous:
            return 0.86
        case .pristine:
            return 1.0
        }
    }

    public var expandedAlpha: Double {
        switch self {
        case .shadowed:
            return 0.55
        case .balanced:
            return 0.88
        case .luminous:
            return 0.94
        case .pristine:
            return 1.0
        }
    }

    public func alpha(isExpanded: Bool) -> Double {
        isExpanded ? expandedAlpha : collapsedAlpha
    }
}

public enum CoveBlurStyle: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case thin = "Thin"
    case regular = "Regular"
    case thick = "Thick"
}

public enum CovePrivacyMode: String, Codable, CaseIterable, Sendable {
    case auto = "Auto"
    case on = "On"
    case off = "Off"

    public var suppressVisualEffects: Bool {
        switch self {
        case .on:
            return true
        case .auto, .off:
            return false
        }
    }
}

private enum CoveThemeJSONShapeValidator {
    static func validate(
        _ root: [String: Any],
        allowsLegacyBuiltIn: Bool
    ) throws {
        let rootKeys: Set<String> = [
            "schemaVersion", "id", "name", "family", "palette", "typography",
            "cornerRadius", "border", "shadow", "noise", "blur",
            "collapsedOpacity", "expandedOpacity", "animation", "surfaceFill",
        ]
        var requiredRoot = rootKeys
        requiredRoot.remove("surfaceFill")
        if allowsLegacyBuiltIn {
            requiredRoot.remove("id")
            requiredRoot.remove("name")
        }
        try validateKeys(
            root,
            allowed: rootKeys,
            required: requiredRoot,
            field: "root"
        )
        let palette = try object(root["palette"], field: "palette")
        try validateKeys(
            palette,
            allowed: ["name", "colors"],
            required: ["name", "colors"],
            field: "palette"
        )
        let colors = try object(palette["colors"], field: "palette.colors")
        if allowsLegacyBuiltIn {
            let legacyColors: Set<String> = [
                "background", "surface", "text", "muted", "accent",
                "working", "waiting", "completed", "failed",
            ]
            try validateKeys(
                colors,
                allowed: legacyColors,
                required: legacyColors,
                field: "palette.colors"
            )
        } else {
            let colorsKeys: Set<String> = [
                "background", "surface", "primaryText", "mutedText", "accent",
                "working", "waitingApproval", "waitingInput", "compacting",
                "completed", "failed", "interrupted", "idle",
            ]
            try validateKeys(
                colors,
                allowed: colorsKeys,
                required: colorsKeys,
                field: "palette.colors"
            )
        }
        let typography = try object(root["typography"], field: "typography")
        try validateKeys(
            typography,
            allowed: ["family", "sizeScale", "weight", "lineHeight"],
            required: ["family", "sizeScale", "weight", "lineHeight"],
            field: "typography"
        )
        let border = try object(root["border"], field: "border")
        try validateKeys(
            border,
            allowed: ["color", "width", "style"],
            required: allowsLegacyBuiltIn
                ? ["width", "style"]
                : ["color", "width", "style"],
            field: "border"
        )
        let shadow = try object(root["shadow"], field: "shadow")
        try validateKeys(
            shadow,
            allowed: ["color", "x", "y", "blur", "opacity"],
            required: allowsLegacyBuiltIn
                ? ["x", "y", "blur", "opacity"]
                : ["color", "x", "y", "blur", "opacity"],
            field: "shadow"
        )
        let animation = try object(root["animation"], field: "animation")
        try validateKeys(
            animation,
            allowed: ["enabled", "durationMs", "easing"],
            required: ["enabled", "durationMs", "easing"],
            field: "animation"
        )
    }

    private static func object(_ value: Any?, field: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw CoveThemeValidationError.invalidField(field)
        }
        return object
    }

    private static func validateKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>,
        field: String
    ) throws {
        let keys = Set(object.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw CoveThemeValidationError.invalidField(field)
        }
    }
}
