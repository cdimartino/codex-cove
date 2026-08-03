import AppKit
import Darwin
import Foundation

/// A process-lifetime, advisory lock for the installed Cove application.
///
/// The lock file is intentionally persistent: kernel ownership of the open
/// descriptor, rather than the file's existence, determines whether an
/// instance is alive. That makes a crash-safe stale file harmless.
final class CoveInstanceLock {
    enum AcquisitionError: LocalizedError {
        case alreadyRunning(ownerPID: pid_t?)
        case applicationSupportUnavailable
        case unsafeFilesystemEntry(String)
        case systemCall(operation: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case let .alreadyRunning(ownerPID):
                if let ownerPID {
                    return "Codex Cove is already running as process \(ownerPID)."
                }
                return "Codex Cove is already running."
            case .applicationSupportUnavailable:
                return "The user Application Support directory is unavailable."
            case let .unsafeFilesystemEntry(path):
                return "Refusing an unsafe Codex Cove runtime entry at \(path)."
            case let .systemCall(operation, code):
                let message = String(cString: strerror(code))
                return "\(operation) failed: \(message) (errno \(code))."
            }
        }
    }

    static let revealNotification = Notification.Name(
        "local.chris.codexcove.reveal-running-instance"
    )

    private static let expectedBundleIdentifier = "local.chris.codexcove"
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        // Closing the descriptor releases flock even after an ungraceful
        // application termination. Leave the regular file in place so no
        // unlink/recreate race can split ownership between two inodes.
        _ = Darwin.close(descriptor)
    }

    static func acquire(fileManager: FileManager = .default) throws -> CoveInstanceLock {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AcquisitionError.applicationSupportUnavailable
        }

        let baseDescriptor = try openExistingDirectory(
            at: applicationSupportURL.path,
            requireCurrentUserOwnership: true
        )
        defer { _ = Darwin.close(baseDescriptor) }

        let supportDescriptor = try openOwnedDirectory(
            named: "Codex Cove",
            beneath: baseDescriptor,
            displayPath: applicationSupportURL
                .appendingPathComponent("Codex Cove", isDirectory: true)
                .path
        )
        defer { _ = Darwin.close(supportDescriptor) }

        let runtimeDescriptor = try openOwnedDirectory(
            named: "run",
            beneath: supportDescriptor,
            displayPath: applicationSupportURL
                .appendingPathComponent("Codex Cove", isDirectory: true)
                .appendingPathComponent("run", isDirectory: true)
                .path
        )
        defer { _ = Darwin.close(runtimeDescriptor) }

        let lockName = "instance.lock"
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let lockDescriptor = openat(runtimeDescriptor, lockName, flags, mode_t(0o600))
        guard lockDescriptor >= 0 else {
            throw currentSystemError(operation: "open Codex Cove instance lock")
        }

        do {
            try validateLockFile(
                descriptor: lockDescriptor,
                displayPath: applicationSupportURL
                    .appendingPathComponent("Codex Cove/run/instance.lock")
                    .path
            )
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                let ownerPID = readOwnerPID(from: lockDescriptor)
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw AcquisitionError.alreadyRunning(ownerPID: ownerPID)
                }
                throw AcquisitionError.systemCall(
                    operation: "lock Codex Cove instance file",
                    code: code
                )
            }
            try writeOwnerPID(to: lockDescriptor)
            return CoveInstanceLock(descriptor: lockDescriptor)
        } catch {
            _ = Darwin.close(lockDescriptor)
            throw error
        }
    }

    /// Acquires an isolated lock for the committed XCUITest host. Production
    /// launches never call this overload; its caller validates the test-only
    /// bundle identifier and supplies a per-test temporary directory.
    static func acquire(runtimeDirectory: URL) throws -> CoveInstanceLock {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runtimeDescriptor = try openExistingDirectory(
            at: runtimeDirectory.path,
            requireCurrentUserOwnership: true
        )
        defer { _ = Darwin.close(runtimeDescriptor) }
        guard fchmod(runtimeDescriptor, mode_t(0o700)) == 0 else {
            throw currentSystemError(operation: "secure \(runtimeDirectory.path)")
        }

        let lockDescriptor = openat(
            runtimeDescriptor,
            "instance.lock",
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else {
            throw currentSystemError(operation: "open fixture instance lock")
        }
        do {
            try validateLockFile(
                descriptor: lockDescriptor,
                displayPath: runtimeDirectory
                    .appendingPathComponent("instance.lock")
                    .path
            )
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw AcquisitionError.alreadyRunning(
                        ownerPID: readOwnerPID(from: lockDescriptor)
                    )
                }
                throw AcquisitionError.systemCall(
                    operation: "lock fixture instance file",
                    code: code
                )
            }
            try writeOwnerPID(to: lockDescriptor)
            return CoveInstanceLock(descriptor: lockDescriptor)
        } catch {
            _ = Darwin.close(lockDescriptor)
            throw error
        }
    }

    /// Best-effort duplicate-launch handoff using only public local macOS APIs.
    /// The distributed notification asks Cove to reveal its island; activation
    /// remains useful if notification delivery races the first launch.
    @MainActor
    static func revealExistingInstance(ownerPID: pid_t?) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? expectedBundleIdentifier
        let candidates: [NSRunningApplication]
        if let ownerPID,
           let owner = NSRunningApplication(processIdentifier: ownerPID),
           owner.bundleIdentifier == bundleIdentifier {
            candidates = [owner]
        } else {
            candidates = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).filter { $0.processIdentifier != getpid() }
        }

        _ = candidates.first?.activate(options: [.activateAllWindows])
        DistributedNotificationCenter.default().postNotificationName(
            revealNotification,
            object: bundleIdentifier,
            userInfo: ownerPID.map { ["ownerPID": Int($0)] },
            deliverImmediately: true
        )
    }

    private static func openExistingDirectory(
        at path: String,
        requireCurrentUserOwnership: Bool
    ) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw currentSystemError(operation: "open \(path)")
        }
        do {
            try validateDirectory(
                descriptor: descriptor,
                displayPath: path,
                requireCurrentUserOwnership: requireCurrentUserOwnership
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func openOwnedDirectory(
        named name: String,
        beneath parentDescriptor: Int32,
        displayPath: String
    ) throws -> Int32 {
        if mkdirat(parentDescriptor, name, mode_t(0o700)) != 0,
           errno != EEXIST {
            throw currentSystemError(operation: "create \(displayPath)")
        }

        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw currentSystemError(operation: "open \(displayPath)")
        }
        do {
            try validateDirectory(
                descriptor: descriptor,
                displayPath: displayPath,
                requireCurrentUserOwnership: true
            )
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw currentSystemError(operation: "secure \(displayPath)")
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(
        descriptor: Int32,
        displayPath: String,
        requireCurrentUserOwnership: Bool
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentSystemError(operation: "inspect \(displayPath)")
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              !requireCurrentUserOwnership || status.st_uid == geteuid()
        else {
            throw AcquisitionError.unsafeFilesystemEntry(displayPath)
        }
    }

    private static func validateLockFile(
        descriptor: Int32,
        displayPath: String
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw currentSystemError(operation: "inspect \(displayPath)")
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1
        else {
            throw AcquisitionError.unsafeFilesystemEntry(displayPath)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw currentSystemError(operation: "secure \(displayPath)")
        }
    }

    private static func readOwnerPID(from descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard count > 0,
              let raw = String(
                  bytes: buffer.prefix(Int(count)),
                  encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int32(raw),
              value > 1
        else { return nil }
        return pid_t(value)
    }

    private static func writeOwnerPID(to descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0
        else {
            throw currentSystemError(operation: "reset Codex Cove instance lock")
        }

        let bytes = Array("\(getpid())\n".utf8)
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
            }
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw currentSystemError(operation: "write Codex Cove instance lock")
            }
            written += result
        }
    }

    private static func currentSystemError(operation: String) -> AcquisitionError {
        AcquisitionError.systemCall(operation: operation, code: errno)
    }
}
