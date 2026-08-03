import Foundation
import SwiftUI

/// A slider for fast changes paired with an exact numeric field and native
/// stepper for keyboard/pointer precision.
struct CovePrecisionControlRow: View {
    @Environment(\.coveTextScale) private var textScale
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let displayScale: Double
    let fractionDigits: Int
    let accessibilityIdentifier: String

    @FocusState private var fieldIsFocused: Bool
    @State private var draft: String
    @State private var validationMessage: String?

    init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        unit: String,
        displayScale: Double = 1,
        fractionDigits: Int = 0,
        accessibilityIdentifier: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.displayScale = displayScale
        self.fractionDigits = fractionDigits
        self.accessibilityIdentifier = accessibilityIdentifier
        _draft = State(
            initialValue: Self.format(
                value.wrappedValue * displayScale,
                fractionDigits: fractionDigits
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if textScale >= 1.5 {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                precisionSlider
                HStack(spacing: 10) {
                    exactValueField
                    unitLabel
                    Spacer(minLength: 8)
                    precisionStepper
                }
            } else {
                HStack(spacing: 8) {
                    Text(title)
                        .frame(minWidth: 142, alignment: .leading)
                    precisionSlider
                    exactValueField
                    unitLabel
                    precisionStepper
                }
            }

            if let validationMessage {
                Text(validationMessage)
                    .coveSystemFont(size: 11)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(accessibilityIdentifier).validation")
            }
        }
        .onChange(of: value) { _, newValue in
            // Binding changes can come from a sibling slider/stepper or a
            // reset button while AppKit still reports this field as focused.
            // Keep the editable draft synchronized so a later focus-loss
            // commit cannot restore the stale pre-reset value.
            draft = formatted(newValue)
            validationMessage = nil
        }
        .onChange(of: fieldIsFocused) { _, isFocused in
            if !isFocused { commitDraft() }
        }
    }

    private var precisionSlider: some View {
        Slider(value: $value, in: range, step: step)
            .accessibilityLabel(title)
            .accessibilityIdentifier("\(accessibilityIdentifier).slider")
    }

    private var exactValueField: some View {
        TextField("Value", text: $draft)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: textScale >= 1.5 ? 92 : 62)
            .textFieldStyle(.roundedBorder)
            .focused($fieldIsFocused)
            .onSubmit(commitDraft)
            .accessibilityLabel("\(title), exact value")
            .accessibilityIdentifier("\(accessibilityIdentifier).field")
    }

    private var unitLabel: some View {
        Text(unit)
            .foregroundStyle(.secondary)
            .frame(minWidth: textScale >= 1.5 ? 40 : 24, alignment: .leading)
    }

    private var precisionStepper: some View {
        Stepper(
            title,
            value: $value,
            in: range,
            step: step
        )
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Adjust \(title)")
        .accessibilityIdentifier("\(accessibilityIdentifier).stepper")
    }

    private func commitDraft() {
        guard let parsedDisplayValue = Self.parse(draft),
              parsedDisplayValue.isFinite,
              displayScale.isFinite,
              displayScale > 0
        else {
            validationMessage = String(localized: "Enter a number.")
            return
        }

        let precision = pow(10, Double(max(0, fractionDigits)))
        let roundedDisplayValue = (parsedDisplayValue * precision).rounded()
            / precision
        let proposedValue = roundedDisplayValue / displayScale
        guard range.contains(proposedValue) else {
            let lower = formatted(range.lowerBound)
            let upper = formatted(range.upperBound)
            validationMessage = String(
                localized: "Enter a value from \(lower) to \(upper) \(unit)."
            )
            return
        }

        value = proposedValue
        draft = formatted(proposedValue)
        validationMessage = nil
    }

    private func formatted(_ underlyingValue: Double) -> String {
        Self.format(
            underlyingValue * displayScale,
            fractionDigits: fractionDigits
        )
    }

    private static func format(
        _ value: Double,
        fractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func parse(_ value: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.isLenient = false
        guard let number = formatter.number(
            from: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
        return number.doubleValue
    }
}
