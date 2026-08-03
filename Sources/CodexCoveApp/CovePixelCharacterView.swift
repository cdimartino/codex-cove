import AppKit
import CoveCore
import QuartzCore
import SwiftUI

/// Semantic colors supplied by the active Cove theme. The renderer never owns a branded palette.
struct CovePixelCharacterPalette {
    let outline: Color
    let body: Color
    let accent: Color
    let activity: Color

    init(outline: Color, body: Color, accent: Color, activity: Color) {
        self.outline = outline
        self.body = body
        self.accent = accent
        self.activity = activity
    }

    init(
        theme: CoveThemePalette,
        status: CoveSessionStatus,
        character: CovePixelCharacter
    ) {
        let colorway = CoveCharacterColorway(
            theme: theme,
            character: character
        )
        self.init(
            outline: Color(hex: theme.foregroundHex),
            body: colorway.body,
            accent: colorway.accent,
            activity: character.animates(status: status)
                ? colorway.activity
                : Color(hex: theme.characterStatusHex(status))
        )
    }

    func color(for ink: CovePixelInk) -> Color {
        switch ink {
        case .outline: outline
        case .body: body
        case .accent: accent
        case .activity: activity
        }
    }
}

/// Backing-pixel-aligned renderer. Active residents animate; attention and terminal residents
/// render one frozen frame containing their semantic callout.
struct CovePixelCharacterView: View {
    let character: CovePixelCharacter
    let status: CoveSessionStatus
    let palette: CovePixelCharacterPalette
    let size: CGFloat
    let reduceMotion: Bool

    init(
        character: CovePixelCharacter,
        status: CoveSessionStatus,
        palette: CovePixelCharacterPalette,
        size: CGFloat,
        reduceMotion: Bool
    ) {
        self.character = character
        self.status = status
        self.palette = palette
        self.size = max(14, size)
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        CovePixelSpriteRepresentable(
            character: character,
            status: status,
            palette: palette,
            reduceMotion: reduceMotion,
            animationInterval: animationInterval
        )
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(character.archetype.displayName), \(status.accessibilityLabel)")
    }

    private var animationInterval: TimeInterval {
        let index = CovePixelCharacterArchetype.allCases.firstIndex(
            of: character.archetype
        ) ?? 0
        return min(
            0.66,
            [0.42, 0.50, 0.58, 0.66][index % 4]
                + Double(character.variation) * 0.015
        )
    }

}

/// Compact integration point for collapsed bubbles.
struct CovePixelCharacterBubble: View {
    let character: CovePixelCharacter
    let status: CoveSessionStatus
    let theme: CoveThemePalette
    let reduceMotion: Bool
    var size: CGFloat = 24

    var body: some View {
        CovePixelCharacterView(
            character: character,
            status: status,
            palette: CovePixelCharacterPalette(
                theme: theme,
                status: status,
                character: character
            ),
            size: size,
            reduceMotion: reduceMotion
        )
    }
}

/// Slightly larger integration point for an expanded session row.
struct CovePixelCharacterRowAvatar: View {
    let character: CovePixelCharacter
    let status: CoveSessionStatus
    let theme: CoveThemePalette
    let reduceMotion: Bool
    var size: CGFloat = 34

    var body: some View {
        CovePixelCharacterView(
            character: character,
            status: status,
            palette: CovePixelCharacterPalette(
                theme: theme,
                status: status,
                character: character
            ),
            size: size,
            reduceMotion: reduceMotion
        )
    }
}

private struct CoveCharacterColorway {
    let body: Color
    let accent: Color
    let activity: Color

    init(theme: CoveThemePalette, character: CovePixelCharacter) {
        let specification = character.colorway
        let themeInfluence: Double = switch theme.palette {
        case .terminalGreen: 0.40
        case .ocean: 0.66
        case .sunset: 0.74
        case .graphite, .highContrast: 0.88
        }
        let base = CoveHSVColor(hex: theme.accentHex)
        let bodyHue = CoveHSVColor.blendedHue(
            from: base.hue,
            to: specification.bodyHueDegrees / 360,
            amount: themeInfluence
        )
        let accentHue = CoveHSVColor.blendedHue(
            from: base.hue,
            to: specification.accentHueDegrees / 360,
            amount: themeInfluence
        )
        let activityHue = CoveHSVColor.blendedHue(
            from: base.hue,
            to: specification.activityHueDegrees / 360,
            amount: themeInfluence
        )
        body = Color(
            hue: bodyHue,
            saturation: min(
                0.92,
                max(0.50, specification.saturation * 0.78 + base.saturation * 0.22)
            ),
            brightness: min(0.98, max(0.68, specification.brightness))
        )
        accent = Color(
            hue: accentHue,
            saturation: min(1, max(0.72, specification.saturation + 0.16)),
            brightness: min(1, max(0.90, specification.brightness + 0.08))
        )
        activity = Color(
            hue: activityHue,
            saturation: min(1, max(0.78, specification.saturation + 0.2)),
            brightness: 1
        )
    }
}

private struct CoveHSVColor {
    let hue: Double
    let saturation: Double
    let brightness: Double

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        brightness = maximum
        saturation = maximum == 0 ? 0 : delta / maximum
        if delta == 0 {
            hue = 0
        } else if maximum == red {
            hue = Self.wrappedHue((green - blue) / delta / 6)
        } else if maximum == green {
            hue = Self.wrappedHue(((blue - red) / delta + 2) / 6)
        } else {
            hue = Self.wrappedHue(((red - green) / delta + 4) / 6)
        }
    }

    static func wrappedHue(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    static func blendedHue(
        from source: Double,
        to target: Double,
        amount: Double
    ) -> Double {
        let delta = wrappedHue(target - source + 0.5) - 0.5
        return wrappedHue(source + delta * min(1, max(0, amount)))
    }
}

/// Hosts the sprite in AppKit so Core Animation can advance discrete frames without invalidating
/// a SwiftUI subtree for every resident and every tick.
private struct CovePixelSpriteRepresentable: NSViewRepresentable {
    let character: CovePixelCharacter
    let status: CoveSessionStatus
    let palette: CovePixelCharacterPalette
    let reduceMotion: Bool
    let animationInterval: TimeInterval

    func makeNSView(context: Context) -> CovePixelSpriteNSView {
        let view = CovePixelSpriteNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: CovePixelSpriteNSView, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(
        _ nsView: CovePixelSpriteNSView,
        coordinator: Void
    ) {
        nsView.dismantle()
    }

    private func configure(_ view: CovePixelSpriteNSView) {
        view.configure(
            character: character,
            status: status,
            colors: CovePixelSpriteColors(palette: palette),
            reduceMotion: reduceMotion,
            animationInterval: animationInterval
        )
    }
}

@MainActor
private final class CovePixelSpriteNSView: NSView {
    private static let animationKey = "cove.pixel-resident.frames"

    private let spriteLayer = CALayer()
    private var configuration: Configuration?
    private var renderedFrames: [CGImage] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        spriteLayer.masksToBounds = false
        spriteLayer.contentsGravity = .resize
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.allowsEdgeAntialiasing = false
        layer?.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                releaseRenderResources()
            } else {
                ensureRenderResources()
            }
        }
    }

    override func layout() {
        super.layout()
        guard canRender else {
            releaseRenderResources()
            return
        }
        ensureRenderResources()
        layoutSpriteLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            releaseRenderResources()
        } else {
            ensureRenderResources()
            needsLayout = true
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        releaseRenderResources()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        ensureRenderResources()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func configure(
        character: CovePixelCharacter,
        status: CoveSessionStatus,
        colors: CovePixelSpriteColors,
        reduceMotion: Bool,
        animationInterval: TimeInterval
    ) {
        let next = Configuration(
            character: character,
            status: status,
            colors: colors,
            reduceMotion: reduceMotion,
            animationInterval: animationInterval
        )
        guard configuration != next else {
            ensureRenderResources()
            return
        }
        configuration = next
        releaseRenderResources()
        ensureRenderResources()
        needsLayout = true
    }

    func dismantle() {
        configuration = nil
        releaseRenderResources()
        spriteLayer.removeFromSuperlayer()
    }

    private var canRender: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && configuration != nil
    }

    private func ensureRenderResources() {
        guard canRender, renderedFrames.isEmpty, let configuration else { return }
        let frameCount = configuration.shouldAnimate
            ? configuration.character.archetype.frameCount
            : 1
        renderedFrames = (0..<frameCount).compactMap { phase in
            Self.render(
                configuration.character.frame(
                    status: configuration.status,
                    phase: phase
                ),
                colors: configuration.colors
            )
        }
        guard let first = renderedFrames.first else { return }
        withoutImplicitAnimations {
            spriteLayer.contents = first
        }
        if configuration.shouldAnimate, renderedFrames.count > 1 {
            startAnimation(interval: configuration.animationInterval)
        }
    }

    private func startAnimation(interval: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: #keyPath(CALayer.contents))
        animation.values = renderedFrames.map { $0 as Any }
        animation.keyTimes = renderedFrames.indices.map {
            NSNumber(value: Double($0) / Double(renderedFrames.count))
        }
        animation.calculationMode = .discrete
        animation.duration = max(0.2, interval) * Double(renderedFrames.count)
        animation.repeatCount = .infinity
        animation.beginTime = spriteLayer.convertTime(CACurrentMediaTime(), from: nil)
        animation.isRemovedOnCompletion = true
        spriteLayer.add(animation, forKey: Self.animationKey)
    }

    private func releaseRenderResources() {
        spriteLayer.removeAnimation(forKey: Self.animationKey)
        withoutImplicitAnimations {
            spriteLayer.contents = nil
        }
        renderedFrames.removeAll(keepingCapacity: false)
    }

    private func layoutSpriteLayer() {
        let scale = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        let pixelSize = CGFloat(
            CovePixelCharacterGeometry.pixelSize(
                availableWidth: Double(bounds.width),
                availableHeight: Double(bounds.height),
                backingScale: Double(scale)
            )
        )
        let drawingWidth = CGFloat(CovePixelFrame.gridWidth) * pixelSize
        let drawingHeight = CGFloat(CovePixelFrame.gridHeight) * pixelSize
        let originX = ((bounds.width - drawingWidth) * scale / 2).rounded(.down) / scale
        let originY = ((bounds.height - drawingHeight) * scale / 2).rounded(.down) / scale
        withoutImplicitAnimations {
            spriteLayer.contentsScale = scale
            spriteLayer.frame = CGRect(
                x: originX,
                y: originY,
                width: drawingWidth,
                height: drawingHeight
            )
        }
    }

    private func withoutImplicitAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }

    private static func render(
        _ frame: CovePixelFrame,
        colors: CovePixelSpriteColors
    ) -> CGImage? {
        let width = CovePixelFrame.gridWidth
        let height = CovePixelFrame.gridHeight
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for pixel in frame.pixels {
            context.setFillColor(colors.color(for: pixel.ink))
            context.fill(
                CGRect(
                    x: pixel.x,
                    y: height - pixel.y - 1,
                    width: 1,
                    height: 1
                )
            )
        }
        return context.makeImage()
    }

    private struct Configuration: Equatable {
        let character: CovePixelCharacter
        let status: CoveSessionStatus
        let colors: CovePixelSpriteColors
        let reduceMotion: Bool
        let animationInterval: TimeInterval

        var shouldAnimate: Bool {
            !reduceMotion && character.animates(status: status)
        }
    }
}

private struct CovePixelSpriteColors: Equatable {
    let outline: CovePixelRGBA
    let body: CovePixelRGBA
    let accent: CovePixelRGBA
    let activity: CovePixelRGBA

    init(palette: CovePixelCharacterPalette) {
        outline = CovePixelRGBA(palette.outline)
        body = CovePixelRGBA(palette.body)
        accent = CovePixelRGBA(palette.accent)
        activity = CovePixelRGBA(palette.activity)
    }

    func color(for ink: CovePixelInk) -> CGColor {
        switch ink {
        case .outline: outline.cgColor
        case .body: body.cgColor
        case .accent: accent.cgColor
        case .activity: activity.cgColor
        }
    }
}

private struct CovePixelRGBA: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
        alpha = converted.alphaComponent
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension CoveThemePalette {
    func characterStatusHex(_ status: CoveSessionStatus) -> String {
        switch status {
        case .waitingApproval, .blocked: waitingApprovalHex
        case .waitingInput: waitingInputHex
        case .working, .active: workingHex
        case .compacting: compactingHex
        case .completed: completedHex
        case .failed: failedHex
        case .interrupted: interruptedHex
        case .idle, .listening, .quiet, .hidden: idleHex
        }
    }
}

private extension CoveSessionStatus {
    var accessibilityLabel: String {
        rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}
