import Foundation

/// The small, correlated control protocol multiplexed with Cove event frames
/// over a selected host's persistent SSH process.
public enum CoveRemoteRelayProtocol {
    public static let schemaVersion = 1
    public static let decisionType = "decision"
    public static let decisionAcknowledgementType = "decisionAck"

    public static func isValidControlID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    /// Options for the unattended relay connection. Host-key verification
    /// remains strict; authentication and connection loss fail without ever
    /// opening an interactive prompt behind Cove's UI.
    public static func persistentSSHArguments(
        alias: String,
        remoteCommand: String
    ) -> [String] {
        [
            "-T",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            alias,
            remoteCommand,
        ]
    }
}

public struct CoveRemoteDecisionControl: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var type: String
    public var controlId: String
    public var decisionSocket: String
    public var decision: CoveDecisionFrame

    public init(
        controlId: String,
        decisionSocket: String,
        decision: CoveDecisionFrame
    ) {
        self.schemaVersion = CoveRemoteRelayProtocol.schemaVersion
        self.type = CoveRemoteRelayProtocol.decisionType
        self.controlId = controlId
        self.decisionSocket = decisionSocket
        self.decision = decision
    }
}

public enum CoveRemoteDecisionAcknowledgementStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case delivered
    case failed
}

public struct CoveRemoteDecisionAcknowledgement: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var type: String
    public var controlId: String
    public var status: CoveRemoteDecisionAcknowledgementStatus

    public init(
        schemaVersion: Int = CoveRemoteRelayProtocol.schemaVersion,
        type: String = CoveRemoteRelayProtocol.decisionAcknowledgementType,
        controlId: String,
        status: CoveRemoteDecisionAcknowledgementStatus
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.controlId = controlId
        self.status = status
    }

    public var isSupported: Bool {
        schemaVersion == CoveRemoteRelayProtocol.schemaVersion
            && type == CoveRemoteRelayProtocol.decisionAcknowledgementType
            && CoveRemoteRelayProtocol.isValidControlID(controlId)
    }
}
