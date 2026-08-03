import SwiftUI
import CoveCore

struct CoveProjectTokenEditor: View {
    // SwiftUI's `.delete` is U+0008, while AppKit text fields and XCUITest
    // report the standard backward-delete key as NSDeleteCharacter (U+007F).
    private static let backwardDeleteKeys: Set<KeyEquivalent> = [
        .delete,
        KeyEquivalent("\u{7F}"),
    ]

    @Binding var tokens: [String]
    let suggestions: [String]
    let accessibilityIdentifier: String

    @State private var draft = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tokens.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        tokenView(token, at: index)
                    }
                }
            }

            HStack {
                TextField("Add a project or task identity", text: $draft)
                    .onSubmit { commit([draft]) }
                    .onChange(of: draft) { _, newValue in
                        commitCommaSeparatedInput(newValue)
                    }
                    .onKeyPress(keys: Self.backwardDeleteKeys) { _ in
                        guard draft.isEmpty, !tokens.isEmpty else { return .ignored }
                        tokens.removeLast()
                        validationMessage = nil
                        return .handled
                    }
                    .accessibilityLabel("Add silenced project")
                    .accessibilityHint("Press Return or comma to add a token. Press Delete in an empty field to remove the last token.")
                    .accessibilityIdentifier("\(accessibilityIdentifier).field")

                Menu("Suggestions") {
                    if availableSuggestions.isEmpty {
                        Text("No current suggestions")
                    } else {
                        ForEach(Array(availableSuggestions.enumerated()), id: \.offset) {
                            index, suggestion in
                            Button(suggestion) {
                                commit([suggestion])
                            }
                            .accessibilityIdentifier(
                                "\(accessibilityIdentifier).suggestion.\(index)"
                            )
                        }
                    }
                }
                .disabled(availableSuggestions.isEmpty)
                .accessibilityLabel("Silenced project suggestions")
                .accessibilityIdentifier("\(accessibilityIdentifier).suggestions")
            }

            HStack {
                Text("\(tokens.count) of \(CoveSilencedProjectRules.maximumCount) rules")
                    .coveSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                if let validationMessage {
                    Text(validationMessage)
                        .coveSystemFont(size: 11)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "\(accessibilityIdentifier).validation"
                        )
                }
            }
        }
    }

    private var availableSuggestions: [String] {
        CoveSilencedProjectRules.normalize(suggestions).filter { suggestion in
            !CoveSilencedProjectRules.containsEquivalent(tokens, to: suggestion)
        }
    }

    private func tokenView(_ token: String, at index: Int) -> some View {
        HStack(spacing: 5) {
            Text(token)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("Silenced project, \(token)")
            Spacer(minLength: 0)
            Button {
                guard tokens.indices.contains(index) else { return }
                tokens.remove(at: index)
                validationMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove silenced project \(token)")
            .accessibilityIdentifier(
                "\(accessibilityIdentifier).token.\(index).remove"
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private func commitCommaSeparatedInput(_ value: String) {
        guard value.contains(",") else { return }
        let pieces = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        let endsWithComma = value.last == ","
        let candidates = endsWithComma ? pieces : Array(pieces.dropLast())
        draft = endsWithComma ? "" : pieces.last ?? ""
        commit(candidates, clearsDraft: false)
    }

    private func commit(
        _ candidates: [String],
        clearsDraft: Bool = true
    ) {
        let nonEmptyCandidates = candidates.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonEmptyCandidates.isEmpty else {
            if clearsDraft { draft = "" }
            validationMessage = nil
            return
        }

        let normalizedExisting = CoveSilencedProjectRules.normalize(tokens)
        let combined = CoveSilencedProjectRules.normalize(
            normalizedExisting + nonEmptyCandidates
        )
        let addedCount = combined.count - normalizedExisting.count
        if addedCount == 0 {
            if combined != tokens { tokens = combined }
            validationMessage = tokens.count >= CoveSilencedProjectRules.maximumCount
                ? String(localized: "The 100-rule limit is reached.")
                : String(localized: "That rule is already added.")
        } else {
            tokens = combined
            validationMessage = combined.count >= CoveSilencedProjectRules.maximumCount
                && addedCount < nonEmptyCandidates.count
                ? String(localized: "Only the first 100 unique rules were added.")
                : nil
        }
        if clearsDraft { draft = "" }
    }
}
