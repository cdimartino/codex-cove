import Foundation

public struct CoveNotificationDisplayContext: Equatable, Sendable {
    public var taskTitle: String?
    public var detail: String?
    public var project: String?
    public var source: String?
    public var host: String?

    public init(
        taskTitle: String? = nil,
        detail: String? = nil,
        project: String? = nil,
        source: String? = nil,
        host: String? = nil
    ) {
        self.taskTitle = taskTitle
        self.detail = detail
        self.project = project
        self.source = source
        self.host = host
    }
}

public struct CoveNotificationPresentation: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// One pure formatter shared by delivered notifications and the Settings
/// preview. Keeping redaction at this boundary makes it impossible for preview
/// content switches to bypass privacy behavior.
public enum CoveNotificationPresentationBuilder {
    public static func presentation(
        kind: CoveNotificationEventKind,
        rule: CoveNotificationRule,
        context: CoveNotificationDisplayContext,
        fallbackTitle: String? = nil,
        fallbackDetail: String? = nil,
        redactsSensitiveContent: Bool,
        count: Int = 1,
        genericBodyWhenEmpty: String = ""
    ) -> CoveNotificationPresentation {
        let boundedCount = max(1, count)
        if redactsSensitiveContent {
            return CoveNotificationPresentation(
                title: boundedCount > 1
                    ? "\(boundedCount) Codex tasks need attention"
                    : genericTitle(for: kind),
                body: "Sensitive details are hidden by Codex Cove privacy."
            )
        }

        let preferredTitle = context.taskTitle?.coveNonEmpty
            ?? fallbackTitle?.coveNonEmpty
        let title = rule.includesTaskTitle
            ? preferredTitle ?? genericTitle(for: kind)
            : genericTitle(for: kind)

        var body: [String] = []
        if boundedCount > 1 {
            body.append("\(boundedCount) related requests")
        }
        if rule.includesDetail,
           let detail = context.detail?.coveNonEmpty
            ?? fallbackDetail?.coveNonEmpty {
            body.append(detail)
        }
        if rule.includesProject,
           let project = context.project?.coveNonEmpty {
            body.append("Project: \(project)")
        }
        if rule.includesSource,
           let source = context.source?.coveNonEmpty {
            body.append(source)
        }
        if rule.includesHost,
           let host = context.host?.coveNonEmpty {
            body.append("Host: \(host)")
        }

        return CoveNotificationPresentation(
            title: title,
            body: body.isEmpty ? genericBodyWhenEmpty : body.joined(separator: " · ")
        )
    }

    public static func genericTitle(
        for kind: CoveNotificationEventKind
    ) -> String {
        switch kind {
        case .approval: "Codex approval needed"
        case .input: "Codex needs input"
        case .completed: "Codex task completed"
        case .failed: "Codex task failed"
        case .interrupted: "Codex task interrupted"
        case .followUp: "Codex follow-up"
        }
    }
}

private extension String {
    var coveNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
