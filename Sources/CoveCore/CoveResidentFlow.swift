import Foundation

/// Geometry for the resident route shown in the collapsed Cove bubble.
///
/// The route starts on the outer left edge, passes through the lower lane, and
/// ends on the outer right edge. Keeping the coordinates in CoveCore makes the
/// capacity and bounds behavior deterministic and independently testable.
public struct CoveResidentFlowLayout: Equatable, Sendable {
    public enum Lane: String, Equatable, Sendable {
        case left
        case lower
        case right
    }

    public struct Slot: Identifiable, Equatable, Sendable {
        public let id: Int
        public let lane: Lane
        public let centerX: Double
        public let centerY: Double
        public let size: Double

        public init(
            id: Int,
            lane: Lane,
            centerX: Double,
            centerY: Double,
            size: Double
        ) {
            self.id = id
            self.lane = lane
            self.centerX = centerX
            self.centerY = centerY
            self.size = size
        }
    }

    public let width: Double
    public let height: Double
    public let topBandHeight: Double
    public let centerClearance: Double
    public let slots: [Slot]

    public var capacity: Int { slots.count }

    public static func resolve(
        width proposedWidth: Double,
        height proposedHeight: Double,
        topBandHeight proposedTopBandHeight: Double,
        centerClearance proposedCenterClearance: Double,
        lowerTrailingReservation proposedLowerTrailingReservation: Double = 0
    ) -> CoveResidentFlowLayout {
        let width = normalized(proposedWidth)
        let height = normalized(proposedHeight)
        let topBandHeight = min(
            height,
            normalized(proposedTopBandHeight)
        )
        let centerClearance = min(
            width,
            normalized(proposedCenterClearance)
        )
        let lowerBandHeight = max(0, height - topBandHeight)
        let sideWidth = max(0, (width - centerClearance) / 2)

        let minimumAvatarSize = 14.0
        let sideSpacing = 2.0
        let sideInnerInset = min(3, sideWidth)
        let sideUsableWidth = max(0, sideWidth - sideInnerInset)
        let sideAvatarSize = floor(min(
            max(0, topBandHeight - 2),
            sideUsableWidth
        ))
        let sideCapacity = laneCapacity(
            availableLength: sideUsableWidth,
            avatarSize: sideAvatarSize,
            spacing: sideSpacing,
            minimumAvatarSize: minimumAvatarSize
        )
        let sideCenterY = max(
            sideAvatarSize / 2,
            topBandHeight - 1 - sideAvatarSize / 2
        )

        var leftInnerToOuter: [Slot] = []
        var rightInnerToOuter: [Slot] = []
        if sideCapacity > 0 {
            for index in 0..<sideCapacity {
                let distance = sideAvatarSize / 2
                    + Double(index) * (sideAvatarSize + sideSpacing)
                leftInnerToOuter.append(Slot(
                    id: 0,
                    lane: .left,
                    centerX: sideWidth - sideInnerInset - distance,
                    centerY: sideCenterY,
                    size: sideAvatarSize
                ))
                rightInnerToOuter.append(Slot(
                    id: 0,
                    lane: .right,
                    centerX: sideWidth + centerClearance
                        + sideInnerInset + distance,
                    centerY: sideCenterY,
                    size: sideAvatarSize
                ))
            }
        }

        let lowerSpacing = 4.0
        let lowerLeadingInset = min(7, width)
        let remainingAfterLeadingInset = max(0, width - lowerLeadingInset)
        let lowerTrailingInset = min(7, remainingAfterLeadingInset)
        let reservation = min(
            normalized(proposedLowerTrailingReservation),
            max(0, remainingAfterLeadingInset - lowerTrailingInset)
        )
        let lowerUsableWidth = max(
            0,
            width - lowerLeadingInset - lowerTrailingInset - reservation
        )
        let lowerAvatarSize = floor(min(
            max(0, lowerBandHeight - 4),
            lowerUsableWidth
        ))
        let lowerCapacity = laneCapacity(
            availableLength: lowerUsableWidth,
            avatarSize: lowerAvatarSize,
            spacing: lowerSpacing,
            minimumAvatarSize: minimumAvatarSize
        )
        var lowerSlots: [Slot] = []
        if lowerCapacity > 0 {
            let occupiedWidth = Double(lowerCapacity) * lowerAvatarSize
                + Double(lowerCapacity - 1) * lowerSpacing
            let firstCenterX = lowerLeadingInset
                + (lowerUsableWidth - occupiedWidth) / 2
                + lowerAvatarSize / 2
            let centerY = topBandHeight + 2 + lowerAvatarSize / 2
            for index in 0..<lowerCapacity {
                lowerSlots.append(Slot(
                    id: 0,
                    lane: .lower,
                    centerX: firstCenterX
                        + Double(index) * (lowerAvatarSize + lowerSpacing),
                    centerY: centerY,
                    size: lowerAvatarSize
                ))
            }
        }

        // This order lets a resident move from the right edge, down through
        // the lower lane, and back up the left side as the visible window
        // advances. New residents enter at one route end while old ones leave
        // at the other, avoiding a cross-bubble wrap animation.
        let route = Array(leftInnerToOuter.reversed())
            + lowerSlots
            + rightInnerToOuter
        let identifiedRoute = route.enumerated().map { index, slot in
            Slot(
                id: index,
                lane: slot.lane,
                centerX: slot.centerX,
                centerY: slot.centerY,
                size: slot.size
            )
        }

        return CoveResidentFlowLayout(
            width: width,
            height: height,
            topBandHeight: topBandHeight,
            centerClearance: centerClearance,
            slots: identifiedRoute
        )
    }

    private static func normalized(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func laneCapacity(
        availableLength: Double,
        avatarSize: Double,
        spacing: Double,
        minimumAvatarSize: Double
    ) -> Int {
        guard avatarSize >= minimumAvatarSize,
              availableLength >= avatarSize
        else {
            return 0
        }
        return max(
            0,
            Int(floor((availableLength + spacing) / (avatarSize + spacing)))
        )
    }
}

/// Assigns residents to the finite route without dropping anyone permanently.
/// With overflow, each step shifts the visible window by one resident. Without
/// overflow, assignments stay fixed regardless of the requested step.
public enum CoveResidentFlowSequence {
    public struct Assignment: Equatable, Sendable {
        public let residentIndex: Int
        public let slotIndex: Int

        public init(residentIndex: Int, slotIndex: Int) {
            self.residentIndex = residentIndex
            self.slotIndex = slotIndex
        }
    }

    public static func assignments(
        residentCount proposedResidentCount: Int,
        slotCount proposedSlotCount: Int,
        step: Int
    ) -> [Assignment] {
        let residentCount = max(0, proposedResidentCount)
        let slotCount = max(0, proposedSlotCount)
        let visibleCount = min(residentCount, slotCount)
        guard residentCount > 0, visibleCount > 0 else { return [] }

        let startIndex = residentCount > visibleCount
            ? positiveModulo(step, divisor: residentCount)
            : 0
        return (0..<visibleCount).map { slotIndex in
            Assignment(
                residentIndex: (startIndex + slotIndex) % residentCount,
                slotIndex: slotIndex
            )
        }
    }

    public static func hiddenCount(
        residentCount: Int,
        slotCount: Int
    ) -> Int {
        max(0, residentCount - max(0, slotCount))
    }

    private static func positiveModulo(_ value: Int, divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
