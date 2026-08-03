import Foundation

/// Canonicalizes the user-owned list of project/task identities that suppress
/// alerts. The first spelling wins so the token field does not unexpectedly
/// rewrite text the user entered.
public enum CoveSilencedProjectRules {
    public static let maximumCount = 100

    public static func normalize(
        _ proposedRules: [String],
        maximumCount: Int = maximumCount
    ) -> [String] {
        guard maximumCount > 0 else { return [] }

        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(min(proposedRules.count, maximumCount))

        for proposedRule in proposedRules {
            let trimmed = proposedRule.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { continue }

            let comparisonKey = comparisonKey(for: trimmed)
            guard seen.insert(comparisonKey).inserted else { continue }

            normalized.append(trimmed)
            if normalized.count == maximumCount { break }
        }
        return normalized
    }

    public static func containsEquivalent(
        _ rules: [String],
        to candidate: String
    ) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let candidateKey = comparisonKey(for: trimmed)
        return rules.contains { comparisonKey(for: $0) == candidateKey }
    }

    private static func comparisonKey(for value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
