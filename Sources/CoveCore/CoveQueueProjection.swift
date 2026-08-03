import Foundation

/// Stable section order for the attention-first queue.
public enum CoveQueueSection: Int, CaseIterable, Sendable {
    case needsAttention
    case active
    case recentlyFinished
    case more
}

/// Stable identity for a projected task row.
public enum CoveQueueItemID: Equatable, Hashable, Sendable {
    case directRequest(CoveDirectRequestKey)
    case snapshot(String)
}

/// A task or request after section classification and request/snapshot
/// deduplication.
public struct CoveQueueItem: Equatable, Sendable, Identifiable {
    public var id: CoveQueueItemID
    public var section: CoveQueueSection
    public var sessionId: String
    public var status: CoveSessionStatus
    public var priority: Int
    public var timestamp: Date?
    public var isPinned: Bool
    public var directRequest: CoveDirectRequest?
    public var snapshot: CoveSessionSnapshot?

    public init(
        id: CoveQueueItemID,
        section: CoveQueueSection,
        sessionId: String,
        status: CoveSessionStatus,
        priority: Int,
        timestamp: Date?,
        isPinned: Bool,
        directRequest: CoveDirectRequest?,
        snapshot: CoveSessionSnapshot?
    ) {
        self.id = id
        self.section = section
        self.sessionId = sessionId
        self.status = status
        self.priority = priority
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.directRequest = directRequest
        self.snapshot = snapshot
    }
}

/// Pure projection of transient Cove state into an attention-first task queue.
///
/// A live direct request owns the actionable row when a snapshot for the same
/// session carries the corresponding attention state. The paired snapshot is
/// retained on that row for task metadata and omitted as a duplicate row.
public struct CoveQueueProjection: Equatable, Sendable {
    public var needsAttention: [CoveQueueItem]
    public var active: [CoveQueueItem]
    public var recentlyFinished: [CoveQueueItem]

    public init(state: CoveState) {
        self.init(
            snapshots: state.session.snapshots,
            directRequests: state.pendingDirectRequests,
            pinnedSessionIDs: state.pinnedSessionIDs
        )
    }

    public init(
        snapshots: [CoveSessionSnapshot],
        directRequests: [CoveDirectRequest],
        pinnedSessionIDs: [String] = []
    ) {
        let pinned = Set(pinnedSessionIDs)
        var pairedSnapshotIndices = Set<Int>()
        var candidates: [Candidate] = []

        for (requestIndex, request) in directRequests.enumerated() {
            let match = snapshots.enumerated()
                .filter { _, snapshot in
                    Self.snapshot(snapshot, represents: request)
                }
                .max { lhs, rhs in
                    lhs.element.timestamp < rhs.element.timestamp
                }
            if let match {
                pairedSnapshotIndices.insert(match.offset)
            }

            let status = Self.status(for: request)
            guard let section = Self.section(for: status) else { continue }
            let sessionId = request.sessionId
            candidates.append(
                Candidate(
                    item: CoveQueueItem(
                        id: .directRequest(request.key),
                        section: section,
                        sessionId: sessionId,
                        status: status,
                        priority: Self.priority(for: request),
                        timestamp: match?.element.timestamp,
                        isPinned: pinned.contains(sessionId),
                        directRequest: request,
                        snapshot: match?.element
                    ),
                    sourceOrder: requestIndex
                )
            )
        }

        let snapshotOffset = directRequests.count
        for (snapshotIndex, snapshot) in snapshots.enumerated()
        where !pairedSnapshotIndices.contains(snapshotIndex) {
            guard let section = Self.section(for: snapshot.status) else {
                continue
            }
            let sessionId = snapshot.sessionId ?? snapshot.snapshotId
            candidates.append(
                Candidate(
                    item: CoveQueueItem(
                        id: .snapshot(snapshot.snapshotId),
                        section: section,
                        sessionId: sessionId,
                        status: snapshot.status,
                        priority: snapshot.priority,
                        timestamp: snapshot.timestamp,
                        isPinned: pinned.contains(sessionId),
                        directRequest: nil,
                        snapshot: snapshot
                    ),
                    sourceOrder: snapshotOffset + snapshotIndex
                )
            )
        }

        let ordered = candidates.sorted(by: Self.precedes)
        self.needsAttention = ordered.compactMap {
            $0.item.section == .needsAttention ? $0.item : nil
        }
        self.active = ordered.compactMap {
            $0.item.section == .active ? $0.item : nil
        }
        self.recentlyFinished = ordered.compactMap {
            $0.item.section == .recentlyFinished ? $0.item : nil
        }
    }

    public var taskCount: Int {
        needsAttention.count + active.count + recentlyFinished.count
    }

    public var allTaskItems: [CoveQueueItem] {
        needsAttention + active + recentlyFinished
    }

    public func items(in section: CoveQueueSection) -> [CoveQueueItem] {
        switch section {
        case .needsAttention:
            return needsAttention
        case .active:
            return active
        case .recentlyFinished:
            return recentlyFinished
        case .more:
            return []
        }
    }

    /// Retains selection across updates and clears it only when its row no
    /// longer exists in the projection.
    public func normalizedSelection(
        _ selection: CoveQueueItemID?
    ) -> CoveQueueItemID? {
        guard let selection,
              allTaskItems.contains(where: { $0.id == selection })
        else {
            return nil
        }
        return selection
    }

    private struct Candidate {
        var item: CoveQueueItem
        var sourceOrder: Int
    }

    private static func section(
        for status: CoveSessionStatus
    ) -> CoveQueueSection? {
        switch status {
        case .waitingApproval, .waitingInput, .blocked:
            return .needsAttention
        case .working, .active, .compacting:
            return .active
        case .completed, .failed, .interrupted:
            return .recentlyFinished
        case .idle, .listening, .quiet, .hidden:
            return nil
        }
    }

    private static func status(
        for request: CoveDirectRequest
    ) -> CoveSessionStatus {
        switch request {
        case .approval:
            return .waitingApproval
        case .question:
            return .waitingInput
        case .planSnapshot:
            return .working
        }
    }

    private static func priority(for request: CoveDirectRequest) -> Int {
        switch request {
        case .approval:
            return 100
        case .question:
            return 95
        case .planSnapshot:
            return 40
        }
    }

    private static func snapshot(
        _ snapshot: CoveSessionSnapshot,
        represents request: CoveDirectRequest
    ) -> Bool {
        guard snapshot.originScope == request.originScope else { return false }
        let snapshotSessionId = snapshot.sessionId ?? snapshot.snapshotId
        guard snapshotSessionId == request.sessionId else { return false }
        if let requestLaunchId = request.launchId,
           let snapshotLaunchId = snapshot.launchId,
           requestLaunchId != snapshotLaunchId {
            return false
        }
        switch request {
        case .approval:
            return snapshot.status == .waitingApproval
        case .question:
            return snapshot.status == .waitingInput
        case .planSnapshot:
            return [.working, .active, .compacting].contains(snapshot.status)
        }
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.item.section != rhs.item.section {
            return lhs.item.section.rawValue < rhs.item.section.rawValue
        }
        if lhs.item.isPinned != rhs.item.isPinned {
            return lhs.item.isPinned
        }
        if lhs.item.priority != rhs.item.priority {
            return lhs.item.priority > rhs.item.priority
        }
        if let lhsTimestamp = lhs.item.timestamp,
           let rhsTimestamp = rhs.item.timestamp,
           lhsTimestamp != rhsTimestamp {
            return lhsTimestamp > rhsTimestamp
        }
        if lhs.sourceOrder != rhs.sourceOrder {
            return lhs.sourceOrder < rhs.sourceOrder
        }
        return String(describing: lhs.item.id)
            < String(describing: rhs.item.id)
    }
}
