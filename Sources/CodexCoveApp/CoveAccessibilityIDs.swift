import Foundation
import CoveCore

/// Stable identifiers shared by SwiftUI views and XCUITests.
///
/// Dynamic request and question identifiers are represented by a deterministic
/// non-cryptographic fingerprint so AX metadata does not expose task IDs.
enum CoveAccessibilityIDs {
    static let overlayRoot = "cove.overlay.root"
    static let overlayExpand = "cove.overlay.expand"
    static let overlayCollapse = "cove.overlay.collapse"
    static let queuePrevious = "cove.queue.previous"
    static let queueNext = "cove.queue.next"

    enum ApprovalControl: String, Sendable {
        case container
        case category
        case source
        case consequence
        case scope
        case allowOnce = "allow-once"
        case allowForTask = "allow-for-task"
        case confirmAllow = "confirm-allow"
        case decline
        case cancel
        case deliveryStatus = "delivery-status"
        case retry
        case openInCodex = "open-in-codex"
    }

    enum DirtyExitControl: String, Sendable {
        case keepEditing = "keep-editing"
        case discard
    }

    static func approval(
        _ control: ApprovalControl,
        requestKey: CoveDirectRequestKey
    ) -> String {
        request(control.rawValue, requestKey: requestKey)
    }

    static func dirtyExit(
        _ control: DirtyExitControl,
        requestKey: CoveDirectRequestKey
    ) -> String {
        request("dirty.\(control.rawValue)", requestKey: requestKey)
    }

    static func questionContainer(
        requestKey: CoveDirectRequestKey
    ) -> String {
        request("question.container", requestKey: requestKey)
    }

    static func questionAnswer(
        requestKey: CoveDirectRequestKey,
        questionID: String
    ) -> String {
        request(
            "question.\(fingerprint(questionID)).answer",
            requestKey: requestKey
        )
    }

    static func questionChoice(
        requestKey: CoveDirectRequestKey,
        questionID: String,
        choiceID: String
    ) -> String {
        request(
            "question.\(fingerprint(questionID)).choice.\(fingerprint(choiceID))",
            requestKey: requestKey
        )
    }

    static func questionSend(requestKey: CoveDirectRequestKey) -> String {
        request("question.send", requestKey: requestKey)
    }

    static func settingsPane(_ pane: String) -> String {
        "cove.settings.pane.\(stableSlug(pane))"
    }

    static func settingsControl(_ control: String) -> String {
        "cove.settings.control.\(stableSlug(control))"
    }

    /// Returns a stable AX identifier without placing the local task/session ID
    /// itself in accessibility metadata.
    static func session(
        _ control: String,
        sessionID: String
    ) -> String {
        "cove.task.\(fingerprint(sessionID)).\(stableSlug(control))"
    }

    static func request(
        _ control: String,
        requestKey: CoveDirectRequestKey
    ) -> String {
        "cove.request.\(requestFingerprint(requestKey)).\(stableSlug(control))"
    }

    static func requestFingerprint(_ key: CoveDirectRequestKey) -> String {
        let requestID = switch key.requestId {
        case let .string(value):
            "s:\(value)"
        case let .integer(value):
            "i:\(value)"
        }
        return fingerprint([
            requestID,
            key.launchId ?? "-",
            key.sessionId,
            key.turnId ?? "-",
            key.source?.rawValue ?? "-",
            key.hostId ?? "-",
        ].joined(separator: "\u{1f}"))
    }

    private static func stableSlug(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(scalars).split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return collapsed.isEmpty ? fingerprint(value) : collapsed
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
