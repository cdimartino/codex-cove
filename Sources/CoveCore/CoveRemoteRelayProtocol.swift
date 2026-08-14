import Foundation

/// The small, correlated control protocol multiplexed with Cove event frames
/// over a selected host's persistent SSH process.
public enum CoveRemoteRelayProtocol {
    public static let schemaVersion = 1
    public static let decisionType = "decision"
    public static let decisionAcknowledgementType = "decisionAck"
    public static let threadControlType = "threadControl"
    public static let threadControlAcknowledgementType = "threadControlAck"

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

/// A separate allowlisted remote control frame. The socket path is consumed
/// only by the selected host's helper and never persisted or rendered by the
/// Mac app.
public struct CoveRemoteThreadControl: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var type: String
    public var controlId: String
    public var controlSocket: String
    public var launchId: String
    public var target: CoveSessionIdentity
    public var operation: CoveThreadControlOperation
    public var expectedTurnId: String?
    public var clientMessageId: String
    public var input: String

    public init(
        controlId: String,
        controlSocket: String,
        launchId: String,
        request: CoveThreadControlRequest
    ) {
        self.schemaVersion = CoveRemoteRelayProtocol.schemaVersion
        self.type = CoveRemoteRelayProtocol.threadControlType
        self.controlId = controlId
        self.controlSocket = controlSocket
        self.launchId = launchId
        self.target = request.target
        self.operation = request.operation
        self.expectedTurnId = request.expectedTurnId
        self.clientMessageId = request.clientMessageId
        self.input = request.input
    }
}

public enum CoveRemoteThreadControlAcknowledgementStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case accepted
    case rejected
    case uncertain
}

public struct CoveRemoteThreadControlAcknowledgement:
    Codable,
    Equatable,
    Sendable
{
    public var schemaVersion: Int
    public var type: String
    public var controlId: String
    public var status: CoveRemoteThreadControlAcknowledgementStatus
    public var turnId: String?
    public var rejection: CoveThreadControlRejection?

    public init(
        schemaVersion: Int = CoveRemoteRelayProtocol.schemaVersion,
        type: String = CoveRemoteRelayProtocol.threadControlAcknowledgementType,
        controlId: String,
        status: CoveRemoteThreadControlAcknowledgementStatus,
        turnId: String? = nil,
        rejection: CoveThreadControlRejection? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.controlId = controlId
        self.status = status
        self.turnId = turnId
        self.rejection = rejection
    }

    public var isSupported: Bool {
        schemaVersion == CoveRemoteRelayProtocol.schemaVersion
            && type == CoveRemoteRelayProtocol.threadControlAcknowledgementType
            && CoveRemoteRelayProtocol.isValidControlID(controlId)
    }

    public var result: CoveThreadControlResult {
        switch status {
        case .accepted:
            .accepted(turnId: turnId)
        case .rejected:
            .rejected(rejection ?? .serverRejected)
        case .uncertain:
            .uncertain
        }
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
