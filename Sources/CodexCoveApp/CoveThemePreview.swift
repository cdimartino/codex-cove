import CoveCore
import SwiftUI

struct CoveThemePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let theme: CoveThemePalette
    let collapsedOpacity: Double
    let expandedOpacity: Double
    let blur: CoveBlurStyle
    let privacy: CovePrivacyMode
    let squareTopCorners: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.name)
                        .coveThemeFont(
                            theme,
                            size: 13,
                            weight: fontWeight
                        )
                    Text("Live preview")
                        .coveSystemFont(size: 11)
                        .foregroundStyle(Color(hex: theme.mutedTextHex))
                }
                Spacer()
                Text("\(Int(collapsedOpacity * 100)) / \(Int(expandedOpacity * 100))%")
                    .coveSystemFont(size: 11)
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
            }

            HStack(spacing: 6) {
                swatch("Work", color: theme.workingHex)
                swatch("Approve", color: theme.waitingApprovalHex)
                swatch("Input", color: theme.waitingInputHex)
                swatch("Compact", color: theme.compactingHex)
            }
            HStack(spacing: 6) {
                swatch("Done", color: theme.completedHex)
                swatch("Failed", color: theme.failedHex)
                swatch("Stopped", color: theme.interruptedHex)
                swatch("Idle", color: theme.idleHex)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: theme.accentHex))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(blur.rawValue)
                Text("Noise \(Int(theme.noiseOpacity * 100))%")
                Text(
                    reduceMotion || !theme.animationEnabled
                        ? "Motion off"
                        : "\(Int(theme.animationDurationMilliseconds)) ms \(theme.animationEasing.rawValue)"
                )
            }
            .coveSystemFont(size: 11)
            .foregroundStyle(Color(hex: theme.mutedTextHex))
        }
        .foregroundStyle(Color(hex: theme.foregroundHex))
        .padding(14)
        // Reuse the production expanded surface. Preview and overlay now share
        // palette, opacity, blur, noise, border, shadow, and accessibility
        // override behavior instead of maintaining two approximations.
        .background {
            CoveBackdropView(
                theme: theme,
                opacity: expandedOpacity,
                blur: blur,
                privacy: privacy,
                squareTopCorners: squareTopCorners
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live preview of \(theme.name)")
    }

    private func swatch(_ label: String, color: String) -> some View {
        Text(label)
            .coveSystemFont(size: 11, weight: .semibold)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(hex: color).opacity(0.2))
            )
            .overlay {
                Capsule()
                    .stroke(Color(hex: color), lineWidth: 1)
            }
    }

    private var fontWeight: Font.Weight {
        switch theme.fontWeight {
        case .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        }
    }
}
