import AppKit
import Darwin
import Foundation
import CoveCore

struct CoveJumpResult: Equatable {
    let focusedExactLocation: Bool
    let message: String
}

/// Resolves a notification's persisted origin without consulting whichever
/// Codex task happens to be current when the notification is opened.
///
/// A launch-bearing notification must match both identifiers. Notifications
/// without a launch identifier (for example Codex Desktop notifications) may
/// match by session alone. Ambiguity fails closed in both cases.
enum CoveNotificationOriginResolver {
    static func snapshot(
        sessionID: String,
        launchID: String?,
        source: CoveWireSource?,
        hostID: String?,
        in snapshots: [CoveSessionSnapshot]
    ) -> CoveSessionSnapshot? {
        guard !sessionID.isEmpty,
              let origin = CoveOriginScope(source: source, hostId: hostID) else {
            return nil
        }
        let matches = snapshots.filter { snapshot in
            guard (snapshot.sessionId ?? snapshot.snapshotId) == sessionID
            else { return false }
            guard snapshot.originScope == origin else { return false }
            guard let launchID else { return true }
            return snapshot.launchId == launchID
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

@MainActor
protocol CoveTerminalJumping: AnyObject {
    func observe(_ envelope: CoveWireEnvelope)
    func restore(metadata: [CoveSessionMetadata])
    func terminalLocationMetadata(
        for envelope: CoveWireEnvelope
    ) -> CoveTerminalLocationMetadata?
    @discardableResult func jump(to snapshot: CoveSessionSnapshot) -> CoveJumpResult
    @discardableResult func jumpToCurrent() -> CoveJumpResult
}

@MainActor
final class CoveSystemTerminalJumpService: CoveTerminalJumping {
    private struct LaunchKey: Hashable {
        var launchID: String
        var origin: CoveOriginScope
    }

    private struct LaunchLocation {
        var launchID: String
        var source: CoveWireSource
        var hostID: String?
        var sessionID: String
        var sessionIDs: Set<String>
        var cwd: String?
        var tty: String?
        var termProgram: String?
        var tmuxPane: String?
        var weztermPane: String?
        var oscMarker: String?
        var parentPID: Int?
        var hostBundleIdentifier: String?
        var editor: EditorLocation?
    }

    private struct EditorLocation {
        var terminalID: String
        var routedLaunchID: String?
        var terminalName: String
        var processID: Int?
        var focusSocket: String
        var focusSocketIdentifier: String?
        var hostApplication: String
        var hostBundleIdentifier: String?
    }

    private var launches: [LaunchKey: LaunchLocation] = [:]
    private var editorLocations: [EditorLocation] = []
    private var activeLaunchKey: LaunchKey?
    private var activeDesktopThreadID: String?
    private let openExternalURL: (URL) -> Bool
    private let focusEditorOverride: ((String, String) -> Bool)?
    private let focusEditorWindowOverride: ((String?, String, String) -> Bool)?
    private let runFirstAvailableOverride: (([String], [String]) -> Bool)?

    init(
        openExternalURL: @escaping (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        },
        focusEditorOverride: ((String, String) -> Bool)? = nil,
        focusEditorWindowOverride: ((String?, String, String) -> Bool)? = nil,
        runFirstAvailableOverride: (([String], [String]) -> Bool)? = nil
    ) {
        self.openExternalURL = openExternalURL
        self.focusEditorOverride = focusEditorOverride
        self.focusEditorWindowOverride = focusEditorWindowOverride
        self.runFirstAvailableOverride = runFirstAvailableOverride
    }

    func observe(_ envelope: CoveWireEnvelope) {
        if envelope.source == .codexDesktop {
            activeDesktopThreadID = envelope.sessionId
        }
        let observedLaunchKey = Self.launchKey(
            launchID: envelope.launchId,
            source: envelope.source,
            hostID: envelope.hostId
        )
        if let observedLaunchKey {
            activeLaunchKey = observedLaunchKey
        }

        if envelope.kind == .launch, let launchKey = observedLaunchKey {
            let launchID = launchKey.launchID
            let payload = envelope.payload.objectValue ?? [:]
            let existing = launches[launchKey]
            var sessionIDs: Set<String> = [envelope.sessionId]
            if existing?.source == envelope.source {
                sessionIDs.formUnion(existing?.sessionIDs ?? [])
            }
            let matchingEditor: EditorLocation? = {
                guard envelope.source == .localCli else { return nil }
                if Self.isRoutedEditorIdentifier(launchID) {
                    return editor(matchingRoutedLaunchID: launchID)
                        ?? existing?.editor.flatMap {
                            $0.terminalID == launchID ? $0 : nil
                        }
                }
                return editor(matchingProcessID: payload["parentPid"]?.intValue)
                    ?? existing?.editor
            }()
            launches[launchKey] = LaunchLocation(
                launchID: launchID,
                source: envelope.source,
                hostID: launchKey.origin.remoteHostId,
                sessionID: envelope.sessionId,
                sessionIDs: sessionIDs,
                cwd: payload["cwd"]?.stringValue,
                tty: payload["tty"]?.stringValue,
                termProgram: payload["termProgram"]?.stringValue,
                tmuxPane: payload["tmuxPane"]?.stringValue,
                weztermPane: payload["weztermPane"]?.stringValue,
                oscMarker: payload["oscMarker"]?.stringValue,
                parentPID: payload["parentPid"]?.intValue,
                hostBundleIdentifier: terminalBundleIdentifier(
                    from: payload["termProgram"]?.stringValue
                ),
                editor: matchingEditor
            )
        } else if envelope.kind.rawValue == "terminal.registered" {
            registerEditor(from: envelope)
        } else if let launchKey = observedLaunchKey,
                  var location = launches[launchKey] {
            location.sessionID = envelope.sessionId
            location.sessionIDs.insert(envelope.sessionId)
            launches[launchKey] = location
        }
    }

    func restore(metadata records: [CoveSessionMetadata]) {
        for record in records.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if record.source == .codexDesktop {
                activeDesktopThreadID = record.sessionId
                continue
            }
            guard let persisted = record.terminalLocation else { continue }
            let launchID = record.launchId ?? record.sessionId
            guard let launchKey = Self.launchKey(
                launchID: launchID,
                source: record.source,
                hostID: record.hostId
            ) else {
                continue
            }
            let editor: EditorLocation? = {
                guard let terminalID = persisted.editorTerminalIdentifier,
                      let socketID = persisted.focusSocketIdentifier,
                      let focusSocket = Self.editorFocusSocketPath(identifier: socketID)
                else {
                    return nil
                }
                return EditorLocation(
                    terminalID: terminalID,
                    routedLaunchID: record.source == .localCli
                        && terminalID == launchID
                        && Self.isRoutedEditorIdentifier(launchID)
                        ? launchID
                        : nil,
                    terminalName: "Integrated Terminal",
                    processID: nil,
                    focusSocket: focusSocket,
                    focusSocketIdentifier: socketID,
                    hostApplication: editorApplicationName(
                        bundleIdentifier: persisted.hostBundleIdentifier
                    ) ?? "Visual Studio Code",
                    hostBundleIdentifier: persisted.hostBundleIdentifier
                )
            }()
            let existing = launches[launchKey]
            var sessionIDs: Set<String> = [record.sessionId]
            if existing?.source == record.source {
                sessionIDs.formUnion(existing?.sessionIDs ?? [])
            }
            launches[launchKey] = LaunchLocation(
                launchID: launchID,
                source: record.source,
                hostID: launchKey.origin.remoteHostId,
                sessionID: record.sessionId,
                sessionIDs: sessionIDs,
                cwd: nil,
                tty: ttyPath(identifier: persisted.ttyIdentifier),
                termProgram: nil,
                tmuxPane: persisted.tmuxPaneIdentifier,
                weztermPane: persisted.weztermPaneIdentifier,
                oscMarker: persisted.oscMarkerIdentifier,
                parentPID: nil,
                hostBundleIdentifier: persisted.hostBundleIdentifier,
                editor: editor ?? existing?.editor
            )
            activeLaunchKey = launchKey
        }
    }

    func terminalLocationMetadata(
        for envelope: CoveWireEnvelope
    ) -> CoveTerminalLocationMetadata? {
        if let launchKey = Self.launchKey(
            launchID: envelope.launchId,
            source: envelope.source,
            hostID: envelope.hostId
        ), let location = launches[launchKey],
           location.sessionIDs.contains(envelope.sessionId) {
            return persistedLocation(from: location)
        }
        return envelope.terminalLocationMetadata()
    }

    @discardableResult
    func jump(to snapshot: CoveSessionSnapshot) -> CoveJumpResult {
        if snapshot.source == .codexDesktop, let sessionID = snapshot.sessionId {
            activeDesktopThreadID = sessionID
            return openCodexThread(sessionID)
        }
        if let launchID = snapshot.launchId {
            guard let launchKey = Self.launchKey(
                      launchID: launchID,
                      source: snapshot.source,
                      hostID: snapshot.hostId
                  ), let sessionID = snapshot.sessionId,
                  let location = launches[launchKey],
                  location.sessionIDs.contains(sessionID) else {
                return CoveJumpResult(
                    focusedExactLocation: false,
                    message: "The exact originating Codex location is not currently available."
                )
            }
            activeLaunchKey = launchKey
            return jump(to: location)
        }
        if let sessionID = snapshot.sessionId {
            guard let origin = CoveOriginScope(
                source: snapshot.source,
                hostId: snapshot.hostId
            ) else {
                return CoveJumpResult(
                    focusedExactLocation: false,
                    message: "The exact originating Codex location is not currently available."
                )
            }
            let matches = launches.values.filter {
                $0.sessionIDs.contains(sessionID)
                    && CoveOriginScope(source: $0.source, hostId: $0.hostID) == origin
            }
            guard matches.count == 1, let location = matches.first else {
                return CoveJumpResult(
                    focusedExactLocation: false,
                    message: "The exact originating Codex location is not currently available."
                )
            }
            activeLaunchKey = LaunchKey(launchID: location.launchID, origin: origin)
            return jump(to: location)
        }
        return CoveJumpResult(
            focusedExactLocation: false,
            message: "The exact originating Codex location is not currently available."
        )
    }

    @discardableResult
    func jumpToCurrent() -> CoveJumpResult {
        if let activeLaunchKey, let location = launches[activeLaunchKey] {
            return jump(to: location)
        }
        if let threadID = activeDesktopThreadID {
            return openCodexThread(threadID)
        }
        return CoveJumpResult(
            focusedExactLocation: false,
            message: "No originating Codex location has been registered yet."
        )
    }

    private func jump(to location: LaunchLocation) -> CoveJumpResult {
        if location.source == .codexDesktop {
            return openCodexThread(location.sessionID)
        }

        if location.source == .remoteCli {
            guard let marker = location.oscMarker,
                  launches.values.filter({ $0.oscMarker == marker }).count == 1,
                  focusTerminalMarker(marker) else {
                return .init(
                    focusedExactLocation: false,
                    message: "The exact originating remote terminal is not currently available."
                )
            }
            return .init(
                focusedExactLocation: true,
                message: "Focused the originating remote Codex terminal."
            )
        }

        if let marker = location.oscMarker, focusTerminalMarker(marker) {
            return .init(
                focusedExactLocation: true,
                message: "Focused the originating remote Codex terminal."
            )
        }

        if let pane = location.tmuxPane,
           runFirstAvailable(
               executables: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"],
               arguments: ["select-pane", "-t", pane]
            ) {
            if let editor = location.editor {
                guard activateAndFocusEditor(editor) else {
                    return .init(
                        focusedExactLocation: false,
                        message: "Selected tmux pane \(pane), but its editor window is not currently available."
                    )
                }
            } else {
                activateTerminalHost(
                    location.termProgram,
                    bundleIdentifier: location.hostBundleIdentifier
                )
            }
            return .init(focusedExactLocation: true, message: "Focused tmux pane \(pane).")
        }

        if let pane = location.weztermPane,
           runFirstAvailable(
               executables: [
                   "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                   "/opt/homebrew/bin/wezterm",
                   "/usr/local/bin/wezterm",
               ],
               arguments: ["cli", "activate-pane", "--pane-id", pane]
           ) {
            activateTerminalHost(
                location.termProgram,
                bundleIdentifier: location.hostBundleIdentifier
            )
            return .init(focusedExactLocation: true, message: "Focused WezTerm pane \(pane).")
        }

        if let editor = location.editor, activateAndFocusEditor(editor) {
            return .init(focusedExactLocation: true, message: "Focused \(editor.terminalName).")
        }

        let program = location.termProgram?.lowercased() ?? ""
        if program.contains("apple_terminal")
            || program == "terminal.app"
            || location.hostBundleIdentifier == "com.apple.Terminal",
           let tty = location.tty {
            let exact = runTerminalAppleScript(tty: tty)
            return .init(
                focusedExactLocation: exact,
                message: exact
                    ? "Focused the originating Terminal tab."
                    : "The originating Terminal tab is not currently available."
            )
        }

        if program.contains("iterm")
            || location.hostBundleIdentifier == "com.googlecode.iterm2",
           let tty = location.tty {
            let exact = runITermAppleScript(tty: tty)
            return .init(
                focusedExactLocation: exact,
                message: exact
                    ? "Focused the originating iTerm session."
                    : "The originating iTerm session is not currently available."
            )
        }
        return .init(
            focusedExactLocation: false,
            message: "The exact originating terminal is not currently available."
        )
    }

    private func registerEditor(from envelope: CoveWireEnvelope) {
        let payload = envelope.payload.objectValue ?? [:]
        guard envelope.source == .localCli,
              let terminal = payload["terminal"]?.objectValue,
              let terminalID = terminal["terminalId"]?.stringValue,
              let focusSocket = payload["focusSocket"]?.stringValue,
              let focusSocketIdentifier = payload["focusSocketId"]?.stringValue,
              let canonicalFocusSocket = Self.editorFocusSocketPath(
                  identifier: focusSocketIdentifier
              ),
              focusSocket == canonicalFocusSocket else {
            return
        }
        let hostIdentity = payload["editorHost"]?.objectValue ?? [:]
        let hostBundleIdentifier = hostIdentity["bundleIdentifier"]?.stringValue
        let name = terminal["terminalName"]?.stringValue ?? "Integrated Terminal"
        let host = hostIdentity["applicationName"]?.stringValue
            ?? editorApplicationName(bundleIdentifier: hostBundleIdentifier)
            ?? editorHost(from: terminal["shellPath"]?.stringValue)
            ?? editorHost(from: ProcessInfo.processInfo.environment["TERM_PROGRAM"])
            ?? "Visual Studio Code"
        let editor = EditorLocation(
            terminalID: terminalID,
            routedLaunchID: {
                guard envelope.source == .localCli,
                      let envelopeLaunchID = envelope.launchId,
                      let registrationLaunchID = terminal["launchId"]?.stringValue,
                      envelopeLaunchID == terminalID,
                      registrationLaunchID == terminalID,
                      Self.isRoutedEditorIdentifier(terminalID) else {
                    return nil
                }
                return terminalID
            }(),
            terminalName: name,
            processID: terminal["processId"]?.intValue,
            focusSocket: focusSocket,
            focusSocketIdentifier: focusSocketIdentifier,
            hostApplication: host,
            hostBundleIdentifier: hostBundleIdentifier
        )
        // The cove-editor namespace is reserved for the exact three-way binding
        // above. A malformed registration must never fall through to PID-based
        // attribution for a routed terminal.
        if Self.isRoutedEditorIdentifier(terminalID), editor.routedLaunchID == nil {
            return
        }
        if editor.routedLaunchID != nil {
            // A reloaded editor window publishes a new process-local focus
            // socket for the same routed terminal. Replace the stale location
            // deterministically so exact lookup never becomes ambiguous.
            editorLocations.removeAll { $0.terminalID == terminalID }
        } else {
            editorLocations.removeAll {
                $0.terminalID == terminalID && $0.focusSocket == focusSocket
            }
        }
        editorLocations.append(editor)
        for (launchKey, var launch) in launches where launch.source == .localCli {
            let launchID = launchKey.launchID
            if Self.isRoutedEditorIdentifier(launchID) {
                if editor.routedLaunchID == launchID {
                    launch.editor = editor
                    launches[launchKey] = launch
                }
                continue
            }
            if launch.editor == nil,
               launch.parentPID != nil,
               launch.parentPID == editor.processID {
                launch.editor = editor
                launches[launchKey] = launch
            }
        }
    }

    private func persistedLocation(
        from location: LaunchLocation
    ) -> CoveTerminalLocationMetadata {
        let ttyIdentifier = Self.persistableTTYIdentifier(location.tty)
        let hostBundleIdentifier = location.editor?.hostBundleIdentifier
            ?? location.hostBundleIdentifier
            ?? terminalBundleIdentifier(from: location.termProgram)
        let adapter: String
        let primaryIdentifier: String
        if let editor = location.editor {
            let normalizedBundle = editor.hostBundleIdentifier?.lowercased() ?? ""
            adapter = normalizedBundle.contains("cursor")
                || normalizedBundle.contains("todesktop")
                ? "cursor"
                : "vscode"
            primaryIdentifier = editor.terminalID
        } else if let marker = location.oscMarker {
            adapter = "remote-marker"
            primaryIdentifier = marker
        } else if let pane = location.tmuxPane {
            adapter = "tmux"
            primaryIdentifier = pane
        } else if let pane = location.weztermPane {
            adapter = "wezterm"
            primaryIdentifier = pane
        } else if let ttyIdentifier {
            let program = location.termProgram?.lowercased() ?? ""
            adapter = program.contains("iterm") ? "iterm" : "terminal"
            primaryIdentifier = ttyIdentifier
        } else {
            adapter = "terminal"
            primaryIdentifier = location.launchID
        }
        return CoveTerminalLocationMetadata(
            adapter: adapter,
            locationIdentifier: primaryIdentifier,
            hostBundleIdentifier: hostBundleIdentifier,
            focusSocketIdentifier: location.editor?.focusSocketIdentifier,
            tmuxPaneIdentifier: location.tmuxPane,
            weztermPaneIdentifier: location.weztermPane,
            ttyIdentifier: ttyIdentifier,
            oscMarkerIdentifier: location.oscMarker,
            editorTerminalIdentifier: location.editor?.terminalID
        )
    }

    private static func persistableTTYIdentifier(_ tty: String?) -> String? {
        guard let tty, tty.hasPrefix("/dev/") else { return nil }
        let components = tty.dropFirst(5)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy { scalar in
                      switch scalar.value {
                      case 48...57, 65...90, 97...122, 45, 46, 95:
                          return true
                      default:
                          return false
                      }
                  }
              }) else {
            return nil
        }
        return components.joined(separator: ":")
    }

    private func ttyPath(identifier: String?) -> String? {
        guard let identifier else { return nil }
        let components = identifier.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && component.unicodeScalars.allSatisfy { scalar in
                      switch scalar.value {
                      case 48...57, 65...90, 97...122, 45, 46, 95:
                          return true
                      default:
                          return false
                      }
                  }
              }) else {
            return nil
        }
        return "/dev/" + components.joined(separator: "/")
    }

    private static func editorFocusSocketPath(identifier: String) -> String? {
        guard identifier.utf8.count == 12,
              identifier.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            return nil
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Codex Cove/run",
                isDirectory: true
            )
            .appendingPathComponent("editor-\(identifier).sock")
            .path
    }

    private func editor(matchingProcessID processID: Int?) -> EditorLocation? {
        guard let processID else { return nil }
        let matches = editorLocations.filter { $0.processID == processID }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func editor(matchingRoutedLaunchID launchID: String) -> EditorLocation? {
        guard Self.isRoutedEditorIdentifier(launchID) else { return nil }
        let matches = editorLocations.filter { $0.routedLaunchID == launchID }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func launchKey(
        launchID: String?,
        source: CoveWireSource?,
        hostID: String?
    ) -> LaunchKey? {
        guard let launchID, !launchID.isEmpty,
              let origin = CoveOriginScope(source: source, hostId: hostID) else {
            return nil
        }
        return LaunchKey(launchID: launchID, origin: origin)
    }

    private static func isRoutedEditorIdentifier(_ identifier: String) -> Bool {
        let prefix = "cove-editor-"
        guard identifier.hasPrefix(prefix) else { return false }
        let value = String(identifier.dropFirst(prefix.count)).lowercased()
        guard value.utf8.count == 36,
              UUID(uuidString: value)?.uuidString.lowercased() == value else {
            return false
        }
        let characters = Array(value)
        return ("1"..."8").contains(String(characters[14]))
            && "89ab".contains(characters[19])
    }

    private enum EditorFocusPhase: String {
        case prepare
        case focus
    }

    private func focusEditor(
        _ editor: EditorLocation,
        phase: EditorFocusPhase
    ) -> Bool {
        if let focusEditorOverride {
            return focusEditorOverride(editor.terminalID, phase.rawValue)
        }
        return Self.performEditorFocusRequest(
            terminalID: editor.terminalID,
            phase: phase.rawValue,
            focusSocket: editor.focusSocket
        )
    }

    nonisolated static func performEditorFocusRequest(
        terminalID: String,
        phase: String,
        focusSocket: String,
        timeout: TimeInterval = 1
    ) -> Bool {
        guard let phase = EditorFocusPhase(rawValue: phase),
              timeout.isFinite,
              timeout > 0 else {
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let currentFlags = fcntl(fd, F_GETFL)
        var suppressSigPipe: Int32 = 1
        guard currentFlags >= 0,
              fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) == 0,
              setsockopt(
                  fd,
                  SOL_SOCKET,
                  SO_NOSIGPIPE,
                  &suppressSigPipe,
                  socklen_t(MemoryLayout<Int32>.size)
              ) == 0 else {
            return false
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = focusSocket.withCString { source -> Bool in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, capacity) < capacity
            }
        }
        guard copied else { return false }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard Self.finishNonblockingConnect(
                  fd: fd,
                  initialResult: connected,
                  deadline: deadline
              ),
              let request = try? JSONSerialization.data(
                  withJSONObject: [
                      "terminalId": terminalID,
                      "phase": phase.rawValue,
                  ]
        ) else {
            return false
        }
        var frame = request
        frame.append(0x0a)
        guard Self.writeAll(frame, to: fd, deadline: deadline),
              let response = Self.readEditorFocusResponse(
                  from: fd,
                  deadline: deadline
              ) else {
            return false
        }
        return Self.acceptsEditorFocusResponse(
            response,
            phase: phase.rawValue
        )
    }

    private nonisolated static func finishNonblockingConnect(
        fd: Int32,
        initialResult: Int32,
        deadline: TimeInterval
    ) -> Bool {
        if initialResult == 0 {
            return true
        }
        guard errno == EINPROGRESS || errno == EALREADY || errno == EWOULDBLOCK,
              waitForSocket(fd, events: POLLOUT, deadline: deadline) else {
            return false
        }
        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
                  fd,
                  SOL_SOCKET,
                  SO_ERROR,
                  &socketError,
                  &socketErrorSize
              ) == 0 else {
            return false
        }
        return socketError == 0
    }

    private nonisolated static func writeAll(
        _ data: Data,
        to fd: Int32,
        deadline: TimeInterval
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    return false
                }
                let count = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0,
                          errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitForSocket(
                        fd,
                        events: POLLOUT,
                        deadline: deadline
                    ) else {
                        return false
                    }
                } else {
                    return false
                }
            }
            return true
        }
    }

    private nonisolated static func readEditorFocusResponse(
        from fd: Int32,
        deadline: TimeInterval,
        maximumBytes: Int = 4_096
    ) -> Data? {
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        while response.count <= maximumBytes {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return nil
            }
            let available = min(chunk.count, maximumBytes + 1 - response.count)
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, available)
            }
            if count > 0 {
                let received = chunk.prefix(count)
                if let newline = received.firstIndex(of: 0x0a) {
                    guard newline == received.index(before: received.endIndex),
                          response.count + received.distance(from: received.startIndex, to: newline)
                              <= maximumBytes else {
                        return nil
                    }
                    response.append(contentsOf: received[..<newline])
                    return response
                }
                response.append(contentsOf: received)
                guard response.count <= maximumBytes else { return nil }
            } else if count == 0 {
                return response.isEmpty ? nil : response
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                guard waitForSocket(
                    fd,
                    events: POLLIN,
                    deadline: deadline,
                    allowHangup: true
                ) else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func waitForSocket(
        _ fd: Int32,
        events: Int32,
        deadline: TimeInterval,
        allowHangup: Bool = false
    ) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            let milliseconds = Int32(
                min(ceil(remaining * 1_000), Double(Int32.max))
            )
            let requestedEvents = Int16(events)
            var descriptor = pollfd(
                fd: fd,
                events: requestedEvents,
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                if descriptor.revents & requestedEvents != 0 {
                    return true
                }
                if allowHangup,
                   descriptor.revents & Int16(POLLHUP) != 0 {
                    return true
                }
                return false
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return false
            }
        }
    }

    nonisolated static func acceptsEditorFocusResponse(
        _ response: Data,
        phase: String
    ) -> Bool {
        guard let phase = EditorFocusPhase(rawValue: phase),
              let object = try? JSONSerialization.jsonObject(with: response)
                  as? [String: Any],
              Self.strictBoolean(object["ok"]) == true,
              Self.strictBoolean(object["terminalSelected"]) == true else {
            return false
        }
        switch phase {
        case .prepare:
            return true
        case .focus:
            return Self.strictBoolean(object["windowFocused"]) == true
        }
    }

    private nonisolated static func strictBoolean(_ value: Any?) -> Bool? {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
              let boolean = value as? Bool else {
            return nil
        }
        return boolean
    }

    private func activateAndFocusEditor(_ editor: EditorLocation) -> Bool {
        guard focusEditor(editor, phase: .prepare),
              let focusSocketIdentifier = editor.focusSocketIdentifier else {
            return false
        }
        let focusedWindow: Bool
        if let focusEditorWindowOverride {
            focusedWindow = focusEditorWindowOverride(
                editor.hostBundleIdentifier,
                editor.hostApplication,
                focusSocketIdentifier
            )
        } else {
            focusedWindow = CoveEditorWindowFocusing.focus(
                bundleIdentifier: editor.hostBundleIdentifier,
                applicationName: editor.hostApplication,
                focusSocketIdentifier: focusSocketIdentifier
            )
        }
        guard focusedWindow else { return false }
        return focusEditor(editor, phase: .focus)
    }

    private func openCodexThread(_ threadID: String) -> CoveJumpResult {
        guard CoveDesktopThreadClient.isSafeThreadIdentifier(threadID),
              let url = URL(string: "codex://threads/\(threadID)") else {
            return .init(focusedExactLocation: false, message: "The Codex task identifier is invalid.")
        }
        let opened = openExternalURL(url)
        return .init(
            focusedExactLocation: opened,
            message: opened ? "Opened the exact Codex task." : "Could not open Codex."
        )
    }

    private func runTerminalAppleScript(tty: String) -> Bool {
        let script = """
        on run argv
          set targetTTY to item 1 of argv
          tell application "Terminal"
            repeat with terminalWindow in windows
              repeat with terminalTab in tabs of terminalWindow
                if tty of terminalTab is targetTTY then
                  set selected tab of terminalWindow to terminalTab
                  set index of terminalWindow to 1
                  activate
                  return "focused"
                end if
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """
        return runAppleScript(script, argument: tty) == "focused"
    }

    private func runITermAppleScript(tty: String) -> Bool {
        let script = """
        on run argv
          set targetTTY to item 1 of argv
          tell application "iTerm2"
            repeat with terminalWindow in windows
              repeat with terminalTab in tabs of terminalWindow
                repeat with terminalSession in sessions of terminalTab
                  if tty of terminalSession is targetTTY then
                    select terminalSession
                    select terminalTab
                    select terminalWindow
                    activate
                    return "focused"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """
        return runAppleScript(script, argument: tty) == "focused"
    }

    private func focusTerminalMarker(_ marker: String) -> Bool {
        let terminalScript = """
        on run argv
          set targetMarker to "codex-cove:" & item 1 of argv
          tell application "Terminal"
            repeat with terminalWindow in windows
              repeat with terminalTab in tabs of terminalWindow
                if name of terminalTab contains targetMarker then
                  set selected tab of terminalWindow to terminalTab
                  set index of terminalWindow to 1
                  activate
                  return "focused"
                end if
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """
        if runAppleScript(terminalScript, argument: marker) == "focused" {
            return true
        }

        let iTermScript = """
        on run argv
          set targetMarker to "codex-cove:" & item 1 of argv
          tell application "iTerm2"
            repeat with terminalWindow in windows
              repeat with terminalTab in tabs of terminalWindow
                repeat with terminalSession in sessions of terminalTab
                  if name of terminalSession contains targetMarker then
                    select terminalSession
                    select terminalTab
                    select terminalWindow
                    activate
                    return "focused"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """
        if runAppleScript(iTermScript, argument: marker) == "focused" {
            return true
        }

        // Public Accessibility fallback for terminal hosts whose active window
        // title exposes the opaque marker. It is attempted only for a remote
        // session that advertised one.
        let accessibilityScript = """
        on run argv
          set targetMarker to "codex-cove:" & item 1 of argv
          tell application "System Events"
            repeat with processName in {"Ghostty", "Warp", "WezTerm", "Cursor", "Code"}
              if exists process processName then
                tell process processName
                  repeat with terminalWindow in windows
                    if name of terminalWindow contains targetMarker then
                      set frontmost to true
                      perform action "AXRaise" of terminalWindow
                      return "focused"
                    end if
                  end repeat
                end tell
              end if
            end repeat
          end tell
          return "missing"
        end run
        """
        return runAppleScript(accessibilityScript, argument: marker) == "focused"
    }

    private func runAppleScript(_ script: String, argument: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, argument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func runFirstAvailable(executables: [String], arguments: [String]) -> Bool {
        if let runFirstAvailableOverride {
            return runFirstAvailableOverride(executables, arguments)
        }
        guard let executable = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    private func activateTerminalHost(
        _ termProgram: String?,
        bundleIdentifier: String? = nil
    ) -> Bool {
        if let bundleIdentifier,
           activateApplication(bundleIdentifier: bundleIdentifier) {
            return true
        }
        let lower = termProgram?.lowercased() ?? ""
        let candidates: [String]
        if lower.contains("ghostty") {
            candidates = ["com.mitchellh.ghostty", "com.mitchellh.ghostty-debug"]
        } else if lower.contains("warp") {
            candidates = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        } else if lower.contains("wezterm") {
            candidates = ["com.github.wez.wezterm"]
        } else if lower.contains("iterm") {
            candidates = ["com.googlecode.iterm2"]
        } else if lower.contains("cursor") {
            candidates = ["com.todesktop.230313mzl4w4u92"]
        } else if lower.contains("vscode") || lower.contains("code") {
            candidates = ["com.microsoft.VSCode"]
        } else {
            candidates = ["com.apple.Terminal"]
        }
        for identifier in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                return app.activate(options: [.activateAllWindows])
            }
        }
        return false
    }

    @discardableResult
    private func activateApplication(bundleIdentifier: String) -> Bool {
        guard bundleIdentifier.unicodeScalars.allSatisfy({
            switch $0.value {
            case 48...57, 65...90, 97...122, 45, 46:
                return true
            default:
                return false
            }
        }) else {
            return false
        }
        if let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            return application.activate(options: [.activateAllWindows])
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration,
            completionHandler: { _, _ in }
        )
        return true
    }

    private func editorHost(from value: String?) -> String? {
        let lower = value?.lowercased() ?? ""
        if lower.contains("cursor") { return "Cursor" }
        if lower.contains("code") || lower.contains("vscode") { return "Visual Studio Code" }
        return nil
    }

    private func editorApplicationName(bundleIdentifier: String?) -> String? {
        let lower = bundleIdentifier?.lowercased() ?? ""
        if lower.contains("cursor") || lower.contains("todesktop") {
            return "Cursor"
        }
        if lower.contains("vscode") || lower.contains("microsoft") {
            return "Visual Studio Code"
        }
        return nil
    }

    private func terminalBundleIdentifier(from value: String?) -> String? {
        let lower = value?.lowercased() ?? ""
        if lower.contains("ghostty") {
            return "com.mitchellh.ghostty"
        }
        if lower.contains("warp") {
            return "dev.warp.Warp-Stable"
        }
        if lower.contains("wezterm") {
            return "com.github.wez.wezterm"
        }
        if lower.contains("iterm") {
            return "com.googlecode.iterm2"
        }
        if lower.contains("cursor") {
            return "com.todesktop.230313mzl4w4u92"
        }
        if lower.contains("vscode") || lower.contains("code") {
            return "com.microsoft.VSCode"
        }
        if lower.contains("apple_terminal") || lower.contains("terminal") {
            return "com.apple.Terminal"
        }
        return nil
    }
}
