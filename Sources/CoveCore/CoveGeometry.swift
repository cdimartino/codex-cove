import Foundation

public struct CoveScreenMetrics: Codable, Equatable, Sendable {
    public var screenWidth: Double
    public var screenHeight: Double
    public var safeAreaTop: Double
    public var safeAreaLeft: Double
    public var safeAreaRight: Double
    public var auxiliaryTopLeftWidth: Double
    public var auxiliaryTopRightWidth: Double

    public init(
        screenWidth: Double,
        screenHeight: Double,
        safeAreaTop: Double,
        safeAreaLeft: Double = 0,
        safeAreaRight: Double = 0,
        auxiliaryTopLeftWidth: Double = 0,
        auxiliaryTopRightWidth: Double = 0
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.safeAreaTop = safeAreaTop
        self.safeAreaLeft = safeAreaLeft
        self.safeAreaRight = safeAreaRight
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }

    public var availableTopWidth: Double {
        max(0, screenWidth - safeAreaLeft - safeAreaRight)
    }

    /// Width of the centered top obstruction reported by public auxiliary
    /// menu-bar geometry. Displays without a notch report no auxiliary pair.
    public var topObstructionWidth: Double {
        guard auxiliaryTopLeftWidth > 0, auxiliaryTopRightWidth > 0 else {
            return 0
        }
        return max(
            0,
            screenWidth - auxiliaryTopLeftWidth - auxiliaryTopRightWidth
        )
    }
}

public struct CoveNotchLayout: Codable, Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double
    public var insetFromTop: Double

    public init(originX: Double, originY: Double, width: Double, height: Double, insetFromTop: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.insetFromTop = insetFromTop
    }
}

public enum CoveGeometryResolver {
    public static func topCenterLayout(
        for screen: CoveScreenMetrics,
        desiredWidth: Double,
        desiredHeight: Double,
        topGap: Double = 8
    ) -> CoveNotchLayout {
        let usableWidth = min(desiredWidth, screen.availableTopWidth)
        let centeredX = max(screen.safeAreaLeft, (screen.screenWidth - usableWidth) / 2)
        let originY = max(0, screen.screenHeight - screen.safeAreaTop - topGap - desiredHeight)
        return CoveNotchLayout(
            originX: centeredX,
            originY: originY,
            width: usableWidth,
            height: desiredHeight,
            insetFromTop: topGap + screen.safeAreaTop
        )
    }
}
