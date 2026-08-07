import Darwin
import Foundation

@main
struct CoveUnixSocketBrokerFoundationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cove-socket-broker-\(getpid())-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for iteration in 0..<32 {
            let socketURL = root.appendingPathComponent("events-\(iteration).sock")
            let broker = CoveUnixSocketBroker(socketPath: socketURL.path)
            broker.start()
            try waitForSocket(at: socketURL.path)

            broker.stop()

            var info = stat()
            guard lstat(socketURL.path, &info) != 0, errno == ENOENT else {
                throw TestError.socketRemained(socketURL.path)
            }
        }

        print("Cove Unix socket broker foundation tests passed")
    }

    private static func waitForSocket(at path: String) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_uid == geteuid(),
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
                    throw TestError.unsafeSocket(path)
                }
                return
            }
            guard errno == ENOENT else {
                throw TestError.systemCall("lstat", errno)
            }
            usleep(10_000)
        }
        throw TestError.socketDidNotStart(path)
    }
}

private enum TestError: LocalizedError {
    case socketDidNotStart(String)
    case socketRemained(String)
    case unsafeSocket(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .socketDidNotStart(path):
            return "broker did not create a socket at \(path)"
        case let .socketRemained(path):
            return "broker stop returned before removing \(path)"
        case let .unsafeSocket(path):
            return "broker created an unsafe entry at \(path)"
        case let .systemCall(name, code):
            return "\(name) failed with errno \(code)"
        }
    }
}
