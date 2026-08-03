import Foundation

/// The non-content identity required to distinguish otherwise identical task
/// identifiers across Cove's three ingestion sources.
///
/// Local CLI and Desktop identifiers are scoped by source. Remote identifiers
/// additionally require the explicitly selected relay alias; a legacy remote
/// record without one cannot be used for exact routing.
public struct CoveOriginScope: Codable, Equatable, Hashable, Sendable {
    public var source: CoveWireSource
    public var remoteHostId: String?

    public init?(source: CoveWireSource?, hostId: String?) {
        guard let source else { return nil }
        self.source = source
        if source == .remoteCli {
            guard let hostId, !hostId.isEmpty else { return nil }
            self.remoteHostId = hostId
        } else {
            self.remoteHostId = nil
        }
    }
}

/// Collision-safe string keys for the few schema-v1 collections that still
/// store identities as strings. Length-prefixing keeps arbitrary opaque IDs
/// distinct without persisting content beyond the identifiers themselves.
public enum CoveScopedIdentityKey {
    public static func event(
        eventId: String,
        source: CoveWireSource,
        hostId: String?
    ) -> String {
        encode([
            "event",
            source.rawValue,
            source == .remoteCli ? hostId : nil,
            eventId,
        ])
    }

    public static func session(
        sessionId: String,
        source: CoveWireSource?,
        hostId: String?
    ) -> String {
        encode([
            "session",
            source?.rawValue,
            source == .remoteCli ? hostId : nil,
            sessionId,
        ])
    }

    public static func encode(_ components: [String?]) -> String {
        components.map { component in
            guard let component else { return "-1:" }
            return "\(component.utf8.count):\(component)"
        }.joined(separator: "|")
    }
}

public extension CoveWireEnvelope {
    var originScope: CoveOriginScope? {
        CoveOriginScope(source: source, hostId: hostId)
    }

    var processedEventKey: String {
        CoveScopedIdentityKey.event(
            eventId: eventId,
            source: source,
            hostId: hostId
        )
    }

    var scopedSessionKey: String {
        CoveScopedIdentityKey.session(
            sessionId: sessionId,
            source: source,
            hostId: hostId
        )
    }
}

public extension CoveSessionSnapshot {
    var originScope: CoveOriginScope? {
        CoveOriginScope(source: source, hostId: hostId)
    }

    var scopedSessionKey: String {
        CoveScopedIdentityKey.session(
            sessionId: sessionId ?? snapshotId,
            source: source,
            hostId: hostId
        )
    }
}

public extension CoveEvent {
    var originScope: CoveOriginScope? {
        CoveOriginScope(
            source: source.flatMap(CoveWireSource.init(rawValue:)),
            hostId: hostId
        )
    }
}

public extension CoveSessionMetadata {
    var originScope: CoveOriginScope? {
        CoveOriginScope(source: source, hostId: hostId)
    }

    var scopedSessionKey: String {
        CoveScopedIdentityKey.session(
            sessionId: sessionId,
            source: source,
            hostId: hostId
        )
    }
}

public extension CoveDirectRequest {
    var originScope: CoveOriginScope? {
        CoveOriginScope(source: source, hostId: hostId)
    }
}
