import Foundation

/// Task-and-turn identity for one group of low-level hook activity. A nil turn
/// identity intentionally groups all turnless hooks for the same task.
public struct CoveActivityGroupKey: Equatable, Hashable, Sendable {
    public var sessionId: String
    public var turnId: String?
    public var source: CoveWireSource?
    public var hostId: String?

    public init(
        sessionId: String,
        turnId: String?,
        source: CoveWireSource? = nil,
        hostId: String? = nil
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.source = source
        self.hostId = source == .remoteCli ? hostId : nil
    }
}

/// One summarized activity row and the raw events available to Diagnostics.
public struct CoveActivityGroup: Equatable, Sendable, Identifiable {
    public var id: CoveActivityGroupKey { key }
    public var key: CoveActivityGroupKey
    public var latestEvent: CoveEvent
    public var events: [CoveEvent]

    public var eventCount: Int { events.count }

    init(
        key: CoveActivityGroupKey,
        latestEvent: CoveEvent,
        events: [CoveEvent]
    ) {
        self.key = key
        self.latestEvent = latestEvent
        self.events = events
    }
}

/// Pure grouping for low-level hook activity retained in `CoveState`.
public enum CoveActivityAggregator {
    public static func groups(
        from events: [CoveEvent]
    ) -> [CoveActivityGroup] {
        var grouped: [CoveActivityGroupKey: [(offset: Int, event: CoveEvent)]] = [:]

        for (offset, event) in events.enumerated()
        where event.wireKind == CoveWireEventKind.hook.rawValue {
            guard let sessionId = event.sessionId, !sessionId.isEmpty else {
                continue
            }
            let key = CoveActivityGroupKey(
                sessionId: sessionId,
                turnId: event.turnId.flatMap { $0.isEmpty ? nil : $0 },
                source: event.source.flatMap(CoveWireSource.init(rawValue:)),
                hostId: event.hostId
            )
            grouped[key, default: []].append((offset, event))
        }

        return grouped.compactMap { key, values in
            let ordered = values.sorted { lhs, rhs in
                if lhs.event.timestamp != rhs.event.timestamp {
                    return lhs.event.timestamp > rhs.event.timestamp
                }
                return lhs.offset < rhs.offset
            }
            guard let latest = ordered.first?.event else { return nil }
            return CoveActivityGroup(
                key: key,
                latestEvent: latest,
                events: ordered.map(\.event)
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestEvent.timestamp != rhs.latestEvent.timestamp {
                return lhs.latestEvent.timestamp > rhs.latestEvent.timestamp
            }
            if lhs.key.sessionId != rhs.key.sessionId {
                return lhs.key.sessionId < rhs.key.sessionId
            }
            if lhs.key.turnId != rhs.key.turnId {
                return (lhs.key.turnId ?? "") < (rhs.key.turnId ?? "")
            }
            if lhs.key.source != rhs.key.source {
                return (lhs.key.source?.rawValue ?? "")
                    < (rhs.key.source?.rawValue ?? "")
            }
            return (lhs.key.hostId ?? "") < (rhs.key.hostId ?? "")
        }
    }
}
