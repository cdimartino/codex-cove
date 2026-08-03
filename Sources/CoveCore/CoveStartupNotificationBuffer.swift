import Foundation

/// A launch-scoped, in-memory holding area for attention notifications that
/// arrive before Notification Center integration is ready.
///
/// The buffer deliberately stores no data on disk. Newer attention wins when
/// the fixed capacity is exhausted, and callers must revalidate drained items
/// against current application state before presenting them.
public struct CoveStartupNotificationBuffer: Sendable {
    public struct Entry: Equatable, Sendable {
        public var envelope: CoveWireEnvelope
        public var kind: CoveNotificationEventKind

        public init(
            envelope: CoveWireEnvelope,
            kind: CoveNotificationEventKind
        ) {
            self.envelope = envelope
            self.kind = kind
        }
    }

    public let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(
        envelope: CoveWireEnvelope,
        kind: CoveNotificationEventKind
    ) {
        entries.append(Entry(envelope: envelope, kind: kind))
        let overflow = entries.count - capacity
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
    }

    /// Removes queued attention covered by the same scope rules used by the
    /// live notification service. A turn is most specific, followed by a
    /// launch; a session-only resolution clears every queued item in it.
    public mutating func resolve(
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
        entries.removeAll { entry in
            let envelope = entry.envelope
            guard envelope.sessionId == sessionID,
                  envelope.originScope == origin else { return false }
            if let turnID { return envelope.turnId == turnID }
            if let launchID { return envelope.launchId == launchID }
            return true
        }
    }

    /// Returns current entries in arrival order and always empties the buffer.
    /// Filtering at drain time prevents a resolved or otherwise stale request
    /// from becoming a delayed banner after service initialization.
    public mutating func drain(
        where isCurrent: (Entry) -> Bool
    ) -> [Entry] {
        let current = entries.filter(isCurrent)
        entries.removeAll(keepingCapacity: false)
        return current
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}
