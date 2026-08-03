import Foundation
import CoveCore

struct CovePendingDirtyExitConfirmation: Equatable, Sendable {
    let requestKey: CoveDirectRequestKey
    let destination: CoveOverlayPresentation
}

struct CoveApprovalDraft: Equatable, Sendable {
    let choice: CoveChoice
    let decision: CoveApprovalDecision

    var scopeLabel: String? {
        switch decision {
        case .accept:
            return "Allow once"
        case .acceptForSession:
            return "Allow for this task"
        case .decline, .cancel:
            return nil
        }
    }

    var requiresConfirmation: Bool {
        decision == .accept || decision == .acceptForSession
    }
}

struct CoveQuestionDraft: Equatable, Sendable {
    var answers: [String: [String]]

    init(answers: [String: [String]] = [:]) {
        self.answers = answers
    }

    var isDirty: Bool {
        answers.values.joined().contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum CoveActionDraft: Equatable, Sendable {
    case approval(CoveApprovalDraft)
    case question(CoveQuestionDraft)

    var isDirty: Bool {
        switch self {
        case .approval:
            return true
        case let .question(draft):
            return draft.isDirty
        }
    }
}

struct CoveActionDraftState: Equatable, Sendable {
    private(set) var requests: [CoveDirectRequestKey: CoveActionDraft] = [:]

    subscript(key: CoveDirectRequestKey) -> CoveActionDraft? {
        requests[key]
    }

    var dirtyRequestKeys: Set<CoveDirectRequestKey> {
        Set(requests.compactMap { $0.value.isDirty ? $0.key : nil })
    }

    var hasDirtyDrafts: Bool {
        requests.values.contains(where: \.isDirty)
    }

    func isDirty(_ key: CoveDirectRequestKey) -> Bool {
        requests[key]?.isDirty == true
    }

    func approval(for key: CoveDirectRequestKey) -> CoveApprovalDraft? {
        guard case let .approval(draft)? = requests[key] else { return nil }
        return draft
    }

    func question(for key: CoveDirectRequestKey) -> CoveQuestionDraft? {
        guard case let .question(draft)? = requests[key] else { return nil }
        return draft
    }

    mutating func setApproval(
        _ draft: CoveApprovalDraft,
        for key: CoveDirectRequestKey
    ) {
        requests[key] = .approval(draft)
    }

    mutating func setQuestionAnswers(
        _ answers: [String: [String]],
        for key: CoveDirectRequestKey
    ) {
        requests[key] = .question(CoveQuestionDraft(answers: answers))
    }

    mutating func setQuestionAnswer(
        _ answers: [String],
        questionID: String,
        for key: CoveDirectRequestKey
    ) {
        var draft = question(for: key) ?? CoveQuestionDraft()
        draft.answers[questionID] = answers
        requests[key] = .question(draft)
    }

    mutating func clear(_ key: CoveDirectRequestKey) {
        requests.removeValue(forKey: key)
    }

    mutating func retain(keys: Set<CoveDirectRequestKey>) {
        requests = requests.filter { keys.contains($0.key) }
    }
}

/// The exact immutable payload retained for a retry. `attemptID` also protects
/// the store from a stale async completion mutating a newer attempt.
struct CoveDecisionAttempt: Equatable, Sendable {
    let attemptID: UUID
    let request: CoveDirectRequest
    let frame: CoveDecisionFrame
    let socketPath: String

    init(
        attemptID: UUID = UUID(),
        request: CoveDirectRequest,
        frame: CoveDecisionFrame,
        socketPath: String
    ) {
        self.attemptID = attemptID
        self.request = request
        self.frame = frame
        self.socketPath = socketPath
    }

    var requestKey: CoveDirectRequestKey { request.key }

    func renewed() -> Self {
        Self(request: request, frame: frame, socketPath: socketPath)
    }
}

enum CoveDecisionDeliveryStatus: Equatable, Sendable {
    case staged
    case sending(CoveDecisionAttempt)
    case succeeded
    case failed(message: String, retry: CoveDecisionAttempt?)
}

struct CoveDecisionDeliveryState: Equatable, Sendable {
    private(set) var requests: [
        CoveDirectRequestKey: CoveDecisionDeliveryStatus
    ] = [:]

    func status(for key: CoveDirectRequestKey) -> CoveDecisionDeliveryStatus? {
        requests[key]
    }

    func isStaged(_ key: CoveDirectRequestKey) -> Bool {
        requests[key] == .staged
    }

    func isSending(_ key: CoveDirectRequestKey) -> Bool {
        guard case .sending? = requests[key] else { return false }
        return true
    }

    func isSending(
        _ key: CoveDirectRequestKey,
        attemptID: UUID
    ) -> Bool {
        guard case let .sending(attempt)? = requests[key] else { return false }
        return attempt.attemptID == attemptID
    }

    func isSucceeded(_ key: CoveDirectRequestKey) -> Bool {
        requests[key] == .succeeded
    }

    func errorMessage(for key: CoveDirectRequestKey) -> String? {
        guard case let .failed(message, _)? = requests[key] else { return nil }
        return message
    }

    func retryAttempt(for key: CoveDirectRequestKey) -> CoveDecisionAttempt? {
        guard case let .failed(_, retry)? = requests[key] else { return nil }
        return retry
    }

    func canBeginSending(_ key: CoveDirectRequestKey) -> Bool {
        switch requests[key] {
        case .sending?, .succeeded?:
            return false
        case nil, .staged?, .failed?:
            return true
        }
    }

    mutating func setStaged(_ key: CoveDirectRequestKey) {
        guard canBeginSending(key) else { return }
        requests[key] = .staged
    }

    mutating func clearStaged(_ key: CoveDirectRequestKey) {
        guard requests[key] == .staged else { return }
        requests.removeValue(forKey: key)
    }

    mutating func setSending(_ attempt: CoveDecisionAttempt) {
        requests[attempt.requestKey] = .sending(attempt)
    }

    mutating func setSucceeded(
        _ key: CoveDirectRequestKey,
        attemptID: UUID
    ) {
        guard isSending(key, attemptID: attemptID) else { return }
        requests[key] = .succeeded
    }

    mutating func setFailed(
        _ key: CoveDirectRequestKey,
        message: String,
        retry: CoveDecisionAttempt? = nil
    ) {
        requests[key] = .failed(message: message, retry: retry)
    }

    mutating func setFailed(
        _ attempt: CoveDecisionAttempt,
        message: String
    ) {
        guard isSending(
            attempt.requestKey,
            attemptID: attempt.attemptID
        ) else { return }
        requests[attempt.requestKey] = .failed(
            message: message,
            retry: attempt
        )
    }

    mutating func clear(_ key: CoveDirectRequestKey) {
        requests.removeValue(forKey: key)
    }

    mutating func retain(keys: Set<CoveDirectRequestKey>) {
        requests = requests.filter { keys.contains($0.key) }
    }
}

/// Result of asking to leave a focused action. This is deliberately pure so
/// presentation code can map it to either today's overlay or Milestone 2's
/// queue/focused navigation without owning draft policy.
enum CoveDirtyExitDisposition: Equatable, Sendable {
    case exit
    case confirmDiscard(CoveDirectRequestKey)

    static func resolve(
        requestKey: CoveDirectRequestKey?,
        drafts: CoveActionDraftState
    ) -> Self {
        guard let requestKey, drafts.isDirty(requestKey) else { return .exit }
        return .confirmDiscard(requestKey)
    }
}
