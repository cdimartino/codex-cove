import Foundation
import UserNotifications
import CoveCore

final class CoveNotificationService:
    NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    var onOpenSession: (
        @MainActor @Sendable (
            _ sessionID: String,
            _ launchID: String?,
            _ turnID: String?,
            _ source: CoveWireSource?,
            _ hostID: String?
        ) -> Void
    )?

    private struct Scope: Hashable, Sendable {
        var sessionID: String
        var launchID: String?
        var turnID: String?
        var origin: CoveOriginScope
    }

    private struct Payload: Sendable {
        var semanticKey: String
        var identifier: String
        var scope: Scope
        var kind: CoveNotificationEventKind
        var rule: CoveNotificationRule
        var context: CoveNotificationDisplayContext
        var fallbackTitle: String
        var fallbackDetail: String?
        var redactsSensitiveContent: Bool
    }

    private struct PendingBatch: Sendable {
        var payload: Payload
        var count: Int
        var generation: Int
    }

    private let center: UNUserNotificationCenter
    private let deliveryQueue = DispatchQueue(
        label: "local.chris.codexcove.notifications",
        qos: .utility
    )
    private var pendingBatches: [String: PendingBatch] = [:]
    private var deliveredScopes: [String: Scope] = [:]
    private var requestedAuthorization = false

    override init() {
        self.center = .current()
        super.init()
        center.delegate = self
    }

    /// Cove notifications are intentionally launch-scoped. Attention that
    /// predates this process remains available in the native Codex UI and the
    /// Cove session list, but is never resurrected as a fresh system banner.
    func clearNotificationsFromEarlierLaunches() {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.pendingBatches.removeAll()
            self.deliveredScopes.removeAll()
            self.center.removeAllPendingNotificationRequests()
            self.center.removeAllDeliveredNotifications()
        }
    }

    func requestAuthorizationIfNeeded(enabled: Bool) {
        guard enabled, !requestedAuthorization else { return }
        requestedAuthorization = true
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    NSLog(
                        "Cove notification authorization failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func notify(
        envelope: CoveWireEnvelope,
        kind: CoveNotificationEventKind,
        rule: CoveNotificationRule,
        context: CoveNotificationDisplayContext,
        enabled: Bool,
        redactsSensitiveContent: Bool
    ) {
        guard enabled, rule.enabled else { return }
        guard let origin = envelope.originScope else { return }
        let scope = Scope(
            sessionID: envelope.sessionId,
            launchID: envelope.launchId,
            turnID: envelope.turnId,
            origin: origin
        )
        let semanticKey = CoveNotificationIdentity.semanticKey(
            kind: kind,
            envelope: envelope
        )
        let payload = Payload(
            semanticKey: semanticKey,
            identifier: "cove-\(kind.rawValue)-\(Self.stableHex(semanticKey))",
            scope: scope,
            kind: kind,
            rule: rule,
            context: context,
            fallbackTitle: envelope.displayEvent().title,
            fallbackDetail: envelope.displayEvent().body,
            redactsSensitiveContent: redactsSensitiveContent
        )

        deliveryQueue.async { [weak self] in
            guard let self,
                  self.deliveredScopes[semanticKey] == nil
            else { return }
            let previous = self.pendingBatches[semanticKey]
            let generation = (previous?.generation ?? 0) + 1
            self.pendingBatches[semanticKey] = PendingBatch(
                payload: payload,
                count: min(99, (previous?.count ?? 0) + 1),
                generation: generation
            )
            // Approval hooks may be satisfied immediately by Codex auto-review
            // or native handling. Their correlated resolution arrives within
            // the hook fallback window, so hold the banner long enough to
            // cancel that transient noise while remaining under two seconds
            // for a genuinely waiting approval.
            let debounce: TimeInterval = kind == .approval ? 1.75 : 0.45
            self.deliveryQueue.asyncAfter(deadline: .now() + debounce) { [weak self] in
                self?.flush(semanticKey: semanticKey, generation: generation)
            }
        }
    }

    func resolveAttention(
        sessionID: String,
        launchID: String?,
        turnID: String?,
        source: CoveWireSource,
        hostID: String?
    ) {
        guard !sessionID.isEmpty,
              let origin = CoveOriginScope(source: source, hostId: hostID) else {
            return
        }
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            let matchingPending = self.pendingBatches.compactMap { key, batch in
                self.matches(
                    batch.payload.scope,
                    sessionID: sessionID,
                    launchID: launchID,
                    turnID: turnID,
                    origin: origin
                ) ? (key, batch.payload.identifier) : nil
            }
            let matchingDelivered = self.deliveredScopes.compactMap { key, scope in
                self.matches(
                    scope,
                    sessionID: sessionID,
                    launchID: launchID,
                    turnID: turnID,
                    origin: origin
                ) ? (key, "cove-\(key.split(separator: "|").first ?? "attention")-\(Self.stableHex(key))") : nil
            }
            matchingPending.forEach { self.pendingBatches.removeValue(forKey: $0.0) }
            matchingDelivered.forEach { self.deliveredScopes.removeValue(forKey: $0.0) }
            let identifiers = Set(
                matchingPending.map(\.1) + matchingDelivered.map(\.1)
            )
            guard !identifiers.isEmpty else { return }
            self.center.removePendingNotificationRequests(
                withIdentifiers: Array(identifiers)
            )
            self.center.removeDeliveredNotifications(
                withIdentifiers: Array(identifiers)
            )
        }
    }

    func notifyFollowUp(
        sessionID: String,
        launchID: String?,
        source: CoveWireSource,
        hostID: String?,
        title: String?,
        rule: CoveNotificationRule,
        enabled: Bool,
        redactsSensitiveContent: Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard enabled, rule.enabled, !sessionID.isEmpty,
              let origin = CoveOriginScope(source: source, hostId: hostID) else {
            completion(false)
            return
        }
        let content = UNMutableNotificationContent()
        let presentation = CoveNotificationPresentationBuilder.presentation(
            kind: .followUp,
            rule: rule,
            context: CoveNotificationDisplayContext(taskTitle: title),
            fallbackTitle: String(localized: "Codex follow-up"),
            redactsSensitiveContent: redactsSensitiveContent,
            genericBodyWhenEmpty: redactsSensitiveContent
                ? String(localized: "A Codex task is ready for follow-up.")
                : String(localized: "Return to this Codex task.")
        )
        content.title = presentation.title
        content.body = presentation.body
        content.userInfo = [
            "sessionId": sessionID,
            "launchId": launchID ?? "",
            "turnId": "",
            "source": origin.source.rawValue,
            "hostId": origin.remoteHostId ?? "",
        ]
        let identity = CoveScopedIdentityKey.encode([
            origin.source.rawValue,
            origin.remoteHostId,
            sessionID,
            launchID ?? "",
        ])
        let request = UNNotificationRequest(
            identifier: "cove-follow-up-\(Self.stableHex(identity))",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog(
                    "Cove follow-up notification failed: \(error.localizedDescription)"
                )
            }
            completion(error == nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let sessionID = response.notification.request.content
                .userInfo["sessionId"] as? String,
              !sessionID.isEmpty
        else {
            return
        }
        let launchID = Self.optionalUserInfoString(
            response.notification.request.content.userInfo["launchId"]
        )
        let turnID = Self.optionalUserInfoString(
            response.notification.request.content.userInfo["turnId"]
        )
        let source = Self.optionalUserInfoString(
            response.notification.request.content.userInfo["source"]
        ).flatMap(CoveWireSource.init(rawValue:))
        let hostID = Self.optionalUserInfoString(
            response.notification.request.content.userInfo["hostId"]
        )
        Task { @MainActor [weak self] in
            self?.onOpenSession?(sessionID, launchID, turnID, source, hostID)
        }
    }

    private func flush(semanticKey: String, generation: Int) {
        guard let batch = pendingBatches[semanticKey],
              batch.generation == generation,
              deliveredScopes[semanticKey] == nil
        else { return }
        pendingBatches.removeValue(forKey: semanticKey)
        deliveredScopes[semanticKey] = batch.payload.scope

        let content = UNMutableNotificationContent()
        let presentation = Self.presentation(
            for: batch.payload,
            count: batch.count
        )
        content.title = presentation.title
        content.body = presentation.body
        content.userInfo = [
            "sessionId": batch.payload.scope.sessionID,
            "launchId": batch.payload.scope.launchID ?? "",
            "turnId": batch.payload.scope.turnID ?? "",
            "source": batch.payload.scope.origin.source.rawValue,
            "hostId": batch.payload.scope.origin.remoteHostId ?? "",
        ]
        let request = UNNotificationRequest(
            identifier: batch.payload.identifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog(
                    "Cove notification delivery failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func matches(
        _ scope: Scope,
        sessionID: String,
        launchID: String?,
        turnID: String?,
        origin: CoveOriginScope
    ) -> Bool {
        guard scope.sessionID == sessionID, scope.origin == origin else {
            return false
        }
        if let turnID { return scope.turnID == turnID }
        if let launchID { return scope.launchID == launchID }
        return true
    }

    private static func presentation(
        for payload: Payload,
        count: Int
    ) -> CoveNotificationPresentation {
        CoveNotificationPresentationBuilder.presentation(
            kind: payload.kind,
            rule: payload.rule,
            context: payload.context,
            fallbackTitle: payload.fallbackTitle,
            fallbackDetail: payload.fallbackDetail,
            redactsSensitiveContent: payload.redactsSensitiveContent,
            count: count
        )
    }

    private static func optionalUserInfoString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func stableHex(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
