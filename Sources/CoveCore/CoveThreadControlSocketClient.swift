import Darwin
import Foundation

public struct CoveThreadControlSocketClient: Sendable {
    public static let maximumFrameBytes = 64 * 1_024

    public init() {}

    public func send(
        _ request: CoveThreadControlRequest,
        launchId: String,
        to socketPath: String
    ) async -> CoveThreadControlResult {
        do {
            try request.validate()
        } catch {
            return .rejected(.invalidInput)
        }
        guard request.target.source == .localCli else {
            return .rejected(.wrongOrigin)
        }
        return await Task.detached(priority: .userInitiated) {
            Self.sendSynchronously(
                request,
                launchId: launchId,
                socketPath: socketPath
            )
        }.value
    }

    private struct Frame: Encodable {
        var schemaVersion = 1
        var launchId: String
        var target: CoveSessionIdentity
        var operation: CoveThreadControlOperation
        var expectedTurnId: String?
        var clientMessageId: String
        var input: String
    }

    private static func sendSynchronously(
        _ request: CoveThreadControlRequest,
        launchId: String,
        socketPath: String
    ) -> CoveThreadControlResult {
        guard !launchId.isEmpty,
              launchId.utf8.count <= 512,
              socketPath.hasPrefix("/"),
              socketPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2,
              isPrivateSocket(socketPath)
        else { return .rejected(.staleRoute) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .rejected(.unavailable) }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, capacity)
            }
        }
        guard copied < capacity else { return .rejected(.staleRoute) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else { return .rejected(.staleRoute) }
        guard peerIsCurrentUser(descriptor) else { return .rejected(.staleRoute) }
        let frame = Frame(
            launchId: launchId,
            target: request.target,
            operation: request.operation,
            expectedTurnId: request.expectedTurnId,
            clientMessageId: request.clientMessageId,
            input: request.input
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var payload = try? encoder.encode(frame),
              payload.count <= maximumFrameBytes
        else { return .rejected(.invalidInput) }
        payload.append(0x0A)
        guard writeAll(payload, to: descriptor) else {
            return .rejected(.unavailable)
        }
        var response = Data()
        var byte: UInt8 = 0
        var receivedNewline = false
        while response.count <= maximumFrameBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    receivedNewline = true
                    break
                }
                response.append(byte)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return .uncertain
            } else {
                return .uncertain
            }
        }
        guard receivedNewline,
              response.count <= maximumFrameBytes,
              let value = try? JSONDecoder().decode(
                  CoveJSONValue.self,
                  from: response
              ),
              let object = value.objectValue
        else { return .uncertain }
        if object["type"]?.stringValue == "threadControlAck" {
            guard object["controlId"]?.stringValue == request.clientMessageId
            else { return .uncertain }
            switch object["status"]?.stringValue {
            case "uncertain":
                return .uncertain
            case "rejected":
                let rejection = object["rejection"]?.stringValue
                    .flatMap(CoveThreadControlRejection.init(rawValue:))
                    ?? .serverRejected
                return .rejected(rejection)
            case "accepted":
                return .accepted(
                    turnId: object["turnId"]?.scalarStringValue
                )
            default:
                return .uncertain
            }
        }
        let expectedResponseID =
            "cove-thread-control:\(request.clientMessageId)"
        guard object["id"]?.scalarStringValue == expectedResponseID else {
            return .uncertain
        }
        if object["error"] != nil && object["error"] != .null {
            let message = object["error"]?.objectValue?["message"]?
                .scalarStringValue?.lowercased() ?? ""
            return .rejected(
                message.contains("turn") && message.contains("mismatch")
                    ? .turnMismatch : .serverRejected
            )
        }
        let result = object["result"]?.objectValue
        let turnID = result?["turn"]?.objectValue?["id"]?.scalarStringValue
            ?? result?["turnId"]?.scalarStringValue
            ?? result?["id"]?.scalarStringValue
        return .accepted(turnId: turnID)
    }

    private static func isPrivateSocket(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_mode & 0o077 == 0
        else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0
        else { return false }
        return true
    }

    private static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            &credentials,
            &length
        ) == 0 else { return false }
        return credentials.cr_uid == geteuid()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return true }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count > 0 {
                    remaining -= count
                    pointer = pointer.advanced(by: count)
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
