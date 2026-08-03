import Foundation
import CoveCore

private let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fatalError("Milestone 2 foundation test failed: \(message)")
    }
}

private func snapshot(
    _ id: String,
    status: CoveSessionStatus,
    priority: Int,
    seconds: TimeInterval,
    sessionId: String? = nil,
    launchId: String? = nil
) -> CoveSessionSnapshot {
    CoveSessionSnapshot(
        snapshotId: id,
        status: status,
        priority: priority,
        title: id,
        timestamp: referenceDate.addingTimeInterval(seconds),
        sessionId: sessionId,
        launchId: launchId
    )
}

private func approval(
    _ id: String,
    sessionId: String,
    launchId: String
) -> CoveDirectRequest {
    .approval(
        CoveApprovalRequest(
            schemaVersion: 1,
            category: .command,
            requestId: .string(id),
            launchId: launchId,
            sessionId: sessionId,
            title: "Allow command?",
            detail: nil,
            choices: [],
            amendments: [],
            permissionProfile: nil,
            decisionSocket: nil
        )
    )
}

private func question(
    _ id: String,
    sessionId: String,
    launchId: String
) -> CoveDirectRequest {
    .question(
        CoveQuestionRequest(
            schemaVersion: 1,
            requestId: .string(id),
            launchId: launchId,
            sessionId: sessionId,
            question: "Choose one",
            options: [],
            allowsFreeform: true,
            decisionSocket: nil
        )
    )
}

private func testQueueClassificationOrderingAndDeduplication() {
    let approvalRequest = approval(
        "approval-1",
        sessionId: "approval-task",
        launchId: "launch-a"
    )
    let questionRequest = question(
        "question-1",
        sessionId: "question-task",
        launchId: "launch-q"
    )
    let approvalSnapshot = snapshot(
        "approval-snapshot",
        status: .waitingApproval,
        priority: 5,
        seconds: 1,
        sessionId: "approval-task",
        launchId: "launch-a"
    )
    let questionSnapshot = snapshot(
        "question-snapshot",
        status: .waitingInput,
        priority: 5,
        seconds: 2,
        sessionId: "question-task",
        launchId: "launch-q"
    )

    let projection = CoveQueueProjection(
        snapshots: [
            snapshot(
                "blocked-pinned",
                status: .blocked,
                priority: 1,
                seconds: 0,
                sessionId: "pinned-task"
            ),
            approvalSnapshot,
            questionSnapshot,
            snapshot("working-low", status: .working, priority: 2, seconds: 3),
            snapshot("active-high", status: .active, priority: 8, seconds: 4),
            snapshot("compacting", status: .compacting, priority: 4, seconds: 5),
            snapshot("completed", status: .completed, priority: 2, seconds: 6),
            snapshot("failed", status: .failed, priority: 9, seconds: 7),
            snapshot("interrupted", status: .interrupted, priority: 4, seconds: 8),
            snapshot("idle", status: .idle, priority: 100, seconds: 9),
            snapshot("listening", status: .listening, priority: 100, seconds: 10),
            snapshot("quiet", status: .quiet, priority: 100, seconds: 11),
            snapshot("hidden", status: .hidden, priority: 100, seconds: 12),
        ],
        directRequests: [questionRequest, approvalRequest],
        pinnedSessionIDs: ["pinned-task"]
    )

    expect(
        projection.needsAttention.map(\.id) == [
            .snapshot("blocked-pinned"),
            .directRequest(approvalRequest.key),
            .directRequest(questionRequest.key),
        ],
        "attention rows must be pinned first, then ordered by request priority"
    )
    expect(
        projection.active.map(\.id) == [
            .snapshot("active-high"),
            .snapshot("compacting"),
            .snapshot("working-low"),
        ],
        "active rows must be ordered by descending priority"
    )
    expect(
        projection.recentlyFinished.map(\.id) == [
            .snapshot("failed"),
            .snapshot("interrupted"),
            .snapshot("completed"),
        ],
        "finished rows must be ordered by descending priority"
    )
    expect(projection.taskCount == 9, "quiet statuses and paired snapshots must be omitted")
    expect(
        projection.allTaskItems.map(\.section) ==
            Array(repeating: .needsAttention, count: 3)
            + Array(repeating: .active, count: 3)
            + Array(repeating: .recentlyFinished, count: 3),
        "allTaskItems must preserve the locked section order"
    )

    let approvalRow = projection.needsAttention.first {
        $0.id == .directRequest(approvalRequest.key)
    }
    expect(
        approvalRow?.snapshot?.snapshotId == approvalSnapshot.snapshotId,
        "a matching request and snapshot must collapse into one enriched row"
    )
    expect(
        !projection.allTaskItems.contains { $0.id == .snapshot(approvalSnapshot.snapshotId) },
        "the paired approval snapshot must not remain as a duplicate row"
    )
    let questionRow = projection.needsAttention.first {
        $0.id == .directRequest(questionRequest.key)
    }
    expect(
        questionRow?.snapshot?.snapshotId == questionSnapshot.snapshotId,
        "question requests must deduplicate against waiting-input snapshots"
    )
}

private func testQueueStableSelection() {
    let request = approval(
        "stable-request",
        sessionId: "stable-task",
        launchId: "stable-launch"
    )
    let selected = CoveQueueItemID.directRequest(request.key)
    let initial = CoveQueueProjection(
        snapshots: [
            snapshot(
                "stable-snapshot",
                status: .waitingApproval,
                priority: 1,
                seconds: 0,
                sessionId: "stable-task",
                launchId: "stable-launch"
            ),
        ],
        directRequests: [request]
    )
    expect(initial.normalizedSelection(selected) == selected, "live selection must be retained")

    let updated = CoveQueueProjection(
        snapshots: [
            snapshot("new-task", status: .working, priority: 99, seconds: 20),
            snapshot(
                "stable-snapshot",
                status: .waitingApproval,
                priority: 1,
                seconds: 10,
                sessionId: "stable-task",
                launchId: "stable-launch"
            ),
        ],
        directRequests: [request]
    )
    expect(
        updated.normalizedSelection(selected) == selected,
        "selection identity must survive reordering and metadata updates"
    )
    expect(
        CoveQueueProjection(snapshots: [], directRequests: [])
            .normalizedSelection(selected) == nil,
        "selection must clear only after its row disappears"
    )
}

private func testPresentationForwardAndBackBehavior() {
    let target = CoveFocusTarget.session("task-a")
    expect(
        CoveOverlayPresentationPolicy.forward(from: .collapsed) == .queue,
        "forward must expand collapsed to queue"
    )
    expect(
        CoveOverlayPresentationPolicy.forward(from: .queue) == .queue,
        "forward without a target must leave queue stable"
    )
    expect(
        CoveOverlayPresentationPolicy.forward(
            from: .collapsed,
            focusing: target
        ) == .focused(target),
        "an explicit focus target must open directly from collapsed"
    )
    expect(
        CoveOverlayPresentationPolicy.forward(
            from: .queue,
            focusing: target
        ) == .focused(target),
        "an explicit focus target must open from queue"
    )
    expect(
        CoveOverlayPresentationPolicy.back(from: .focused(target)) == .queue,
        "Escape/back must return focused content to queue"
    )
    expect(
        CoveOverlayPresentationPolicy.back(from: .queue) == .collapsed,
        "a second Escape/back must collapse the queue"
    )
    expect(
        CoveOverlayPresentationPolicy.back(from: .collapsed) == .collapsed,
        "Escape/back must be idempotent when collapsed"
    )
}

private func testHookAggregationAndRawEventRetention() {
    let first = CoveEvent(
        kind: .display,
        title: "first hook",
        body: "raw first body",
        source: CoveWireSource.localCli.rawValue,
        sessionId: "task-a",
        turnId: "turn-1",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(1)
    )
    let latest = CoveEvent(
        kind: .display,
        title: "latest hook",
        body: "raw latest body",
        source: CoveWireSource.localCli.rawValue,
        sessionId: "task-a",
        turnId: "turn-1",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(3)
    )
    let turnless = CoveEvent(
        kind: .display,
        title: "turnless hook",
        sessionId: "task-a",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(2)
    )
    let emptyTurn = CoveEvent(
        kind: .display,
        title: "empty turn hook",
        sessionId: "task-a",
        turnId: "",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(4)
    )
    let otherTask = CoveEvent(
        kind: .display,
        title: "other task hook",
        sessionId: "task-b",
        turnId: "turn-1",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(5)
    )
    let nonHook = CoveEvent(
        kind: .display,
        title: "not a hook",
        sessionId: "task-a",
        turnId: "turn-1",
        wireKind: CoveWireEventKind.display.rawValue,
        timestamp: referenceDate.addingTimeInterval(100)
    )

    let remoteHostA = CoveEvent(
        kind: .display,
        title: "remote host A hook",
        source: CoveWireSource.remoteCli.rawValue,
        hostId: "host-a",
        sessionId: "task-a",
        turnId: "turn-1",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(6)
    )
    let remoteHostB = CoveEvent(
        kind: .display,
        title: "remote host B hook",
        source: CoveWireSource.remoteCli.rawValue,
        hostId: "host-b",
        sessionId: "task-a",
        turnId: "turn-1",
        wireKind: CoveWireEventKind.hook.rawValue,
        timestamp: referenceDate.addingTimeInterval(7)
    )

    let groups = CoveActivityAggregator.groups(
        from: [
            first,
            nonHook,
            turnless,
            latest,
            otherTask,
            emptyTurn,
            remoteHostA,
            remoteHostB,
        ]
    )
    expect(
        groups.count == 5,
        "hooks must group by task, turn, and origin and exclude non-hooks"
    )
    expect(
        groups.map(\.key) == [
            CoveActivityGroupKey(
                sessionId: "task-a",
                turnId: "turn-1",
                source: .remoteCli,
                hostId: "host-b"
            ),
            CoveActivityGroupKey(
                sessionId: "task-a",
                turnId: "turn-1",
                source: .remoteCli,
                hostId: "host-a"
            ),
            CoveActivityGroupKey(sessionId: "task-b", turnId: "turn-1"),
            CoveActivityGroupKey(sessionId: "task-a", turnId: nil),
            CoveActivityGroupKey(
                sessionId: "task-a",
                turnId: "turn-1",
                source: .localCli
            ),
        ],
        "groups must be origin-isolated and ordered by latest activity"
    )

    let keyed = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
    let turnGroup = keyed[
        CoveActivityGroupKey(
            sessionId: "task-a",
            turnId: "turn-1",
            source: .localCli
        )
    ]
    expect(turnGroup?.eventCount == 2, "repeated hooks must occupy one task/turn group")
    expect(
        turnGroup?.events.map(\.title) == ["latest hook", "first hook"],
        "raw hook events must be retained newest-first"
    )
    expect(
        turnGroup?.events.last?.body == "raw first body"
            && turnGroup?.events.first?.wireKind == CoveWireEventKind.hook.rawValue,
        "raw body and wire-kind metadata must survive aggregation"
    )
    expect(
        keyed[CoveActivityGroupKey(sessionId: "task-a", turnId: nil)]?.eventCount == 2,
        "nil and empty turn identities must share the task fallback group"
    )

    let envelope = CoveWireEnvelope(
        eventId: "hook-envelope",
        kind: .hook,
        timestamp: referenceDate.addingTimeInterval(6),
        source: .remoteCli,
        sessionId: "task-c",
        turnId: "turn-c",
        launchId: "launch-c",
        hostId: "host-c",
        payload: .object([
            "title": .string("retained title"),
            "body": .string("retained body"),
        ])
    )
    let event = envelope.displayEvent()
    expect(
        event.sessionId == "task-c"
            && event.turnId == "turn-c"
            && event.wireKind == CoveWireEventKind.hook.rawValue
            && event.body == "retained body",
        "displayEvent must retain task, turn, wire kind, and raw body metadata"
    )
    expect(
        CoveActivityAggregator.groups(from: [event]).first?.events == [event],
        "an envelope-derived hook must remain available to Diagnostics"
    )
}

print("Running Milestone 2 queue projection tests…")
testQueueClassificationOrderingAndDeduplication()
testQueueStableSelection()
print("Running Milestone 2 presentation policy tests…")
testPresentationForwardAndBackBehavior()
print("Running Milestone 2 hook aggregation tests…")
testHookAggregationAndRawEventRetention()
print("Milestone 2 foundation tests passed")
