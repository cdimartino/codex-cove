import Foundation

public enum CoveJSONValue: Codable, Equatable, Sendable {
    case object([String: CoveJSONValue])
    case array([CoveJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CoveJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CoveJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var scalarStringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return Int64(exactly: value).map(String.init) ?? String(value)
        case let .bool(value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }

    public var objectValue: [String: CoveJSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [CoveJSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .number(value):
            return value.rounded() == value ? Int(exactly: value) : nil
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }
}

public enum CoveWireSource: String, Codable, CaseIterable, Sendable {
    case localCli
    case codexDesktop
    case remoteCli
}

/// An open string type: newer helpers and Codex versions can add event kinds
/// without making an older Cove app drop the complete envelope.
public struct CoveWireEventKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let sessionSnapshot = Self(rawValue: "session_snapshot")
    public static let sessionStatus = Self(rawValue: "session_status")
    public static let approvalRequest = Self(rawValue: "approval_request")
    public static let questionRequest = Self(rawValue: "question_request")
    public static let planSnapshot = Self(rawValue: "plan_snapshot")
    public static let display = Self(rawValue: "display")
    public static let notification = Self(rawValue: "notification")
    public static let command = Self(rawValue: "command")

    // Runtime kinds emitted by the Rust broker.
    public static let launch = Self(rawValue: "launch")
    public static let appServer = Self(rawValue: "appServer")
    public static let approvalRequested = Self(rawValue: "approvalRequested")
    public static let questionRequested = Self(rawValue: "questionRequested")
    public static let serverRequestResolved = Self(rawValue: "serverRequestResolved")
    public static let hook = Self(rawValue: "hook")
}

public struct CoveWireEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var eventId: String
    public var kind: CoveWireEventKind
    public var timestamp: Date
    public var source: CoveWireSource
    public var sessionId: String
    public var turnId: String?
    public var launchId: String?
    public var hostId: String?
    public var payload: CoveJSONValue

    public init(
        schemaVersion: Int = 1,
        eventId: String,
        kind: CoveWireEventKind,
        timestamp: Date,
        source: CoveWireSource,
        sessionId: String,
        turnId: String? = nil,
        launchId: String? = nil,
        hostId: String? = nil,
        payload: CoveJSONValue
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.kind = kind
        self.timestamp = timestamp
        self.source = source
        self.sessionId = sessionId
        self.turnId = turnId
        self.launchId = launchId
        self.hostId = hostId
        self.payload = payload
    }

    public func displayEvent() -> CoveEvent {
        let object = payloadObject
        let params = requestParameters
        let title = object["title"]?.stringValue
            ?? params["title"]?.stringValue
            ?? displayTitle(for: effectiveMethod)
        let body = object["body"]?.stringValue
            ?? params["reason"]?.stringValue
            ?? params["message"]?.stringValue
            ?? firstQuestionObject?["question"]?.stringValue
        return CoveEvent(
            kind: .display,
            title: title,
            body: body,
            source: source.rawValue,
            hostId: hostId,
            sessionId: sessionId,
            turnId: turnId,
            wireKind: kind.rawValue,
            timestamp: timestamp
        )
    }

    public func directRequest() -> CoveDirectRequest? {
        let object = payloadObject
        let message = brokerMessage
        let params = requestParameters
        let requestId = Self.requestID(object["requestId"])
            ?? Self.requestID(message["id"])
            ?? Self.requestID(object["id"])
            ?? .string(eventId)
        let decisionSocket = object["decisionSocket"]?.stringValue
        let rawTitle = params["title"]?.stringValue
            ?? params["question"]?.stringValue
            ?? params["summary"]?.stringValue
            ?? object["title"]?.stringValue
        let method = effectiveMethod

        switch method ?? kind.rawValue {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestApproval",
             "execCommandApproval",
             "applyPatchApproval",
             "hook/PermissionRequest",
             CoveWireEventKind.approvalRequest.rawValue,
             CoveWireEventKind.approvalRequested.rawValue:
            let category: CoveApprovalCategory = {
                switch method {
                case "item/fileChange/requestApproval":
                    return .file
                case "item/permissions/requestApproval", "hook/PermissionRequest":
                    return .permissions
                default:
                    return .command
                }
            }()
            let choiceValue = params["availableDecisions"]
                ?? object["availableDecisions"]
                ?? params["choices"]
                ?? object["choices"]
            return .approval(
                .init(
                    schemaVersion: schemaVersion,
                    category: category,
                    requestId: requestId,
                    launchId: launchId,
                    sessionId: sessionId,
                    turnId: turnId,
                    source: source,
                    hostId: hostId,
                    title: rawTitle ?? approvalTitle(from: params, category: category),
                    detail: params["reason"]?.stringValue
                        ?? params["detail"]?.stringValue
                        ?? object["detail"]?.stringValue
                        ?? object["body"]?.stringValue,
                    choices: advertisedApprovalChoices(
                        CoveChoice.fromJSONValueArray(choiceValue),
                        category: category,
                        choicesWereAdvertised: choiceValue != nil
                    ),
                    amendments: CoveChoice.fromJSONValueArray(params["amendments"] ?? object["amendments"]),
                    permissionProfile: (params["permissions"] ?? object["permissions"]).map {
                        CoveGrantedPermissionProfile(raw: $0)
                    },
                    decisionSocket: decisionSocket
                )
            )
        case "item/tool/requestUserInput",
             "requestUserInput",
             CoveWireEventKind.questionRequest.rawValue,
             CoveWireEventKind.questionRequested.rawValue:
            let questions = questionObjects(from: params).enumerated().map { index, question in
                CoveQuestionPrompt(
                    questionId: question["id"]?.scalarStringValue
                        ?? (index == 0
                            ? requestId.displayValue
                            : "\(requestId.displayValue)-\(index + 1)"),
                    header: question["header"]?.stringValue,
                    question: question["question"]?.stringValue
                        ?? (index == 0 ? rawTitle : nil)
                        ?? "Question",
                    options: advertisedQuestionChoices(
                        question["options"] ?? (index == 0 ? params["options"] : nil)
                    ),
                    allowsFreeform: question["isOther"]?.boolValue
                        ?? question["allowsFreeform"]?.boolValue
                        ?? (index == 0 ? params["isOther"]?.boolValue : nil)
                        ?? (index == 0 ? params["allowsFreeform"]?.boolValue : nil)
                        ?? false
                )
            }
            return .question(
                .init(
                    schemaVersion: schemaVersion,
                    requestId: requestId,
                    launchId: launchId,
                    sessionId: sessionId,
                    turnId: turnId,
                    source: source,
                    hostId: hostId,
                    questions: questions,
                    decisionSocket: decisionSocket
                )
            )
        case CoveWireEventKind.planSnapshot.rawValue:
            return .planSnapshot(
                .init(
                    schemaVersion: schemaVersion,
                    requestId: requestId,
                    launchId: launchId,
                    sessionId: sessionId,
                    turnId: turnId,
                    source: source,
                    hostId: hostId,
                    title: rawTitle ?? "Plan Snapshot",
                    steps: CovePlanStep.fromJSONValueArray(params["steps"] ?? object["steps"]),
                    decisionSocket: decisionSocket
                )
            )
        default:
            return nil
        }
    }

    public func sessionSnapshot() -> CoveSessionSnapshot? {
        let object = payloadObject
        if kind == .launch {
            let terminal = object["termProgram"]?.stringValue ?? "Terminal"
            let tty = object["tty"]?.stringValue
            return .init(
                schemaVersion: schemaVersion,
                snapshotId: launchId ?? eventId,
                status: .listening,
                priority: 10,
                title: "Codex CLI",
                detail: [terminal, tty].compactMap { $0 }.joined(separator: " · "),
                timestamp: timestamp,
                sessionId: sessionId,
                launchId: launchId,
                source: source,
                hostId: hostId,
                parentSessionId: parentSessionID(),
                liveness: object["liveness"]?.stringValue.flatMap(
                    CoveSessionLiveness.init(rawValue:)
                ),
                activeTurnId: object["activeTurnId"]?.scalarStringValue,
                controlRoute: object["controlRoute"]?.stringValue.flatMap(
                    CoveThreadControlRoute.init(rawValue:)
                )
            )
        }
        guard kind == .sessionSnapshot else { return nil }
        return .init(
            schemaVersion: schemaVersion,
            snapshotId: object["snapshotId"]?.stringValue ?? eventId,
            status: CoveSessionStatus(rawValue: object["status"]?.stringValue ?? "") ?? .idle,
            priority: object["priority"]?.intValue ?? 0,
            title: object["title"]?.stringValue ?? "Snapshot",
            detail: object["detail"]?.stringValue,
            latestOutput: object["latestOutput"]?.stringValue,
            timestamp: timestamp,
            sessionId: sessionId,
            launchId: launchId,
            source: source,
            hostId: hostId,
            parentSessionId: parentSessionID(),
            liveness: object["liveness"]?.stringValue.flatMap(
                CoveSessionLiveness.init(rawValue:)
            ),
            activeTurnId: object["activeTurnId"]?.scalarStringValue,
            controlRoute: object["controlRoute"]?.stringValue.flatMap(
                CoveThreadControlRoute.init(rawValue:)
            ),
            unread: object["unread"]?.boolValue ?? false
        )
    }

    public func sessionStatusUpdate() -> CoveSessionStatusUpdate? {
        let object = payloadObject
        if kind == .sessionStatus {
            return .init(
                schemaVersion: schemaVersion,
                status: CoveSessionStatus(rawValue: object["status"]?.stringValue ?? "") ?? .idle,
                priority: object["priority"]?.intValue ?? 0,
                summary: object["summary"]?.stringValue ?? object["title"]?.stringValue,
                timestamp: timestamp
            )
        }

        switch kind {
        case .approvalRequested:
            return .init(
                schemaVersion: schemaVersion,
                status: .waitingApproval,
                priority: 100,
                summary: "Waiting for approval",
                timestamp: timestamp
            )
        case .questionRequested:
            return .init(
                schemaVersion: schemaVersion,
                status: .waitingInput,
                priority: 95,
                summary: "Waiting for input",
                timestamp: timestamp
            )
        case .launch:
            return .init(
                schemaVersion: schemaVersion,
                status: .listening,
                priority: 10,
                summary: "Codex CLI connected",
                timestamp: timestamp
            )
        default:
            break
        }

        let params = requestParameters
        let method = effectiveMethod ?? ""
        if method.hasPrefix("hook/") {
            let mapped: (CoveSessionStatus, Int, String)? = switch method {
            case "hook/SessionStart":
                (.listening, 10, "Codex task started")
            case "hook/PermissionRequest":
                (.waitingApproval, 100, "Waiting for approval")
            case "hook/PreToolUse", "hook/PostToolUse", "hook/SubagentStart":
                (.working, 40, "Working")
            case "hook/PreCompact", "hook/PostCompact":
                (.compacting, 60, "Compacting")
            case "hook/Stop":
                (.completed, 80, "Completed")
            case "hook/SessionEnd":
                (.idle, 5, "Session ended")
            case "hook/SubagentStop":
                (.working, 40, "Subagent completed")
            default:
                nil
            }
            guard let mapped else { return nil }
            return .init(
                schemaVersion: schemaVersion,
                status: mapped.0,
                priority: mapped.1,
                summary: mapped.2,
                timestamp: timestamp
            )
        }
        if method == "thread/status/changed" {
            let statusObject = params["status"]?.objectValue ?? [:]
            let type = statusObject["type"]?.stringValue ?? params["status"]?.stringValue ?? ""
            let flags = statusObject["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let status: CoveSessionStatus
            let priority: Int
            if flags.contains(where: { $0.localizedCaseInsensitiveContains("approval") }) {
                status = .waitingApproval
                priority = 100
            } else if flags.contains(where: { $0.localizedCaseInsensitiveContains("input") }) {
                status = .waitingInput
                priority = 95
            } else if type.localizedCaseInsensitiveContains("compact") {
                status = .compacting
                priority = 60
            } else if type == "idle" {
                status = .idle
                priority = 5
            } else {
                status = .working
                priority = 40
            }
            return .init(
                schemaVersion: schemaVersion,
                status: status,
                priority: priority,
                summary: status.displayName,
                timestamp: timestamp
            )
        }

        let mapped: (CoveSessionStatus, Int, String)? = switch method {
        case "turn/started", "item/started":
            (.working, 40, "Working")
        case "thread/compacted", "turn/compacted":
            (.compacting, 60, "Compacting")
        case "turn/completed":
            (.completed, 80, "Completed")
        case "turn/aborted", "turn/interrupted":
            (.interrupted, 85, "Interrupted")
        case "error", "turn/failed":
            (.failed, 90, "Failed")
        default:
            nil
        }
        guard let mapped else { return nil }
        return .init(
            schemaVersion: schemaVersion,
            status: mapped.0,
            priority: mapped.1,
            summary: mapped.2,
            timestamp: timestamp
        )
    }

    public func latestAssistantOutput() -> String? {
        let item = requestParameters["item"]?.objectValue ?? requestParameters
        let raw = requestParameters["last_assistant_message"]?.stringValue
            ?? (effectiveMethod == "item/completed"
                && item["type"]?.stringValue == "agentMessage"
                ? item["text"]?.stringValue
                : nil)
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(4_000))
    }

    public func resolvedRequestID() -> CoveRequestID? {
        guard effectiveMethod == "serverRequest/resolved" || kind == .serverRequestResolved else {
            return nil
        }
        return Self.requestID(requestParameters["requestId"])
            ?? Self.requestID(brokerMessage["id"])
    }

    public func usageSnapshot() -> CoveUsageSnapshot? {
        let params = requestParameters
        if effectiveMethod == "account/rateLimits/updated"
            || params["rateLimits"]?.objectValue != nil {
            let result = brokerMessage["result"]
                ?? .object(params)
            return try? CoveRateLimitsSnapshotParser.snapshot(
                fromResult: result,
                capturedAt: timestamp,
                forcePartial: effectiveMethod == "account/rateLimits/updated"
            )
        }

        guard effectiveMethod == "thread/tokenUsage/updated",
              let tokenUsage = params["tokenUsage"]?.objectValue,
              let total = tokenUsage["total"]?.objectValue else {
            return nil
        }
        return CoveUsageSnapshot(
            tokenUsage: CoveTokenUsage(
                inputTokens: total["inputTokens"]?.intValue ?? 0,
                cachedInputTokens: total["cachedInputTokens"]?.intValue ?? 0,
                outputTokens: total["outputTokens"]?.intValue ?? 0,
                reasoningOutputTokens: total["reasoningOutputTokens"]?.intValue ?? 0,
                totalTokens: total["totalTokens"]?.intValue ?? 0,
                contextWindow: tokenUsage["modelContextWindow"]?.intValue
            ),
            capturedAt: timestamp,
            isPartial: true
        )
    }

    public func parentSessionID() -> String? {
        let params = requestParameters
        return params["parentThreadId"]?.scalarStringValue
            ?? params["parentSessionId"]?.scalarStringValue
            ?? params["parent_thread_id"]?.scalarStringValue
    }

    /// Returns only an ID carried by the authoritative turn-start event. Cove
    /// never guesses the active turn from recency or a status label.
    public func authoritativeStartedTurnID() -> String? {
        guard effectiveMethod == "turn/started" else { return nil }
        let params = requestParameters
        return params["turn"]?.objectValue?["id"]?.scalarStringValue
            ?? params["turnId"]?.scalarStringValue
            ?? turnId
    }

    public var endsActiveTurn: Bool {
        if let method = effectiveMethod, [
            "turn/completed",
            "turn/aborted",
            "turn/interrupted",
            "turn/failed",
        ].contains(method) {
            return true
        }
        guard effectiveMethod == "thread/status/changed" else { return false }
        let params = requestParameters
        return params["status"]?.objectValue?["type"]?.stringValue == "idle"
            || params["status"]?.stringValue == "idle"
    }

    public func terminalLocationMetadata() -> CoveTerminalLocationMetadata? {
        let object = payloadObject
        if kind.rawValue == "terminal.registered",
           let terminal = object["terminal"]?.objectValue,
           let identifier = terminal["terminalId"]?.scalarStringValue {
            let editorHost = object["editorHost"]?.objectValue ?? [:]
            let bundleIdentifier = editorHost["bundleIdentifier"]?.stringValue
            let normalizedBundle = bundleIdentifier?.lowercased() ?? ""
            let adapter = normalizedBundle.contains("cursor")
                || normalizedBundle.contains("todesktop")
                ? "cursor"
                : "vscode"
            return .init(
                adapter: adapter,
                locationIdentifier: identifier,
                hostBundleIdentifier: bundleIdentifier,
                focusSocketIdentifier: object["focusSocketId"]?.stringValue,
                editorTerminalIdentifier: identifier
            )
        }
        guard kind == .launch, let launchId else { return nil }
        let tmuxPane = object["tmuxPane"]?.stringValue
        let weztermPane = object["weztermPane"]?.stringValue
        let marker = object["oscMarker"]?.stringValue
        let tty = Self.persistableTTYIdentifier(object["tty"]?.stringValue)
        let program = object["termProgram"]?.stringValue?.lowercased() ?? ""
        let adapter: String
        if marker != nil {
            adapter = "remote-marker"
        } else if tmuxPane != nil {
            adapter = "tmux"
        } else if weztermPane != nil {
            adapter = "wezterm"
        } else if program.contains("iterm") {
            adapter = "iterm"
        } else if program.contains("ghostty") {
            adapter = "ghostty"
        } else if program.contains("warp") {
            adapter = "warp"
        } else if program.contains("cursor") {
            adapter = "cursor"
        } else if program.contains("vscode") || program.contains("code") {
            adapter = "vscode"
        } else {
            adapter = "terminal"
        }
        let locationIdentifier = marker
            ?? tmuxPane
            ?? weztermPane
            ?? tty
            ?? launchId
        return .init(
            adapter: adapter,
            locationIdentifier: locationIdentifier,
            hostBundleIdentifier: Self.terminalBundleIdentifier(for: program),
            tmuxPaneIdentifier: tmuxPane,
            weztermPaneIdentifier: weztermPane,
            ttyIdentifier: tty,
            oscMarkerIdentifier: marker
        )
    }

    /// Internal approval-review threads are implementation details of Codex's
    /// automated approval reviewer. They are not user tasks and must never
    /// become Cove sessions, attention requests, notifications, or history.
    ///
    /// Hook payloads expose the stable `codex-auto-review` model marker. The
    /// app-server exposes the canonical sub-agent source marker
    /// `source.subAgent.other == "guardian"` (older stored fixtures may use
    /// snake/lower camel spellings). Deliberately do not classify a normal
    /// parent merely because its settings select `auto_review`.
    public var isApprovalReviewSubagentEvent: Bool {
        if [
            "item/autoApprovalReview/started",
            "item/autoApprovalReview/completed",
        ].contains(effectiveMethod) {
            return true
        }
        if Self.isApprovalReviewModel(payloadObject["model"]?.scalarStringValue)
            || Self.isApprovalReviewModel(
                payloadObject["data"]?.objectValue?["model"]?.scalarStringValue
            )
        {
            return true
        }
        return approvalReviewThreadObjects.contains {
            Self.isApprovalReviewThreadObject($0)
        }
    }

    /// Public PermissionRequest hooks currently omit the per-request reviewer.
    /// Treat every current hook as native-only. A future protocol revision can
    /// add a versioned per-request discriminator. Authoritative app-server
    /// approval requests are unaffected.
    public var shouldDeferHookPermissionRequestToNative: Bool {
        isHookPermissionRequest
    }

    /// Canonical app-server thread identifier for an internal reviewer. Hook
    /// events intentionally return nil because subagent hooks share the parent
    /// session id; caching that id would incorrectly hide the parent task.
    public var approvalReviewSubagentThreadID: String? {
        for thread in approvalReviewThreadObjects
        where Self.isApprovalReviewThreadObject(thread) {
            if let identifier = thread["id"]?.scalarStringValue,
               !identifier.isEmpty {
                return identifier
            }
        }
        return nil
    }

    /// Stateless safety net used by the reducer, persistence, and notification
    /// classifier. `CoveEventVisibilityPolicy` adds cross-event thread tracking
    /// for later messages that no longer repeat the thread source marker.
    public var isPermanentlyHiddenInternalEvent: Bool {
        isApprovalReviewSubagentEvent
            || shouldDeferHookPermissionRequestToNative
    }

    private static func persistableTTYIdentifier(_ tty: String?) -> String? {
        guard let tty, tty.hasPrefix("/dev/") else { return nil }
        let components = tty.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy { scalar in
                      switch scalar.value {
                      case 48...57, 65...90, 97...122, 45, 46, 95:
                          return true
                      default:
                          return false
                      }
                  }
              }) else {
            return nil
        }
        return components.joined(separator: ":")
    }

    private static func terminalBundleIdentifier(for program: String) -> String? {
        if program.contains("ghostty") {
            return "com.mitchellh.ghostty"
        }
        if program.contains("warp") {
            return "dev.warp.Warp-Stable"
        }
        if program.contains("wezterm") {
            return "com.github.wez.wezterm"
        }
        if program.contains("iterm") {
            return "com.googlecode.iterm2"
        }
        if program.contains("cursor") {
            return "com.todesktop.230313mzl4w4u92"
        }
        if program.contains("vscode") || program.contains("code") {
            return "com.microsoft.VSCode"
        }
        return "com.apple.Terminal"
    }

    private var payloadObject: [String: CoveJSONValue] {
        payload.objectValue ?? [:]
    }

    private var brokerMessage: [String: CoveJSONValue] {
        payloadObject["message"]?.objectValue ?? payloadObject
    }

    private var requestParameters: [String: CoveJSONValue] {
        brokerMessage["params"]?.objectValue
            ?? payloadObject["params"]?.objectValue
            ?? payloadObject["data"]?.objectValue
            ?? payloadObject
    }

    private var effectiveMethod: String? {
        brokerMessage["method"]?.stringValue
            ?? payloadObject["method"]?.stringValue
            ?? payloadObject["hookEventName"]?.stringValue.map { "hook/\($0)" }
    }

    private var isHookPermissionRequest: Bool {
        effectiveMethod == "hook/PermissionRequest"
    }

    private var approvalReviewThreadObjects: [[String: CoveJSONValue]] {
        let message = brokerMessage
        let params = message["params"]?.objectValue ?? [:]
        let result = message["result"]?.objectValue ?? [:]
        return [
            payloadObject["thread"]?.objectValue,
            payloadObject["data"]?.objectValue?["thread"]?.objectValue,
            message["thread"]?.objectValue,
            params["thread"]?.objectValue,
            result["thread"]?.objectValue,
        ].compactMap { $0 }
    }

    private static func isApprovalReviewModel(_ value: String?) -> Bool {
        value == "codex-auto-review"
    }

    private static func isApprovalReviewThreadObject(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        if isApprovalReviewModel(thread["model"]?.scalarStringValue) {
            return true
        }
        guard let source = thread["source"]?.objectValue else { return false }
        let subagent = source["subAgent"]?.objectValue
            ?? source["subagent"]?.objectValue
            ?? source["sub_agent"]?.objectValue
        return subagent?["other"]?.scalarStringValue == "guardian"
    }

    private var firstQuestionObject: [String: CoveJSONValue]? {
        requestParameters["questions"]?.arrayValue?.first?.objectValue
    }

    private func questionObjects(
        from params: [String: CoveJSONValue]
    ) -> [[String: CoveJSONValue]] {
        let supplied = params["questions"]?.arrayValue?.compactMap(\.objectValue) ?? []
        return supplied.isEmpty ? [params] : supplied
    }

    private func advertisedQuestionChoices(_ value: CoveJSONValue?) -> [CoveChoice] {
        guard case let .array(items)? = value else { return [] }
        return items.enumerated().compactMap { index, item in
            if let label = item.stringValue, !label.isEmpty {
                return CoveChoice(identifier: label, label: label, raw: item)
            }
            let object = item.objectValue ?? [:]
            guard let label = object["label"]?.stringValue
                ?? object["title"]?.stringValue
                ?? object["value"]?.stringValue
                ?? object["decision"]?.stringValue,
                !label.isEmpty
            else {
                return nil
            }
            return CoveChoice(
                identifier: object["id"]?.stringValue
                    ?? object["identifier"]?.stringValue
                    ?? object["decision"]?.stringValue
                    ?? "\(index)",
                label: label,
                raw: item
            )
        }
    }

    private func displayTitle(for method: String?) -> String {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "item/permissions/requestApproval", "item/tool/requestApproval":
            return "Approval needed"
        case "hook/PermissionRequest":
            return "Approval needed"
        case "item/tool/requestUserInput", "requestUserInput":
            return "Input needed"
        case "serverRequest/resolved":
            return "Request resolved"
        case "thread/status/changed":
            return "Codex status"
        case "turn/completed":
            return "Task completed"
        case "turn/failed", "error":
            return "Task failed"
        case let value? where value.hasPrefix("hook/"):
            return "Codex task"
        case let value?:
            return value.replacingOccurrences(of: "/", with: " ").capitalized
        case nil:
            if kind == .appServer {
                return "Codex status"
            }
            return kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func approvalTitle(
        from params: [String: CoveJSONValue],
        category: CoveApprovalCategory
    ) -> String {
        if category == .command,
           let command = params["command"]?.arrayValue?.compactMap(\.scalarStringValue),
           !command.isEmpty {
            return command.joined(separator: " ")
        }
        switch category {
        case .command:
            return "Run command?"
        case .file:
            return "Apply file changes?"
        case .permissions:
            return "Permission request"
        }
    }

    private func advertisedApprovalChoices(
        _ choices: [CoveChoice],
        category: CoveApprovalCategory,
        choicesWereAdvertised: Bool
    ) -> [CoveChoice] {
        if !choices.isEmpty {
            return choices
        }
        guard !choicesWereAdvertised, category != .permissions else { return [] }
        return [
            .init(identifier: "accept", label: "Allow"),
            .init(identifier: "acceptForSession", label: "Allow for session"),
            .init(identifier: "decline", label: "Decline"),
            .init(identifier: "cancel", label: "Cancel"),
        ]
    }

    private static func requestID(_ value: CoveJSONValue?) -> CoveRequestID? {
        switch value {
        case let .string(value):
            return .string(value)
        case let .number(value):
            return Int64(exactly: value).map(CoveRequestID.integer)
        default:
            return nil
        }
    }

}

/// Stateful ingestion filter for Codex-internal approval review traffic.
/// A canonical thread-start event teaches the policy the reviewer's thread id;
/// later turn/status events for that id stay hidden even when Codex omits the
/// source object from those follow-up messages.
public struct CoveEventVisibilityPolicy: Equatable, Sendable {
    private var hiddenApprovalReviewThreadKeys: Set<String>

    public init() {
        self.hiddenApprovalReviewThreadKeys = []
    }

    public mutating func hideApprovalReviewThread(
        sessionId: String,
        source: CoveWireSource,
        hostId: String?
    ) {
        guard !sessionId.isEmpty,
              CoveOriginScope(source: source, hostId: hostId) != nil else {
            return
        }
        hiddenApprovalReviewThreadKeys.insert(
            CoveScopedIdentityKey.session(
                sessionId: sessionId,
                source: source,
                hostId: hostId
            )
        )
    }

    public mutating func shouldSuppress(_ envelope: CoveWireEnvelope) -> Bool {
        if let threadID = envelope.approvalReviewSubagentThreadID {
            hideApprovalReviewThread(
                sessionId: threadID,
                source: envelope.source,
                hostId: envelope.hostId
            )
        }
        return envelope.isPermanentlyHiddenInternalEvent
            || hiddenApprovalReviewThreadKeys.contains(envelope.scopedSessionKey)
    }
}

public struct CoveChoice: Codable, Equatable, Sendable {
    public var identifier: String
    public var label: String
    public var raw: CoveJSONValue?

    public init(identifier: String, label: String, raw: CoveJSONValue? = nil) {
        self.identifier = identifier
        self.label = label
        self.raw = raw
    }

    public static func fromJSONValueArray(_ value: CoveJSONValue?) -> [CoveChoice] {
        guard case let .array(items)? = value else { return [] }
        return items.enumerated().compactMap { index, item in
            if let label = item.stringValue, !label.isEmpty {
                return CoveChoice(identifier: label, label: label, raw: item)
            }
            let object = item.objectValue ?? [:]
            guard let label = object["label"]?.stringValue
                ?? object["title"]?.stringValue
                ?? object["value"]?.stringValue
                ?? object["decision"]?.stringValue,
                !label.isEmpty
            else {
                return nil
            }
            return CoveChoice(
                identifier: object["id"]?.stringValue
                    ?? object["identifier"]?.stringValue
                    ?? object["decision"]?.stringValue
                    ?? "\(index)",
                label: label,
                raw: item
            )
        }
    }
}

public struct CovePlanStep: Codable, Equatable, Sendable {
    public var title: String
    public var status: String
    public var detail: String?

    public init(title: String, status: String, detail: String? = nil) {
        self.title = title
        self.status = status
        self.detail = detail
    }

    public static func fromJSONValueArray(_ value: CoveJSONValue?) -> [CovePlanStep] {
        guard case let .array(items)? = value else { return [] }
        return items.map { item in
            let object = item.objectValue ?? [:]
            return CovePlanStep(
                title: object["title"]?.stringValue ?? object["name"]?.stringValue ?? "Step",
                status: object["status"]?.stringValue ?? "pending",
                detail: object["detail"]?.stringValue ?? object["body"]?.stringValue
            )
        }
    }
}

public struct CoveSessionStatusUpdate: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var status: CoveSessionStatus
    public var priority: Int
    public var summary: String?
    public var timestamp: Date

    public init(schemaVersion: Int = 1, status: CoveSessionStatus, priority: Int, summary: String?, timestamp: Date) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.priority = priority
        self.summary = summary
        self.timestamp = timestamp
    }
}

public enum CoveEventDecoder {
    public static func decodeLine(_ line: String) -> CoveWireEnvelope? {
        guard let data = line.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CoveWireEnvelope.self, from: data)
    }
}

private extension CoveJSONValue {
    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }
}
