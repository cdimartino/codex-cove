import Darwin
import Foundation

public protocol CoveDecisionSending: Sendable {
    func send(_ frame: CoveDecisionFrame, to socketPath: String) async throws
}

public struct CoveDecisionSocketClient: CoveDecisionSending, Sendable {
    public static let protocolMaximumFrameBytes = 1_048_576

    let timeout: TimeInterval
    let maximumFrameBytes: Int

    public init(timeout: TimeInterval = 0.75, maximumFrameBytes: Int = protocolMaximumFrameBytes) {
        self.timeout = min(max(0.05, timeout), 2)
        self.maximumFrameBytes = min(
            max(1, maximumFrameBytes),
            Self.protocolMaximumFrameBytes
        )
    }

    public func send(_ frame: CoveDecisionFrame, to socketPath: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try sendSynchronously(frame, to: socketPath)
        }.value
    }

    private func sendSynchronously(_ frame: CoveDecisionFrame, to socketPath: String) throws {
        let payload = try encodedLine(for: frame)
        try validatePrivateSocket(at: socketPath)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CoveDecisionSocketError.connectionFailed
        }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw CoveDecisionSocketError.connectionFailed
        }

        let originalFlags = fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw CoveDecisionSocketError.connectionFailed
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        try connect(descriptor: descriptor, socketPath: socketPath, deadline: deadline)
        try validatePeer(descriptor: descriptor)
        try write(payload, descriptor: descriptor, deadline: deadline)
    }

    private func encodedLine(for frame: CoveDecisionFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var payload: Data
        do {
            payload = try encoder.encode(frame)
        } catch {
            throw CoveDecisionSocketError.encodingFailed
        }
        payload.append(0x0a)

        guard payload.count <= maximumFrameBytes else {
            throw CoveDecisionSocketError.frameTooLarge
        }
        return payload
    }

    private func validatePrivateSocket(at path: String) throws {
        guard !path.isEmpty else {
            throw CoveDecisionSocketError.invalidSocket
        }

        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw CoveDecisionSocketError.invalidSocket
        }
        guard metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_mode & 0o077 == 0
        else {
            throw CoveDecisionSocketError.insecureSocket
        }
    }

    private func connect(descriptor: Int32, socketPath: String, deadline: UInt64) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { source -> Int in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                memset(destination, 0, pathCapacity)
                return strlcpy(destination, source, pathCapacity)
            }
        }
        guard copied < pathCapacity else {
            throw CoveDecisionSocketError.invalidSocket
        }

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 {
            return
        }
        guard errno == EINPROGRESS else {
            throw CoveDecisionSocketError.connectionFailed
        }

        try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)

        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorSize
        ) == 0, socketError == 0
        else {
            throw CoveDecisionSocketError.connectionFailed
        }
    }

    private func validatePeer(descriptor: Int32) throws {
        var peerUser = uid_t()
        var peerGroup = gid_t()
        guard getpeereid(descriptor, &peerUser, &peerGroup) == 0,
              peerUser == geteuid()
        else {
            throw CoveDecisionSocketError.insecureSocket
        }
    }

    private func write(_ payload: Data, descriptor: Int32, deadline: UInt64) throws {
        var sent = 0
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while sent < payload.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    payload.count - sent
                )
                if result > 0 {
                    sent += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
                } else {
                    throw CoveDecisionSocketError.writeFailed
                }
            }
        }
    }

    private func wait(descriptor: Int32, events: Int16, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            throw CoveDecisionSocketError.timedOut
        }
        let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)

        let result = Darwin.poll(&pollDescriptor, 1, Int32(min(remainingMilliseconds, Int(Int32.max))))
        if result == 0 {
            throw CoveDecisionSocketError.timedOut
        }
        guard result > 0,
              pollDescriptor.revents & events != 0,
              pollDescriptor.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) == 0
        else {
            throw CoveDecisionSocketError.connectionFailed
        }
    }
}

public enum CoveDecisionSocketError: LocalizedError {
    case encodingFailed
    case frameTooLarge
    case invalidSocket
    case insecureSocket
    case connectionFailed
    case timedOut
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The response could not be encoded."
        case .frameTooLarge:
            return "The response exceeds Cove's 1 MiB limit."
        case .invalidSocket, .insecureSocket:
            return "The private response channel is unavailable."
        case .connectionFailed, .timedOut, .writeFailed:
            return "The response could not be sent. Answer in Codex instead."
        }
    }
}
