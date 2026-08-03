import Foundation

public enum CoveApprovalDecision: String, Codable, CaseIterable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

/// A JSON-RPC request identifier with its wire type preserved.
///
/// JSON-RPC treats a numeric ID and a string containing the same digits as
/// distinct identifiers. `displayValue` is only for UI and diagnostic labels;
/// encoding always writes the original scalar type.
public enum CoveRequestID:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral
{
    case string(String)
    case integer(Int64)

    public var displayValue: String {
        switch self {
        case let .string(value):
            return value
        case let .integer(value):
            return String(value)
        }
    }

    public init(_ value: String) {
        self = .string(value)
    }

    public init(_ value: Int64) {
        self = .integer(value)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "A request ID must be a JSON string or integer"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        }
    }
}

public struct CoveDecisionFrame: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var launchId: String?
    public var requestId: CoveRequestID
    public var result: CoveDecisionResult

    public init(
        schemaVersion: Int = 1,
        launchId: String?,
        requestId: CoveRequestID,
        result: CoveDecisionResult
    ) {
        self.schemaVersion = schemaVersion
        self.launchId = launchId
        self.requestId = requestId
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, launchId, requestId, result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.launchId = try container.decodeIfPresent(String.self, forKey: .launchId)
        self.requestId = try container.decode(CoveRequestID.self, forKey: .requestId)
        self.result = try container.decode(CoveDecisionResult.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(launchId, forKey: .launchId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(result, forKey: .result)
    }
}

public enum CoveDecisionResult: Codable, Equatable, Sendable {
    case approval(decision: CoveApprovalDecision, amendment: CoveJSONValue? = nil)
    case question(answers: [String: CoveQuestionAnswer])
    case permissions(profile: CoveJSONValue, scope: String)
    case planAcknowledged(raw: CoveJSONValue? = nil)
    case cancelled(reason: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case decision
        case amendment
        case answers
        case permissions
        case scope
        case raw
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decision = try container.decodeIfPresent(CoveApprovalDecision.self, forKey: .decision) {
            self = .approval(
                decision: decision,
                amendment: try container.decodeIfPresent(CoveJSONValue.self, forKey: .amendment)
            )
            return
        }
        if let answers = try container.decodeIfPresent(
            [String: CoveQuestionAnswer].self,
            forKey: .answers
        ) {
            self = .question(answers: answers)
            return
        }
        if let profile = try container.decodeIfPresent(CoveJSONValue.self, forKey: .permissions) {
            self = .permissions(
                profile: profile,
                scope: try container.decode(String.self, forKey: .scope)
            )
            return
        }
        if let raw = try container.decodeIfPresent(CoveJSONValue.self, forKey: .raw) {
            self = .planAcknowledged(raw: raw)
            return
        }
        self = .cancelled(reason: try container.decodeIfPresent(String.self, forKey: .reason))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approval(decision, amendment):
            try container.encode(decision, forKey: .decision)
            try container.encodeIfPresent(amendment, forKey: .amendment)
        case let .question(answers):
            try container.encode(answers, forKey: .answers)
        case let .permissions(profile, scope):
            try container.encode(profile, forKey: .permissions)
            try container.encode(scope, forKey: .scope)
        case let .planAcknowledged(raw):
            try container.encodeIfPresent(raw, forKey: .raw)
        case let .cancelled(reason):
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

public struct CoveQuestionAnswer: Codable, Equatable, Sendable {
    public var answers: [String]

    public init(answers: [String]) {
        self.answers = answers
    }
}

public struct CoveGrantedPermissionProfile: Codable, Equatable, Sendable {
    public var raw: CoveJSONValue

    public init(raw: CoveJSONValue) {
        self.raw = raw
    }
}

public enum CoveApprovalCategory: String, Codable, CaseIterable, Sendable {
    case command
    case file
    case permissions
}

public struct CoveApprovalRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var category: CoveApprovalCategory
    public var requestId: CoveRequestID
    public var launchId: String?
    public var sessionId: String
    public var turnId: String?
    public var source: CoveWireSource?
    public var hostId: String?
    public var title: String
    public var detail: String?
    public var choices: [CoveChoice]
    public var amendments: [CoveChoice]
    public var permissionProfile: CoveGrantedPermissionProfile?
    public var decisionSocket: String?

    public init(
        schemaVersion: Int,
        category: CoveApprovalCategory,
        requestId: CoveRequestID,
        launchId: String?,
        sessionId: String,
        turnId: String? = nil,
        source: CoveWireSource? = nil,
        hostId: String? = nil,
        title: String,
        detail: String?,
        choices: [CoveChoice],
        amendments: [CoveChoice],
        permissionProfile: CoveGrantedPermissionProfile?,
        decisionSocket: String?
    ) {
        self.schemaVersion = schemaVersion
        self.category = category
        self.requestId = requestId
        self.launchId = launchId
        self.sessionId = sessionId
        self.turnId = turnId
        self.source = source
        self.hostId = source == .remoteCli ? hostId : nil
        self.title = title
        self.detail = detail
        self.choices = choices
        self.amendments = amendments
        self.permissionProfile = permissionProfile
        self.decisionSocket = decisionSocket
    }
}

public struct CoveQuestionPrompt: Codable, Equatable, Sendable {
    public var questionId: String
    public var header: String?
    public var question: String
    public var options: [CoveChoice]
    public var allowsFreeform: Bool

    public init(
        questionId: String,
        header: String? = nil,
        question: String,
        options: [CoveChoice],
        allowsFreeform: Bool
    ) {
        self.questionId = questionId
        self.header = header
        self.question = question
        self.options = options
        self.allowsFreeform = allowsFreeform
    }
}

public struct CoveQuestionRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var requestId: CoveRequestID
    public var launchId: String?
    public var sessionId: String
    public var turnId: String?
    public var source: CoveWireSource?
    public var hostId: String?
    public var questions: [CoveQuestionPrompt]
    public var decisionSocket: String?

    /// Compatibility accessors for the original single-question request API.
    /// New consumers should render and answer every item in `questions`.
    public var questionId: String {
        questions.first?.questionId ?? requestId.displayValue
    }

    public var question: String {
        questions.first?.question ?? "Question"
    }

    public var options: [CoveChoice] {
        questions.first?.options ?? []
    }

    public var allowsFreeform: Bool {
        questions.first?.allowsFreeform ?? false
    }

    public init(
        schemaVersion: Int,
        requestId: CoveRequestID,
        questionId: String? = nil,
        launchId: String?,
        sessionId: String,
        turnId: String? = nil,
        source: CoveWireSource? = nil,
        hostId: String? = nil,
        question: String,
        options: [CoveChoice],
        allowsFreeform: Bool,
        decisionSocket: String?
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.launchId = launchId
        self.sessionId = sessionId
        self.turnId = turnId
        self.source = source
        self.hostId = source == .remoteCli ? hostId : nil
        self.questions = [
            CoveQuestionPrompt(
                questionId: questionId ?? requestId.displayValue,
                question: question,
                options: options,
                allowsFreeform: allowsFreeform
            )
        ]
        self.decisionSocket = decisionSocket
    }

    public init(
        schemaVersion: Int,
        requestId: CoveRequestID,
        launchId: String?,
        sessionId: String,
        turnId: String? = nil,
        source: CoveWireSource? = nil,
        hostId: String? = nil,
        questions: [CoveQuestionPrompt],
        decisionSocket: String?
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.launchId = launchId
        self.sessionId = sessionId
        self.turnId = turnId
        self.source = source
        self.hostId = source == .remoteCli ? hostId : nil
        self.questions = questions
        self.decisionSocket = decisionSocket
    }
}

public struct CovePlanSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var requestId: CoveRequestID
    public var launchId: String?
    public var sessionId: String
    public var turnId: String?
    public var source: CoveWireSource?
    public var hostId: String?
    public var title: String
    public var steps: [CovePlanStep]
    public var decisionSocket: String?

    public init(
        schemaVersion: Int,
        requestId: CoveRequestID,
        launchId: String?,
        sessionId: String,
        turnId: String? = nil,
        source: CoveWireSource? = nil,
        hostId: String? = nil,
        title: String,
        steps: [CovePlanStep],
        decisionSocket: String?
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.launchId = launchId
        self.sessionId = sessionId
        self.turnId = turnId
        self.source = source
        self.hostId = source == .remoteCli ? hostId : nil
        self.title = title
        self.steps = steps
        self.decisionSocket = decisionSocket
    }
}

public enum CoveDirectRequest: Codable, Equatable, Sendable {
    case approval(CoveApprovalRequest)
    case question(CoveQuestionRequest)
    case planSnapshot(CovePlanSnapshot)
}

/// The complete identity of a live Codex server request.
///
/// JSON-RPC request IDs are scoped to their connection. A numeric ID and a
/// string ID with the same display text are distinct, and two launches can
/// legitimately reuse the same ID. Source and remote-host identity are also
/// part of the connection scope. Cove therefore never keys request state by a
/// display string or request ID alone.
public struct CoveDirectRequestKey:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public var requestId: CoveRequestID
    public var launchId: String?
    public var sessionId: String
    public var turnId: String?
    public var source: CoveWireSource?
    public var hostId: String?

    public init(
        requestId: CoveRequestID,
        launchId: String?,
        sessionId: String,
        turnId: String? = nil,
        source: CoveWireSource? = nil,
        hostId: String? = nil
    ) {
        self.requestId = requestId
        self.launchId = launchId
        self.sessionId = sessionId
        self.turnId = turnId
        self.source = source
        self.hostId = source == .remoteCli ? hostId : nil
    }
}

public extension CoveDirectRequest {
    var key: CoveDirectRequestKey {
        CoveDirectRequestKey(
            requestId: requestId,
            launchId: launchId,
            sessionId: sessionId,
            turnId: turnId,
            source: source,
            hostId: hostId
        )
    }

    var requestId: CoveRequestID {
        switch self {
        case let .approval(request):
            return request.requestId
        case let .question(request):
            return request.requestId
        case let .planSnapshot(request):
            return request.requestId
        }
    }

    var launchId: String? {
        switch self {
        case let .approval(request):
            return request.launchId
        case let .question(request):
            return request.launchId
        case let .planSnapshot(request):
            return request.launchId
        }
    }

    var sessionId: String {
        switch self {
        case let .approval(request):
            return request.sessionId
        case let .question(request):
            return request.sessionId
        case let .planSnapshot(request):
            return request.sessionId
        }
    }

    var turnId: String? {
        switch self {
        case let .approval(request):
            return request.turnId
        case let .question(request):
            return request.turnId
        case let .planSnapshot(request):
            return request.turnId
        }
    }

    var source: CoveWireSource? {
        switch self {
        case let .approval(request):
            return request.source
        case let .question(request):
            return request.source
        case let .planSnapshot(request):
            return request.source
        }
    }

    var hostId: String? {
        guard source == .remoteCli else { return nil }
        switch self {
        case let .approval(request):
            return request.hostId
        case let .question(request):
            return request.hostId
        case let .planSnapshot(request):
            return request.hostId
        }
    }

    var decisionSocket: String? {
        switch self {
        case let .approval(request):
            return request.decisionSocket
        case let .question(request):
            return request.decisionSocket
        case let .planSnapshot(request):
            return request.decisionSocket
        }
    }
}
