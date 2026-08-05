import Foundation

public enum CoveResidentSet: String, Codable, CaseIterable, Sendable {
    case dungeonAndDragons
    case techCreatures
    case virusAndBacteria

    public var displayName: String {
        switch self {
        case .dungeonAndDragons: "Dungeon / D&D"
        case .techCreatures: "Tech Creatures"
        case .virusAndBacteria: "Virus / Bacteria"
        }
    }

    public var archetypes: [CovePixelCharacterArchetype] {
        switch self {
        case .dungeonAndDragons:
            [.beaconKeeper, .lanternScribe, .mossRanger, .duneScout, .harborMage,
             .emberArchivist]
        case .techCreatures:
            [.cloudTinkerer, .tidePilot, .starCartographer, .pebbleBot, .prismDiver]
        case .virusAndBacteria:
            [.shellRunner, .coralCourier, .kelpMechanic, .cometGardener, .moonSkipper]
        }
    }
}

/// A clean-room, tiny pixel resident used to give a Codex Cove session a stable visual identity.
/// The character contains no person-derived artwork: an identity string only selects a deterministic
/// archetype and variation locally.
public struct CovePixelCharacter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let archetype: CovePixelCharacterArchetype
    public let variation: Int

    public var id: String { "\(archetype.rawValue)-\(variation)" }

    /// Color metadata which a UI can blend with its active theme.
    public var colorway: CovePixelColorway {
        archetype.colorway.adjusted(for: variation)
    }

    public init(archetype: CovePixelCharacterArchetype, variation: Int = 0) {
        self.archetype = archetype
        self.variation = max(0, variation % 4)
    }

    /// Returns the same character for the same identity on every platform and process launch.
    public static func assigned(
        to identity: String,
        set: CoveResidentSet = .dungeonAndDragons
    ) -> CovePixelCharacter {
        let hash = stableHash(identity.isEmpty ? "codex-cove" : identity)
        let archetypes = set.archetypes
        let archetypeIndex = Int(hash % UInt64(archetypes.count))
        let variation = Int((hash >> 17) % 4)
        return CovePixelCharacter(
            archetype: archetypes[archetypeIndex],
            variation: variation
        )
    }

    public static func stableHash(_ value: String) -> UInt64 {
        // FNV-1a is deliberately specified here rather than using Swift's randomized Hasher.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    public func animates(status: CoveSessionStatus) -> Bool {
        archetype.animates(status: status)
    }

    public func calloutGlyph(status: CoveSessionStatus) -> CovePixelCalloutGlyph? {
        archetype.calloutGlyph(status: status)
    }

    public func frame(status: CoveSessionStatus, phase: Int) -> CovePixelFrame {
        archetype.frame(status: status, phase: phase, variation: variation)
    }
}

/// Hue seeds are intentionally UI-framework independent. A SwiftUI palette can convert each hue
/// to `Color` and temper its saturation/brightness against the selected Cove theme.
public struct CovePixelColorway: Codable, Equatable, Hashable, Sendable {
    public let seed: UInt64
    public let bodyHueDegrees: Double
    public let accentHueDegrees: Double
    public let activityHueDegrees: Double
    public let saturation: Double
    public let brightness: Double

    public init(
        seed: UInt64,
        bodyHueDegrees: Double,
        accentHueDegrees: Double,
        activityHueDegrees: Double,
        saturation: Double,
        brightness: Double
    ) {
        self.seed = seed
        self.bodyHueDegrees = Self.normalizedHue(bodyHueDegrees)
        self.accentHueDegrees = Self.normalizedHue(accentHueDegrees)
        self.activityHueDegrees = Self.normalizedHue(activityHueDegrees)
        self.saturation = min(1, max(0, saturation))
        self.brightness = min(1, max(0, brightness))
    }

    public func adjusted(for variation: Int) -> CovePixelColorway {
        let normalizedVariation = max(0, variation % 4)
        let shift = Double(normalizedVariation * 7)
        return CovePixelColorway(
            seed: seed &+ UInt64(normalizedVariation),
            bodyHueDegrees: bodyHueDegrees + shift,
            accentHueDegrees: accentHueDegrees + shift,
            activityHueDegrees: activityHueDegrees + shift,
            saturation: saturation,
            brightness: brightness
        )
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }
}

public enum CovePixelCalloutGlyph: String, Codable, CaseIterable, Sendable {
    case exclamation
    case question
    case lock
    case checkmark
    case xmark
    case stop
}

public enum CovePixelCharacterArchetype: String, Codable, CaseIterable, Sendable {
    case beaconKeeper
    case shellRunner
    case lanternScribe
    case cloudTinkerer
    case mossRanger
    case tidePilot
    case starCartographer
    case coralCourier
    case pebbleBot
    case duneScout
    case harborMage
    case prismDiver
    case kelpMechanic
    case cometGardener
    case emberArchivist
    case moonSkipper

    public var displayName: String {
        switch self {
        case .beaconKeeper: "Beacon keeper"
        case .shellRunner: "Capsule runner"
        case .lanternScribe: "Lantern scribe"
        case .cloudTinkerer: "Cloud tinkerer"
        case .mossRanger: "Moss ranger"
        case .tidePilot: "Tide pilot"
        case .starCartographer: "Star cartographer"
        case .coralCourier: "Coccus courier"
        case .pebbleBot: "Pebble bot"
        case .duneScout: "Dune scout"
        case .harborMage: "Harbor mage"
        case .prismDiver: "Prism diver"
        case .kelpMechanic: "Bacillus mechanic"
        case .cometGardener: "Spore gardener"
        case .emberArchivist: "Ember archivist"
        case .moonSkipper: "Flagellum skipper"
        }
    }

    public var colorway: CovePixelColorway {
        switch self {
        case .beaconKeeper: .init(seed: 0xB001, bodyHueDegrees: 43, accentHueDegrees: 8, activityHueDegrees: 54, saturation: 0.72, brightness: 0.94)
        case .shellRunner: .init(seed: 0xB002, bodyHueDegrees: 25, accentHueDegrees: 196, activityHueDegrees: 36, saturation: 0.65, brightness: 0.88)
        case .lanternScribe: .init(seed: 0xB003, bodyHueDegrees: 268, accentHueDegrees: 42, activityHueDegrees: 30, saturation: 0.61, brightness: 0.91)
        case .cloudTinkerer: .init(seed: 0xB004, bodyHueDegrees: 201, accentHueDegrees: 332, activityHueDegrees: 184, saturation: 0.57, brightness: 0.96)
        case .mossRanger: .init(seed: 0xB005, bodyHueDegrees: 112, accentHueDegrees: 52, activityHueDegrees: 137, saturation: 0.68, brightness: 0.82)
        case .tidePilot: .init(seed: 0xB006, bodyHueDegrees: 213, accentHueDegrees: 177, activityHueDegrees: 193, saturation: 0.74, brightness: 0.92)
        case .starCartographer: .init(seed: 0xB007, bodyHueDegrees: 247, accentHueDegrees: 58, activityHueDegrees: 286, saturation: 0.63, brightness: 0.93)
        case .coralCourier: .init(seed: 0xB008, bodyHueDegrees: 352, accentHueDegrees: 23, activityHueDegrees: 12, saturation: 0.71, brightness: 0.95)
        case .pebbleBot: .init(seed: 0xB009, bodyHueDegrees: 222, accentHueDegrees: 166, activityHueDegrees: 311, saturation: 0.48, brightness: 0.86)
        case .duneScout: .init(seed: 0xB00A, bodyHueDegrees: 38, accentHueDegrees: 18, activityHueDegrees: 63, saturation: 0.59, brightness: 0.89)
        case .harborMage: .init(seed: 0xB00B, bodyHueDegrees: 284, accentHueDegrees: 189, activityHueDegrees: 303, saturation: 0.69, brightness: 0.91)
        case .prismDiver: .init(seed: 0xB00C, bodyHueDegrees: 188, accentHueDegrees: 316, activityHueDegrees: 167, saturation: 0.66, brightness: 0.96)
        case .kelpMechanic: .init(seed: 0xB00D, bodyHueDegrees: 143, accentHueDegrees: 32, activityHueDegrees: 82, saturation: 0.64, brightness: 0.84)
        case .cometGardener: .init(seed: 0xB00E, bodyHueDegrees: 328, accentHueDegrees: 79, activityHueDegrees: 16, saturation: 0.7, brightness: 0.94)
        case .emberArchivist: .init(seed: 0xB00F, bodyHueDegrees: 7, accentHueDegrees: 44, activityHueDegrees: 21, saturation: 0.73, brightness: 0.9)
        case .moonSkipper: .init(seed: 0xB010, bodyHueDegrees: 232, accentHueDegrees: 62, activityHueDegrees: 259, saturation: 0.62, brightness: 0.92)
        }
    }

    /// The frame catalog stays four-wide for renderer API compatibility.
    public var frameCount: Int { 4 }

    public func animates(status: CoveSessionStatus) -> Bool {
        switch status {
        case .working, .active, .compacting:
            true
        case .waitingApproval, .waitingInput, .blocked,
             .completed, .failed, .interrupted,
             .idle, .listening, .quiet, .hidden:
            false
        }
    }

    public func calloutGlyph(status: CoveSessionStatus) -> CovePixelCalloutGlyph? {
        switch status {
        case .waitingApproval: .exclamation
        case .waitingInput: .question
        case .blocked: .lock
        case .completed: .checkmark
        case .failed: .xmark
        case .interrupted: .stop
        case .working, .active, .compacting,
             .idle, .listening, .quiet, .hidden:
            nil
        }
    }

    fileprivate func frame(
        status: CoveSessionStatus,
        phase: Int,
        variation: Int
    ) -> CovePixelFrame {
        let normalizedPhase = ((phase % frameCount) + frameCount) % frameCount
        var pixels = Self.pixels(in: baseRows, variation: variation)
        if animates(status: status) {
            pixels.append(contentsOf: activityPose[normalizedPhase].map {
                CovePixel(x: $0.0, y: $0.1, ink: .activity)
            })
        } else if let glyph = calloutGlyph(status: status) {
            pixels.append(contentsOf: Self.calloutPixels(glyph))
        }
        return CovePixelFrame(pixels: pixels)
    }

    private var baseRows: [String] {
        let art: String
        switch self {
        case .beaconKeeper:
            art = """
            ....AAA.....
            ...AOOOA....
            ....OBO.....
            ...OBOBO....
            ....OOO.....
            ...OOOOO....
            ..OOBBBOO...
            .A.OBOBO.A..
            ...OBBBO....
            ...OBBBO....
            ...OO.OO....
            ..OO...OO...
            .OO.....OO..
            ............
            """
        case .shellRunner:
            art = """
            ....A..A....
            ...A....A...
            ..A.OOOO.A..
            .A.OABBAO.A.
            ..OBBBBBBO..
            A.OBABABBO.A
            ..OBBBBBBO..
            .A.OABBAO.A.
            ..A.OOOO.A..
            ...A....A...
            ....A..A....
            .....AA.....
            ............
            ............
            """
        case .lanternScribe:
            art = """
            .....A......
            ....AAA.....
            ....OOO.....
            ...OBOBO....
            ....OOO.....
            ....OBO.....
            ..O.OBO.O...
            ..OAOBBAO...
            ..O.OBBO.O..
            ....OBB.....
            ...OO.OO....
            ...O...O....
            ..OO...OO...
            ............
            """
        case .cloudTinkerer:
            art = """
            ...OOOOO....
            ..OOAAOOO...
            .OOOBOBOOO..
            ..OOBBBOO...
            ...OOOOO....
            .A..OBO..A..
            OOOOBBBOOOOO
            .A.OBBBO.A..
            ...OBBBO....
            ...OOOOO....
            ...OO.OO....
            ..OO...OO...
            ..O.....O...
            ............
            """
        case .mossRanger:
            art = """
            ..A.....A...
            .AAA...AAA..
            ..A.OOO.A...
            ...OBOBO....
            ...OOOOO....
            ..AOBBBOA...
            .AAOBBBOAA..
            ..AOBBBOA...
            ...OBBBO....
            ..AOBBBOA...
            .AAOOOOOAA..
            ...OO.OO....
            ..OO...OO...
            ............
            """
        case .tidePilot:
            art = """
            ....AAAA....
            ..AAOOOOAA..
            .A.OBOBO.A..
            .A.OOOOO.A..
            ..AAOOOAA...
            ....OBO.....
            .A.OOBBO.A..
            AA.OBBBO.AA.
            .A.OBBBO.A..
            ...OBBBO....
            .A.OO.OO.A..
            AAO.....OAA.
            .A.......A..
            ............
            """
        case .starCartographer:
            art = """
            .....A......
            ....AAA.....
            ..A.AAA.A...
            ...AOOOA....
            ...OBOBO....
            ...OOOOO....
            ..AOBBBOA...
            .A.OBBBO.A..
            ...OBBBO....
            ..AOBBBOA...
            .A.OOOOO.A..
            ...OO.OO....
            ..O.....O...
            ............
            """
        case .coralCourier:
            art = """
            ............
            ..AOOOOA....
            .AOBBBBOA...
            AOBABBBBOA..
            .OBBBBBBO...
            ..OABBBA....
            ...OOOO.....
            .......AOOA.
            ......AOBBOA
            .......OBBO.
            .......OOOO.
            ............
            ............
            ............
            """
        case .pebbleBot:
            art = """
            ....A.......
            ....A.......
            ..OOOOOOO...
            .OOABOBAOO..
            .OOBBBBBOO..
            .OOOOOOOOO..
            ..OABBBAO...
            ..OBOBOBO...
            ..OABBBAO...
            ..OOOOOOO...
            ..OO...OO...
            .OOO...OOO..
            .O.O...O.O..
            ............
            """
        case .duneScout:
            art = """
            .......A....
            ..AAAAAAAA..
            .AAAAAAAAAA.
            ...OBOBO....
            ...OOOOO....
            ..AOBBBOA...
            .AAOBBBOA...
            ...OBBBO....
            ...OBBOA....
            ...OO.AOO...
            ..OO....OO..
            .OO......OO.
            ............
            ............
            """
        case .harborMage:
            art = """
            .....A.....A
            ....AAA....A
            ...AAAAA...A
            ..AAOOOAA..A
            ...OBOBO...A
            ...OOOOO...A
            ..AOBBBOA..A
            .A.OBBBO.A.A
            ...OBBBO..AA
            ..AOBBBOA..A
            .AAOOOOOAA.A
            ...OO.OO...A
            ..OO...OO..A
            ..........AA
            """
        case .prismDiver:
            art = """
            ...AAAAAA...
            ..AOOOOOOA..
            .AOOABOBOOA.
            .AOOBBBBOOA.
            .AOOOOOOOOA.
            ..AAOOOOAA..
            ...OBBBO....
            .A.OBBBO.A..
            AA.OBBBO.AA.
            .A.OBBBO.A..
            ...OO.OO....
            .AAO...OAA..
            AA.......AA.
            ............
            """
        case .kelpMechanic:
            art = """
            ............
            ..A......A..
            ...OOOOOO...
            ..OABBBBBO..
            .OBBBBBBBBO.
            AOBABBBBBBOA
            .OBBBBBBBBO.
            ..OABBBBBO..
            ...OOOOOO...
            A..........A
            .A........A.
            ..AA....AA..
            ............
            ............
            """
        case .cometGardener:
            art = """
            ....AAAA....
            ..AAOOOOAA..
            .AOBBBBOA...
            AOBABBBBOA..
            OBBBBBBBBBO.
            OBBABBABBBO.
            .OBBBBBBBO..
            ..OOBBBBO...
            ...OOOOO....
            ....A.A.....
            ...A...A....
            ............
            ............
            ............
            """
        case .emberArchivist:
            art = """
            ....A.A.....
            ...AAAAA....
            ....AAA.....
            ...OBOBO....
            ...OOOOO....
            ..OOBBBOO...
            .AAOBBBOAA..
            A.OOBBBOO.A.
            .A.OAAAO.A..
            ...OBBBO....
            ..AOOOOOA...
            ...OO.OO....
            ..OO...OO...
            ............
            """
        case .moonSkipper:
            art = """
            ...A........
            ..A.........
            .A.OOOOO....
            A.OABBBBO...
            .OBBBBBBBO..
            .OBABABABO..
            .OBBBBBBBO..
            ..OABBBBO...
            ...OOOOO....
            ....A.......
            .....A......
            ......AA....
            ........AA..
            ..........A.
            """
        }
        return art.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func pixels(in rows: [String], variation: Int) -> [CovePixel] {
        rows.enumerated().flatMap { y, row in
            row.enumerated().compactMap { x, character in
                let ink: CovePixelInk?
                switch character {
                case "O": ink = .outline
                case "B": ink = .body
                case "A": ink = .accent
                default: ink = nil
                }
                guard let ink else { return nil }
                // A stable highlight lets two residents of one archetype remain distinguishable.
                let resolvedInk: CovePixelInk = ink == .accent
                    || (ink == .body && (x + y + variation) % 17 == 0)
                    ? .accent
                    : ink
                return CovePixel(x: x, y: y, ink: resolvedInk)
            }
        }
    }

    /// Each resident owns an activity silhouette (signal sweep, parcel pass, spell orbit, etc.).
    /// Every catalog contains exactly four visibly different motion poses.
    private var activityPose: [[(Int, Int)]] {
        switch self {
        case .beaconKeeper:
            [[(7, 2), (8, 1), (9, 0)], [(8, 3), (10, 3), (11, 3)], [(7, 4), (8, 5), (9, 6)], [(3, 3), (1, 3), (0, 3)]]
        case .shellRunner:
            [[(1, 9), (0, 10), (1, 11)], [(2, 9), (1, 11), (0, 11)], [(6, 9), (7, 11), (8, 11)], [(7, 8), (9, 9), (10, 10)]]
        case .lanternScribe:
            [[(1, 5), (1, 6), (2, 7)], [(1, 4), (1, 5), (2, 6)], [(8, 6), (9, 6), (9, 7)], [(8, 5), (9, 5), (10, 5)]]
        case .cloudTinkerer:
            [[(8, 4), (9, 3), (10, 2)], [(8, 5), (9, 4), (10, 3)], [(7, 6), (8, 6), (9, 6)], [(7, 7), (8, 7), (9, 7)]]
        case .mossRanger:
            [[(1, 8), (0, 7), (0, 6)], [(1, 8), (0, 8), (0, 7)], [(9, 8), (10, 7), (10, 6)], [(9, 8), (10, 8), (10, 7)]]
        case .tidePilot:
            [[(0, 9), (1, 8), (2, 9)], [(2, 10), (3, 9), (4, 10)], [(7, 10), (8, 9), (9, 10)], [(9, 9), (10, 8), (11, 9)]]
        case .starCartographer:
            [[(1, 2), (2, 2), (3, 3)], [(8, 1), (9, 2), (8, 3)], [(9, 7), (10, 7), (9, 8)], [(1, 7), (2, 8), (3, 8)]]
        case .coralCourier:
            [[(1, 6), (2, 6), (2, 7)], [(2, 6), (3, 6), (3, 7)], [(8, 6), (9, 6), (9, 7)], [(9, 6), (10, 6), (10, 7)]]
        case .pebbleBot:
            [[(5, 1), (5, 0), (4, 0)], [(6, 1), (6, 0), (7, 0)], [(5, 1), (4, 1), (3, 1)], [(6, 1), (7, 1), (8, 1)]]
        case .duneScout:
            [[(8, 3), (9, 3), (10, 3)], [(9, 4), (10, 4), (11, 4)], [(8, 5), (9, 5), (10, 5)], [(7, 4), (8, 4), (9, 4)]]
        case .harborMage:
            [[(2, 3), (1, 2), (2, 1)], [(9, 2), (10, 2), (10, 3)], [(9, 8), (10, 8), (10, 9)], [(2, 8), (1, 8), (1, 9)]]
        case .prismDiver:
            [[(9, 8), (10, 7), (10, 6)], [(9, 7), (10, 6), (11, 5)], [(8, 6), (9, 5), (9, 4)], [(7, 5), (8, 4), (8, 3)]]
        case .kelpMechanic:
            [[(1, 7), (2, 6), (3, 6)], [(1, 8), (2, 7), (3, 7)], [(8, 7), (9, 6), (10, 6)], [(8, 8), (9, 7), (10, 7)]]
        case .cometGardener:
            [[(8, 5), (9, 6), (10, 7)], [(8, 6), (9, 7), (10, 8)], [(2, 9), (2, 8), (3, 8)], [(3, 9), (3, 8), (4, 8)]]
        case .emberArchivist:
            [[(1, 6), (2, 5), (3, 5)], [(1, 5), (2, 4), (3, 4)], [(8, 5), (9, 4), (10, 4)], [(8, 6), (9, 5), (10, 5)]]
        case .moonSkipper:
            [[(2, 10), (3, 9), (4, 8)], [(4, 8), (5, 7), (6, 6)], [(6, 6), (7, 7), (8, 8)], [(8, 8), (9, 9), (10, 10)]]
        }
    }

    private static func calloutPixels(_ glyph: CovePixelCalloutGlyph) -> [CovePixel] {
        let fill = (1...4).flatMap { y in
            (8...10).map { CovePixel(x: $0, y: y, ink: .body) }
        }
        let outlinePoints = [
            (8, 0), (9, 0), (10, 0),
            (7, 1), (11, 1), (7, 2), (11, 2),
            (7, 3), (11, 3), (7, 4), (11, 4),
            (8, 5), (9, 5), (10, 5), (10, 6),
        ]
        let glyphPoints: [(Int, Int)]
        switch glyph {
        case .exclamation:
            glyphPoints = [(9, 1), (9, 2), (9, 4)]
        case .question:
            glyphPoints = [(8, 1), (9, 1), (10, 2), (9, 3), (9, 4)]
        case .lock:
            glyphPoints = [(8, 2), (8, 1), (9, 0), (10, 1), (10, 2), (8, 3), (9, 3), (10, 3), (9, 4)]
        case .checkmark:
            glyphPoints = [(8, 3), (9, 4), (10, 3), (10, 2), (10, 1)]
        case .xmark:
            glyphPoints = [(8, 1), (10, 1), (9, 2), (8, 3), (10, 3)]
        case .stop:
            glyphPoints = [(8, 1), (9, 1), (10, 1), (8, 2), (10, 2), (8, 3), (9, 3), (10, 3)]
        }
        return fill
            + outlinePoints.map { CovePixel(x: $0.0, y: $0.1, ink: .outline) }
            + glyphPoints.map { CovePixel(x: $0.0, y: $0.1, ink: .activity) }
    }
}

public enum CovePixelInk: String, Codable, CaseIterable, Sendable {
    case outline
    case body
    case accent
    case activity
}

public struct CovePixel: Codable, Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let ink: CovePixelInk

    public init(x: Int, y: Int, ink: CovePixelInk) {
        self.x = x
        self.y = y
        self.ink = ink
    }
}

public struct CovePixelFrame: Codable, Equatable, Hashable, Sendable {
    public static let gridWidth = 12
    public static let gridHeight = 14

    public let pixels: [CovePixel]

    public init(pixels: [CovePixel]) {
        self.pixels = pixels
    }
}

public enum CovePixelCharacterGeometry {
    public static func pixelSize(
        availableWidth: Double,
        availableHeight: Double,
        backingScale: Double
    ) -> Double {
        let scale = max(1, backingScale)
        let rawPixelSize = min(
            max(0, availableWidth) / Double(CovePixelFrame.gridWidth),
            max(0, availableHeight) / Double(CovePixelFrame.gridHeight)
        )
        return max(1 / scale, floor(rawPixelSize * scale) / scale)
    }

    public static func spriteSize(
        availableWidth: Double,
        availableHeight: Double,
        backingScale: Double
    ) -> (width: Double, height: Double) {
        let pixel = pixelSize(
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            backingScale: backingScale
        )
        return (
            Double(CovePixelFrame.gridWidth) * pixel,
            Double(CovePixelFrame.gridHeight) * pixel
        )
    }
}
