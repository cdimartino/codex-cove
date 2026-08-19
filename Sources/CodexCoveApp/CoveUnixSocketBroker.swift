import Foundation
import Dispatch
import Darwin
import CoveCore

final class CoveUnixSocketBroker: @unchecked Sendable {
    var onEvent: @Sendable (CoveWireEnvelope) -> Void = { _ in }

    private static let maximumFrameBytes = 1_048_576
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.codexcove.socket-broker", qos: .utility)
    private let clientQueue = DispatchQueue(
        label: "com.codexcove.socket-broker.clients",
        qos: .utility,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var isRunning = false
    private var listenerFD: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = true
        stateLock.unlock()
        queue.async { [weak self] in
            self?.runServer()
        }
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        let fd = listenerFD
        stateLock.unlock()
        if fd >= 0 {
            wakeListener()
        }
        // Application termination must not outrun runServer's socket cleanup.
        queue.sync {}
    }

    private func runServer() {
        do {
            try prepareSocketDirectory()
            try removeOwnedSocketIfPresent()
        } catch {
            NSLog("CoveUnixSocketBroker refused socket path: \(error)")
            markStopped()
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("CoveUnixSocketBroker socket() failed: %d", errno)
            markStopped()
            return
        }
        stateLock.lock()
        listenerFD = fd
        stateLock.unlock()
        defer {
            close(fd)
            stateLock.lock()
            if listenerFD == fd {
                listenerFD = -1
            }
            isRunning = false
            stateLock.unlock()
            try? removeOwnedSocketIfPresent()
        }

        guard var addr = socketAddress() else {
            NSLog("CoveUnixSocketBroker path copy failed")
            return
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("CoveUnixSocketBroker bind failed: %d", errno)
            return
        }
        guard chmod(socketPath, mode_t(0o600)) == 0 else {
            NSLog("CoveUnixSocketBroker chmod failed: %d", errno)
            return
        }

        guard listen(fd, 16) == 0 else {
            NSLog("CoveUnixSocketBroker listen failed: %d", errno)
            return
        }

        while runningSnapshot() {
            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLength)
                }
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                if runningSnapshot() {
                    NSLog("CoveUnixSocketBroker accept failed: %d", errno)
                }
                break
            }
            clientQueue.async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)

        while runningSnapshot() {
            let readCount = read(clientFD, &chunk, chunk.count)
            if readCount > 0 {
                buffer.append(contentsOf: chunk.prefix(readCount))
                guard buffer.count <= Self.maximumFrameBytes else {
                    NSLog("CoveUnixSocketBroker rejected oversized frame")
                    return
                }
                while let newline = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    consume(lineData: line)
                }
            } else if readCount == 0 {
                if !buffer.isEmpty {
                    consume(lineData: buffer)
                }
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                break
            }
        }
    }

    private func consume(lineData: Data) {
        guard let line = String(data: lineData, encoding: .utf8) else { return }
        guard let envelope = CoveEventDecoder.decodeLine(line) else { return }
        DispatchQueue.main.async { [onEvent] in
            onEvent(envelope)
        }
    }

    private func runningSnapshot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func markStopped() {
        stateLock.lock()
        isRunning = false
        listenerFD = -1
        stateLock.unlock()
    }

    private func wakeListener() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        guard var address = socketAddress() else { return }
        _ = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func socketAddress() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { source -> Int in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                memset(destination, 0, pathCapacity)
                return strlcpy(destination, source, pathCapacity)
            }
        }
        return copied < pathCapacity ? address : nil
    }

    private func prepareSocketDirectory() throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(parent.path, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw CoveSocketPathError.unsafeDirectory(parent.path)
        }
        guard chmod(parent.path, mode_t(0o700)) == 0 else {
            throw CoveSocketPathError.systemCall("chmod", errno)
        }
    }

    private func removeOwnedSocketIfPresent() throws {
        var info = stat()
        if lstat(socketPath, &info) != 0 {
            if errno == ENOENT { return }
            throw CoveSocketPathError.systemCall("lstat", errno)
        }
        guard info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw CoveSocketPathError.unsafeExistingPath(socketPath)
        }
        guard unlink(socketPath) == 0 else {
            throw CoveSocketPathError.systemCall("unlink", errno)
        }
    }
}

private enum CoveSocketPathError: LocalizedError {
    case unsafeDirectory(String)
    case unsafeExistingPath(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .unsafeDirectory(path):
            return "socket directory is not a user-owned directory: \(path)"
        case let .unsafeExistingPath(path):
            return "existing socket path is not a user-owned socket: \(path)"
        case let .systemCall(name, code):
            return "\(name) failed with errno \(code)"
        }
    }
}
