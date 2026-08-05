import AppKit
import SwiftUI

extension Color {
    init(hex: String, opacity: Double = 1.0) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255.0
            g = Double((value & 0x00FF00) >> 8) / 255.0
            b = Double(value & 0x0000FF) / 255.0
        default:
            r = 1
            g = 1
            b = 1
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    var hex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> Int {
            Int((min(1, max(0, value)) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            byte(color.redComponent),
            byte(color.greenComponent),
            byte(color.blueComponent)
        )
    }
}
