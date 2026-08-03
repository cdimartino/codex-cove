import Foundation

public enum CoveNotificationEventKind:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case approval
    case input
    case completed
    case failed
    case interrupted
    case followUp

    public var displayName: String {
        switch self {
        case .approval: "Approval"
        case .input: "Question or input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .followUp: "Follow-up reminder"
        }
    }

    public static func classify(_ envelope: CoveWireEnvelope) -> Self? {
        guard !envelope.isPermanentlyHiddenInternalEvent else { return nil }
        if let request = envelope.directRequest() {
            switch request {
            case .approval:
                return .approval
            case .question:
                return .input
            case .planSnapshot:
                return nil
            }
        }
        guard let status = envelope.sessionStatusUpdate()?.status else {
            return nil
        }
        switch status {
        case .waitingApproval, .blocked:
            return .approval
        case .waitingInput:
            return .input
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .interrupted:
            return .interrupted
        default:
            return nil
        }
    }
}

public struct CoveNotificationRule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var includesTaskTitle: Bool
    public var includesDetail: Bool
    public var includesProject: Bool
    public var includesSource: Bool
    public var includesHost: Bool

    public init(
        enabled: Bool = true,
        includesTaskTitle: Bool = true,
        includesDetail: Bool = false,
        includesProject: Bool = true,
        includesSource: Bool = false,
        includesHost: Bool = false
    ) {
        self.enabled = enabled
        self.includesTaskTitle = includesTaskTitle
        self.includesDetail = includesDetail
        self.includesProject = includesProject
        self.includesSource = includesSource
        self.includesHost = includesHost
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, includesTaskTitle, includesDetail, includesProject
        case includesSource, includesHost
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            includesTaskTitle: try values.decodeIfPresent(
                Bool.self,
                forKey: .includesTaskTitle
            ) ?? true,
            includesDetail: try values.decodeIfPresent(
                Bool.self,
                forKey: .includesDetail
            ) ?? false,
            includesProject: try values.decodeIfPresent(
                Bool.self,
                forKey: .includesProject
            ) ?? true,
            includesSource: try values.decodeIfPresent(
                Bool.self,
                forKey: .includesSource
            ) ?? false,
            includesHost: try values.decodeIfPresent(
                Bool.self,
                forKey: .includesHost
            ) ?? false
        )
    }
}

public struct CoveNotificationPreferences: Codable, Equatable, Sendable {
    public var approval: CoveNotificationRule
    public var input: CoveNotificationRule
    public var completed: CoveNotificationRule
    public var failed: CoveNotificationRule
    public var interrupted: CoveNotificationRule
    public var followUp: CoveNotificationRule

    public init(
        approval: CoveNotificationRule = .init(),
        input: CoveNotificationRule = .init(includesDetail: true),
        completed: CoveNotificationRule = .init(),
        failed: CoveNotificationRule = .init(includesDetail: true),
        interrupted: CoveNotificationRule = .init(),
        followUp: CoveNotificationRule = .init()
    ) {
        self.approval = approval
        self.input = input
        self.completed = completed
        self.failed = failed
        self.interrupted = interrupted
        self.followUp = followUp
    }

    public func rule(for kind: CoveNotificationEventKind) -> CoveNotificationRule {
        switch kind {
        case .approval: approval
        case .input: input
        case .completed: completed
        case .failed: failed
        case .interrupted: interrupted
        case .followUp: followUp
        }
    }

    public mutating func set(
        _ rule: CoveNotificationRule,
        for kind: CoveNotificationEventKind
    ) {
        switch kind {
        case .approval: approval = rule
        case .input: input = rule
        case .completed: completed = rule
        case .failed: failed = rule
        case .interrupted: interrupted = rule
        case .followUp: followUp = rule
        }
    }

    private enum CodingKeys: String, CodingKey {
        case approval, input, completed, failed, interrupted, followUp
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        self.init(
            approval: try values.decodeIfPresent(
                CoveNotificationRule.self,
                forKey: .approval
            ) ?? defaults.approval,
            input: try values.decodeIfPresent(
                CoveNotificationRule.self,
                forKey: .input
            ) ?? defaults.input,
            completed: try values.decodeIfPresent(
                CoveNotificationRule.self,
                forKey: .completed
            ) ?? defaults.completed,
            failed: try values.decodeIfPresent(
                CoveNotificationRule.self,
                forKey: .failed
            ) ?? defaults.failed,
            interrupted: try values.decodeIfPresent(
                CoveNotificationRule.self,
                forKey: .interrupted
            ) ?? defaults.interrupted,
            followUp: try values.decodeIfPresent(
                CoveNotificationRule.self,
                forKey: .followUp
            ) ?? defaults.followUp
        )
    }
}

public enum CoveLaunchAlertPolicy {
    public static func eventOccurredAfterLaunch(
        _ envelope: CoveWireEnvelope,
        launchedAt: Date,
        observedAt: Date = Date()
    ) -> Bool {
        envelope.timestamp >= launchedAt && envelope.timestamp <= observedAt.addingTimeInterval(5)
    }
}

public enum CoveNotificationIdentity {
    /// A notification represents an attention state for one task turn, not
    /// one hook invocation. Parallel/retried hook events therefore collapse
    /// into a single launch-scoped banner.
    public static func semanticKey(
        kind: CoveNotificationEventKind,
        envelope: CoveWireEnvelope
    ) -> String {
        let scopeIdentity = envelope.turnId
            ?? envelope.launchId
            ?? envelope.sessionId
        let remoteHost = envelope.source == .remoteCli
            ? envelope.hostId
            : nil
        return kind.rawValue + "|" + CoveScopedIdentityKey.encode([
            envelope.source.rawValue,
            remoteHost,
            envelope.sessionId,
            scopeIdentity,
        ])
    }
}
