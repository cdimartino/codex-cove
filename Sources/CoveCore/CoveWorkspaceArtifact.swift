import Foundation

/// A confirmation-only artifact discovered in live assistant output.
public struct CoveWorkspaceArtifactSuggestion: Equatable, Sendable, Identifiable {
    public var link: CoveWorkspaceLink
    public var sourceIdentity: CoveSessionIdentity

    public var id: String { "\(sourceIdentity.id)\u{0}\(link.url.absoluteString)" }

    public init(link: CoveWorkspaceLink, sourceIdentity: CoveSessionIdentity) {
        self.link = link
        self.sourceIdentity = sourceIdentity
    }
}

/// Shared structural and local-file safety policy for Workspace artifacts.
public enum CoveWorkspaceArtifactPolicy {
    public static let maximumSuggestionOutputs = 64
    public static let maximumSuggestionBytes = 64 * 1_024
    public static let maximumSuggestions = CoveWorkspaceLimits.linksPerCard

    private static let unsafeFileExtensions: Set<String> = [
        "app", "action", "command", "dmg", "fileloc", "inetloc", "pkg",
        "scpt", "terminal", "workflow", "sh", "bash", "zsh", "csh", "ksh",
    ]

    public static func canonicalPersistentURL(_ url: URL) -> URL? {
        guard url.absoluteString.utf8.count <= CoveWorkspaceLimits.linkURLBytes,
              !hasControlCharacters(url.absoluteString),
              let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https":
            guard url.host != nil, url.user == nil, url.password == nil else {
                return nil
            }
            return url
        case "file":
            guard url.isFileURL,
                  (url.host ?? "").isEmpty,
                  url.path.hasPrefix("/"),
                  !hasControlCharacters(url.path)
            else { return nil }
            return url.standardizedFileURL
        default:
            return nil
        }
    }

    /// Returns a canonical local document or non-package directory suitable
    /// for a deliberate open. Missing files are intentionally not accepted
    /// here, but may remain persisted as stale user-authored references.
    public static func safeExistingFileURL(_ url: URL) -> URL? {
        guard let candidate = canonicalPersistentURL(url), candidate.isFileURL else {
            return nil
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return nil
        }
        let extensionName = resolved.pathExtension.lowercased()
        guard !unsafeFileExtensions.contains(extensionName) else { return nil }
        if isDirectory.boolValue { return resolved }
        guard let attributes = try? manager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              !manager.isExecutableFile(atPath: resolved.path)
        else { return nil }
        return resolved
    }

    public static func suggestions(
        snapshots: [CoveSessionSnapshot],
        existingLinks: [CoveWorkspaceLink]
    ) -> [CoveWorkspaceArtifactSuggestion] {
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )
        var remainingBytes = maximumSuggestionBytes
        var seen = Set(existingLinks.compactMap { canonicalPersistentURL($0.url)?.absoluteString })
        var result: [CoveWorkspaceArtifactSuggestion] = []

        for snapshot in snapshots.prefix(maximumSuggestionOutputs) {
            guard let identity = snapshot.sessionIdentity,
                  let output = snapshot.latestOutput,
                  !output.isEmpty,
                  remainingBytes > 0
            else { continue }
            let text = String(decoding: output.utf8.prefix(remainingBytes), as: UTF8.self)
            remainingBytes -= text.utf8.count
            let candidates = urls(in: text, detector: detector, source: identity.source)
                + localPathURLs(in: text, source: identity.source)
            for candidate in candidates {
                guard let url = canonicalPersistentURL(candidate.url),
                      seen.insert(url.absoluteString).inserted,
                      result.count < maximumSuggestions
                else { continue }
                if url.isFileURL, safeExistingFileURL(url) == nil { continue }
                let label = candidate.label?.nilIfEmpty
                    ?? (url.isFileURL ? url.lastPathComponent : url.host ?? url.absoluteString)
                result.append(.init(
                    link: .init(label: label, url: url),
                    sourceIdentity: identity
                ))
            }
            if result.count == maximumSuggestions { break }
        }
        return result
    }

    private static func urls(
        in text: String,
        detector: NSDataDetector?,
        source: CoveWireSource
    ) -> [(label: String?, url: URL)] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
                    || (scheme == "file" && source != .remoteCli)
            else { return nil }
            return (nil, url)
        }
    }

    private static func localPathURLs(
        in text: String,
        source: CoveWireSource
    ) -> [(label: String?, url: URL)] {
        guard source != .remoteCli else { return [] }
        let patterns = [
            #"\[([^\]]+)\]\((?:<)?((?:file://)?/[^)>]+)(?:>)?\)"#,
            #"(?:`|\"|'|<)((?:file://)?/[^`\"'>]+)(?:`|\"|'|>)"#,
            #"(?:^|\s)((?:file://)?/[^\s]+)"#,
        ]
        return patterns.flatMap { pattern -> [(label: String?, url: URL)] in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return [(label: String?, url: URL)]()
            }
            let range = NSRange(text.startIndex..., in: text)
            return expression.matches(in: text, range: range).compactMap { match -> (label: String?, url: URL)? in
                let pathRange = match.range(at: match.numberOfRanges > 2 ? 2 : 1)
                guard let swiftRange = Range(pathRange, in: text) else { return nil }
                let raw = stripLocationSuffix(String(text[swiftRange]))
                let url = raw.hasPrefix("file://")
                    ? URL(string: raw)
                    : URL(fileURLWithPath: raw)
                guard let url else { return nil }
                let label: String?
                if match.numberOfRanges > 2,
                   let labelRange = Range(match.range(at: 1), in: text) {
                    label = String(text[labelRange])
                } else {
                    label = nil
                }
                return (label, url)
            }
        }
    }

    private static func stripLocationSuffix(_ value: String) -> String {
        value.replacingOccurrences(
            of: #":\d+(?::\d+)?$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
