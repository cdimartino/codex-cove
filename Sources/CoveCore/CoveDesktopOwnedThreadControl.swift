import Darwin
import Foundation

/// A bounded, persistent public app-server connection for turns initiated by
/// Cove. It controls loaded Desktop tasks and validates hook-only local task
/// identities before starting a new turn. Keeping the connection alive lets
/// authoritative approval and question requests flow back through Cove.
public final class CoveDesktopOwnedThreadControlClient:
    CoveThreadControlling,
    @unchecked Sendable
{
    public typealias EventHandler = @Sendable (CoveWireEnvelope) -> Void

    private static let decisionFrameLimit = 1_048_576
    private let configuration: CoveDesktopThreadHydrationConfiguration
    private let runtimeDirectory: URL
    private let controlQueue = DispatchQueue(
        label: "local.chris.codexcove.desktop-owned-control",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var connection: Connection?
    private var waiters: [String: ResponseWaiter] = [:]
    private var ownedRoutes: [CoveSessionIdentity: OwnedRoute] = [:]
    private var activeTurns: [CoveSessionIdentity: String] = [:]
    private var pendingDecisions: [String: Set<CoveRequestID>] = [:]
    private var eventHandler: EventHandler = { _ in }
    private var decisionListener: Int32 = -1
    private var decisionSocketPath: String?
    private var decisionListenerRunning = false

    public init(
        configuration: CoveDesktopThreadHydrationConfiguration,
        runtimeDirectory: URL
    ) {
        self.configuration = configuration
        self.runtimeDirectory = runtimeDirectory
    }

    deinit { stop() }

    public func setEventHandler(_ handler: @escaping EventHandler) {
        lock.withLock { eventHandler = handler }
    }

    public func send(
        _ request: CoveThreadControlRequest
    ) async -> CoveThreadControlResult {
        do {
            try request.validate()
        } catch {
            return .rejected(.invalidInput)
        }
        guard request.target.source == .codexDesktop
                || request.target.source == .localCli else {
            return .rejected(.wrongOrigin)
        }
        return await withCheckedContinuation { continuation in
            controlQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .rejected(.unavailable))
                    return
                }
                continuation.resume(returning: self.sendSynchronously(request))
            }
        }
    }

    /// Reads authoritative local task state without resuming it. This is used
    /// to enable an exact Start/Steer control only after source and turn checks.
    public func inspectLocalTarget(
        _ target: CoveSessionIdentity
    ) async -> CoveSessionSnapshot? {
        guard target.source == .localCli else { return nil }
        return await withCheckedContinuation { continuation in
            controlQueue.async { [weak self] in
                guard let self, self.ensureConnection() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.localSnapshot(for: target))
            }
        }
    }

    public func stop() {
        controlQueue.sync { resetConnection() }
        stopDecisionListener()
    }

    private func sendSynchronously(
        _ request: CoveThreadControlRequest
    ) -> CoveThreadControlResult {
        guard ensureDecisionListener(), ensureConnection() else {
            return .rejected(.unavailable)
        }
        let needsLocalResume = request.target.source == .localCli
            && request.operation == .start
        if request.target.source == .codexDesktop,
           request.operation == .start {
            guard let thread = readThread(request.target.sessionId),
                  hasDesktopRoot(thread, expectedID: request.target.sessionId)
            else { return .rejected(.wrongOrigin) }
            let status = thread["status"]?.objectValue?["type"]?
                .scalarStringValue ?? ""
            guard ["notLoaded", "idle"].contains(status) else {
                return .rejected(.turnMismatch)
            }
            guard activeTurnState(for: request.target.sessionId) == .none else {
                return .rejected(.turnMismatch)
            }
            _ = lock.withLock { activeTurns.removeValue(forKey: request.target) }
        }
        if request.target.source == .localCli {
            switch request.operation {
            case .start:
                guard validateLocalTarget(request.target) else {
                    return .rejected(.wrongOrigin)
                }
            case .steer:
                break
            }
        }
        let route = lock.withLock { () -> OwnedRoute in
            if let existing = ownedRoutes[request.target] { return existing }
            let route = OwnedRoute(
                launchId: "app-server-owned-\(UUID().uuidString.lowercased())"
            )
            ownedRoutes[request.target] = route
            return route
        }
        if needsLocalResume, !resumeLocalTarget(request.target) {
            lock.withLock {
                if ownedRoutes[request.target]?.launchId == route.launchId {
                    ownedRoutes.removeValue(forKey: request.target)
                    activeTurns.removeValue(forKey: request.target)
                    pendingDecisions.removeValue(forKey: route.launchId)
                }
            }
            return .rejected(.wrongOrigin)
        }
        if needsLocalResume {
            guard activeTurnState(for: request.target.sessionId) == .none else {
                lock.withLock {
                    if ownedRoutes[request.target]?.launchId == route.launchId {
                        ownedRoutes.removeValue(forKey: request.target)
                        activeTurns.removeValue(forKey: request.target)
                        pendingDecisions.removeValue(forKey: route.launchId)
                    }
                }
                return .rejected(.turnMismatch)
            }
            _ = lock.withLock { activeTurns.removeValue(forKey: request.target) }
        }
        if lock.withLock({ pendingDecisions[route.launchId]?.isEmpty == false }) {
            return .rejected(.pendingRequest)
        }
        if request.target.source == .localCli, request.operation == .steer {
            guard let thread = readThread(request.target.sessionId),
                  hasLocalCLIRoot(thread, expectedID: request.target.sessionId)
            else { return .rejected(.wrongOrigin) }
            guard !Self.hasPendingUserAction(thread) else {
                return .rejected(.pendingRequest)
            }
            guard let expectedTurnID = request.expectedTurnId,
                  activeTurnState(for: request.target.sessionId)
                    == .active(expectedTurnID)
            else { return .rejected(.turnMismatch) }
            lock.withLock { activeTurns[request.target] = expectedTurnID }
        }
        if request.target.source == .codexDesktop, request.operation == .steer {
            guard let thread = readThread(request.target.sessionId),
                  hasDesktopRoot(thread, expectedID: request.target.sessionId)
            else { return .rejected(.wrongOrigin) }
            guard !Self.hasPendingUserAction(thread) else {
                return .rejected(.pendingRequest)
            }
            guard let expectedTurnID = request.expectedTurnId,
                  activeTurnState(for: request.target.sessionId)
                    == .active(expectedTurnID)
            else { return .rejected(.turnMismatch) }
            lock.withLock { activeTurns[request.target] = expectedTurnID }
        }
        let knownActiveTurn = lock.withLock { activeTurns[request.target] }
        if request.operation == .start, knownActiveTurn != nil {
            return .rejected(.turnMismatch)
        }
        if request.operation == .steer {
            if request.target.source == .localCli {
                guard knownActiveTurn == request.expectedTurnId else {
                    return .rejected(.turnMismatch)
                }
            } else if let knownActiveTurn,
                      knownActiveTurn != request.expectedTurnId {
                return .rejected(.turnMismatch)
            }
        }
        var params: [String: Any] = [
            "threadId": request.target.sessionId,
            "clientUserMessageId": request.clientMessageId,
            "input": [["type": "text", "text": request.input]],
        ]
        let method: String
        switch request.operation {
        case .start:
            method = "turn/start"
        case .steer:
            guard let expectedTurnId = request.expectedTurnId else {
                return .rejected(.turnMismatch)
            }
            method = "turn/steer"
            params["expectedTurnId"] = expectedTurnId
        }
        let response = rpc(method: method, params: params)
        switch response {
        case .notWritten:
            return .rejected(.unavailable)
        case .writtenWithoutResponse:
            return .uncertain
        case let .response(object):
            if let error = object["error"], error != .null {
                let message = error.objectValue?["message"]?
                    .scalarStringValue?.lowercased() ?? ""
                return .rejected(
                    message.contains("turn") && message.contains("mismatch")
                        ? .turnMismatch : .serverRejected
                )
            }
            let result = object["result"]?.objectValue
            let turnId = result?["turn"]?.objectValue?["id"]?.scalarStringValue
                ?? result?["turnId"]?.scalarStringValue
                ?? result?["id"]?.scalarStringValue
            if let turnId {
                lock.withLock { activeTurns[request.target] = turnId }
            }
            // The route is intentionally retained for the lifetime of this
            // connection so later server requests can be answered exactly.
            _ = route
            return .accepted(turnId: turnId)
        }
    }

    func validateLocalTarget(_ target: CoveSessionIdentity) -> Bool {
        guard let thread = readThread(target.sessionId),
              ["notLoaded", "idle"].contains(
                  thread["status"]?.objectValue?["type"]?.scalarStringValue ?? ""
              )
        else { return false }
        return hasLocalCLIRoot(thread, expectedID: target.sessionId)
    }

    func resumeLocalTarget(_ target: CoveSessionIdentity) -> Bool {
        let resumed = rpc(
            method: "thread/resume",
            params: [
                "threadId": target.sessionId,
                "excludeTurns": true,
            ]
        )
        guard case let .response(object) = resumed,
              object["error"] == nil || object["error"] == .null,
              let thread = object["result"]?.objectValue?["thread"]?.objectValue
        else { return false }
        return thread["id"]?.scalarStringValue == target.sessionId
            && thread["status"]?.objectValue?["type"]?.scalarStringValue == "idle"
            && hasLocalCLIRoot(thread, expectedID: target.sessionId)
    }

    func activeLocalTurn(for target: CoveSessionIdentity) -> String? {
        guard let thread = readThread(target.sessionId),
              hasLocalCLIRoot(thread, expectedID: target.sessionId)
        else { return nil }
        return activeTurnID(for: target.sessionId)
    }

    func activeTurnID(for threadID: String) -> String? {
        guard case let .active(turnID) = activeTurnState(for: threadID) else {
            return nil
        }
        return turnID
    }

    private func activeTurnState(for threadID: String) -> ActiveTurnState {
        let response = rpc(
            method: "thread/turns/list",
            params: [
                "threadId": threadID,
                "limit": 8,
                "sortDirection": "desc",
                "itemsView": "summary",
            ]
        )
        guard case let .response(object) = response,
              object["error"] == nil || object["error"] == .null,
              let turns = object["result"]?.objectValue?["data"]?.arrayValue
        else { return .invalid }
        let active = turns.filter {
            $0.objectValue?["status"]?.scalarStringValue == "inProgress"
        }
        guard !active.isEmpty else { return .none }
        guard active.count == 1,
              let turnID = active[0].objectValue?["id"]?.scalarStringValue,
              !turnID.isEmpty,
              turnID.utf8.count <= 512
        else { return .invalid }
        return .active(turnID)
    }

    func localSnapshot(for target: CoveSessionIdentity) -> CoveSessionSnapshot? {
        guard let thread = readThread(target.sessionId),
              hasLocalCLIRoot(thread, expectedID: target.sessionId)
        else { return nil }
        let statusObject = thread["status"]?.objectValue ?? [:]
        let rawStatus = statusObject["type"]?.scalarStringValue ?? ""
        let flags = statusObject["activeFlags"]?.arrayValue?
            .compactMap(\.scalarStringValue).map { $0.lowercased() } ?? []
        let status: CoveSessionStatus
        if flags.contains(where: { $0.contains("approval") }) {
            status = .waitingApproval
        } else if flags.contains(where: { $0.contains("input") }) {
            status = .waitingInput
        } else if flags.contains(where: { $0.contains("compact") }) {
            status = .compacting
        } else {
            status = switch rawStatus {
            case "active": .active
            case "systemError": .failed
            default: .idle
            }
        }
        let priority: Int = switch status {
        case .waitingApproval: 100
        case .waitingInput: 95
        case .failed: 90
        case .compacting: 60
        case .active, .working: 40
        default: 5
        }
        let activeTurn = status == .active
            || status == .working
            || status == .waitingApproval
            || status == .waitingInput
            || status == .compacting
            ? activeTurnID(for: target.sessionId) : nil
        let timestamp = thread["updatedAt"]?.intValue.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        } ?? Date()
        return CoveSessionSnapshot(
            snapshotId: target.sessionId,
            status: status,
            priority: priority,
            title: thread["name"]?.stringValue
                ?? thread["title"]?.stringValue
                ?? thread["preview"]?.stringValue
                ?? "Codex task",
            timestamp: timestamp,
            sessionId: target.sessionId,
            source: .localCli,
            parentSessionId: CoveThreadProvenance.parentID(in: thread),
            parentProvenanceConflict: CoveThreadProvenance
                .hasConflictingParentID(in: thread),
            liveness: .loaded,
            activeTurnId: activeTurn,
            controlRoute: .localAppServer
        )
    }

    func readThread(_ threadID: String) -> [String: CoveJSONValue]? {
        guard CoveDesktopThreadClient.isSafeThreadIdentifier(threadID) else {
            return nil
        }
        let read = rpc(
            method: "thread/read",
            params: ["threadId": threadID, "includeTurns": false]
        )
        guard case let .response(object) = read,
              object["error"] == nil || object["error"] == .null,
              let thread = object["result"]?.objectValue?["thread"]?.objectValue,
              thread["id"]?.scalarStringValue == threadID
        else { return nil }
        return thread
    }

    func hasLocalCLIRoot(
        _ initial: [String: CoveJSONValue],
        expectedID: String
    ) -> Bool {
        var current = initial
        var expected = expectedID
        var visited = Set<String>()
        for _ in 0..<32 {
            guard current["id"]?.scalarStringValue == expected,
                  visited.insert(expected).inserted,
                  !CoveThreadProvenance.hasConflictingParentID(in: current),
                  !CoveThreadProvenance.isExcludedAgent(current)
            else { return false }
            if !CoveThreadProvenance.isThreadSpawnAgent(current) {
                return current["source"]?.scalarStringValue == "cli"
            }
            guard
                  let parent = CoveThreadProvenance.parentID(in: current),
                  CoveDesktopThreadClient.isSafeThreadIdentifier(parent),
                  !visited.contains(parent),
                  let parentThread = readThread(parent)
            else { return false }
            current = parentThread
            expected = parent
        }
        return false
    }

    func hasDesktopRoot(
        _ initial: [String: CoveJSONValue],
        expectedID: String
    ) -> Bool {
        var current = initial
        var expected = expectedID
        var visited = Set<String>()
        for _ in 0..<32 {
            guard current["id"]?.scalarStringValue == expected,
                  visited.insert(expected).inserted,
                  !CoveThreadProvenance.hasConflictingParentID(in: current),
                  !CoveThreadProvenance.isExcludedAgent(current)
            else { return false }
            if !CoveThreadProvenance.isThreadSpawnAgent(current) {
                return CoveDesktopThreadSnapshotParser
                    .isConfidentlyDesktopOpenable(current)
            }
            guard let parent = CoveThreadProvenance.parentID(in: current),
                  CoveDesktopThreadClient.isSafeThreadIdentifier(parent),
                  !visited.contains(parent),
                  let parentThread = readThread(parent)
            else { return false }
            current = parentThread
            expected = parent
        }
        return false
    }

    static func hasPendingUserAction(_ thread: [String: CoveJSONValue]) -> Bool {
        let status = thread["status"]?.objectValue ?? [:]
        let type = status["type"]?.scalarStringValue?.lowercased() ?? ""
        let flags = status["activeFlags"]?.arrayValue?
            .compactMap(\.scalarStringValue).map { $0.lowercased() } ?? []
        return type.contains("approval")
            || type.contains("input")
            || flags.contains(where: {
                $0.contains("approval") || $0.contains("input")
            })
    }
}

private enum ActiveTurnState: Equatable {
    case none
    case active(String)
    case invalid
}

private extension CoveDesktopOwnedThreadControlClient {
    func ensureConnection() -> Bool {
        if lock.withLock({ connection?.process.isRunning == true }) {
            return true
        }
        resetConnection()
        for arguments in [["app-server", "proxy"], ["app-server", "--stdio"]] {
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = configuration.realCodexURL
            process.arguments = arguments
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_COVE_BYPASS"] = "1"
            environment["RUST_LOG"] = "off"
            process.environment = environment
            do {
                try process.run()
            } catch {
                continue
            }
            let candidate = Connection(
                process: process,
                input: inputPipe.fileHandleForWriting,
                output: outputPipe.fileHandleForReading
            )
            _ = fcntl(candidate.input.fileDescriptor, F_SETNOSIGPIPE, 1)
            lock.withLock { connection = candidate }
            startReader(for: candidate)
            let initialization = rpc(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_cove",
                        "title": "Codex Cove",
                        "version": configuration.clientVersion,
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
                timeout: arguments.last == "proxy"
                    ? min(0.75, configuration.requestTimeout)
                    : configuration.requestTimeout
            )
            guard case let .response(response) = initialization,
                  response["error"] == nil || response["error"] == .null
            else {
                resetConnection(generation: candidate.generation)
                continue
            }
            guard writeJSON(["method": "initialized", "params": [:]]) else {
                resetConnection(generation: candidate.generation)
                continue
            }
            return true
        }
        return false
    }

    func rpc(
        method: String,
        params: [String: Any],
        timeout: TimeInterval? = nil
    ) -> OwnedRPCResult {
        let id = "cove-desktop-control-\(UUID().uuidString.lowercased())"
        let waiter = ResponseWaiter()
        lock.withLock { waiters[id] = waiter }
        guard writeJSON(["id": id, "method": method, "params": params]) else {
            _ = lock.withLock { waiters.removeValue(forKey: id) }
            return .notWritten
        }
        let waitSeconds = timeout ?? configuration.requestTimeout
        guard waiter.semaphore.wait(timeout: .now() + waitSeconds) == .success,
              let response = waiter.value()
        else {
            _ = lock.withLock { waiters.removeValue(forKey: id) }
            return .writtenWithoutResponse
        }
        _ = lock.withLock { waiters.removeValue(forKey: id) }
        return .response(response)
    }

    func writeJSON(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              data.count <= configuration.maximumLineBytes
        else { return false }
        data.append(0x0A)
        guard let active = lock.withLock({ connection }),
              active.process.isRunning
        else { return false }
        return writeLock.withLock {
            do {
                try active.input.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
    }

    func resetConnection(generation: UUID? = nil) {
        let prior: Connection? = lock.withLock {
            guard generation == nil || connection?.generation == generation else {
                return nil
            }
            let prior = connection
            connection = nil
            ownedRoutes.removeAll()
            activeTurns.removeAll()
            pendingDecisions.removeAll()
            let pending = Array(waiters.values)
            waiters.removeAll()
            for waiter in pending {
                waiter.resolve(["error": .string("connection closed")])
            }
            return prior
        }
        guard let prior else { return }
        try? prior.input.close()
        try? prior.output.close()
        if prior.process.isRunning {
            prior.process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 0.5
            ) {
                if prior.process.isRunning { kill(prior.process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private extension CoveDesktopOwnedThreadControlClient {
    func ensureDecisionListener() -> Bool {
        if lock.withLock({ decisionListenerRunning && decisionListener >= 0 }) {
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var metadata = stat()
            guard lstat(runtimeDirectory.path, &metadata) == 0,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & 0o077 == 0
            else { return false }
            let path = runtimeDirectory.appendingPathComponent(
                "desktop-\(UUID().uuidString.prefix(12)).d"
            ).path
            guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
                return false
            }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let copied = path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                    strlcpy(destination, source, capacity)
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard copied < capacity,
                  bound == 0,
                  chmod(path, 0o600) == 0,
                  Darwin.listen(descriptor, 8) == 0
            else {
                Darwin.close(descriptor)
                unlink(path)
                return false
            }
            lock.withLock {
                decisionListener = descriptor
                decisionSocketPath = path
                decisionListenerRunning = true
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.decisionAcceptLoop(descriptor: descriptor)
            }
            return true
        } catch {
            return false
        }
    }

    func decisionAcceptLoop(descriptor: Int32) {
        while lock.withLock({
            decisionListenerRunning && decisionListener == descriptor
        }) {
            let client = Darwin.accept(descriptor, nil, nil)
            if client >= 0 {
                handleDecisionClient(client)
                Darwin.close(client)
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    func handleDecisionClient(_ descriptor: Int32) {
        var credentials = xucred()
        var credentialLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            &credentials,
            &credentialLength
        ) == 0,
            credentials.cr_uid == geteuid()
        else { return }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= Self.decisionFrameLimit {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A { break }
                data.append(byte)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
        guard data.count <= Self.decisionFrameLimit,
              let frame = try? JSONDecoder().decode(CoveDecisionFrame.self, from: data),
              frame.schemaVersion == 1,
              let launchId = frame.launchId,
              lock.withLock({ pendingDecisions[launchId]?.contains(frame.requestId) == true }),
              let value = try? JSONDecoder().decode(
                  CoveJSONValue.self,
                  from: JSONEncoder().encode(frame)
              ),
              let object = value.objectValue,
              let requestId = object["requestId"],
              let result = object["result"]
        else { return }
        let response = CoveJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": requestId,
            "result": result,
        ])
        guard var encoded = try? JSONEncoder().encode(response),
              encoded.count <= configuration.maximumLineBytes
        else { return }
        encoded.append(0x0A)
        guard writeRaw(encoded) else { return }
        _ = lock.withLock {
            pendingDecisions[launchId]?.remove(frame.requestId)
        }
    }

    func writeRaw(_ data: Data) -> Bool {
        guard let active = lock.withLock({ connection }),
              active.process.isRunning
        else { return false }
        return writeLock.withLock {
            do {
                try active.input.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
    }

    func stopDecisionListener() {
        let state: (Int32, String?) = lock.withLock {
            decisionListenerRunning = false
            let state = (decisionListener, decisionSocketPath)
            decisionListener = -1
            decisionSocketPath = nil
            return state
        }
        if state.0 >= 0 { Darwin.close(state.0) }
        if let path = state.1 { unlink(path) }
    }
}

private extension CoveDesktopOwnedThreadControlClient {
    func startReader(for active: Connection) {
        let maximumLineBytes = configuration.maximumLineBytes
        DispatchQueue.global(qos: .utility).async { [weak self, active] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(
                    active.output.fileDescriptor,
                    &chunk,
                    chunk.count
                )
                if count > 0 {
                    buffer.append(contentsOf: chunk.prefix(count))
                    guard buffer.count <= maximumLineBytes else { break }
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard line.count <= maximumLineBytes else { break }
                        self?.handleAppServerLine(line, generation: active.generation)
                    }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            self?.controlQueue.async { [weak self] in
                self?.resetConnection(generation: active.generation)
            }
        }
    }

    func handleAppServerLine(_ data: Data, generation: UUID) {
        guard data.count <= configuration.maximumLineBytes,
              let value = try? JSONDecoder().decode(CoveJSONValue.self, from: data),
              let object = value.objectValue
        else { return }
        if object["method"] == nil,
           let id = object["id"]?.stringValue,
           let waiter = lock.withLock({ waiters[id] }) {
            waiter.resolve(object)
            return
        }
        guard lock.withLock({ connection?.generation == generation }),
              let sessionId = Self.sessionId(in: object),
              let identity = lock.withLock({ () -> CoveSessionIdentity? in
                  let matches = ownedRoutes.keys.filter {
                      $0.sessionId == sessionId
                  }
                  return matches.count == 1 ? matches[0] : nil
              })
        else { return }
        let method = object["method"]?.stringValue ?? ""
        let eventTurnId = object["params"]?.objectValue?["turnId"]?
            .scalarStringValue
            ?? object["params"]?.objectValue?["turn"]?.objectValue?["id"]?
                .scalarStringValue
        lock.withLock {
            if method == "turn/started", let eventTurnId {
                activeTurns[identity] = eventTurnId
            } else if [
                "turn/completed",
                "turn/aborted",
                "turn/interrupted",
                "turn/failed",
            ].contains(method) {
                activeTurns.removeValue(forKey: identity)
            }
        }
        let routeAndSocket = lock.withLock { () -> (OwnedRoute, String)? in
            guard let route = ownedRoutes[identity],
                  let decisionSocketPath
            else { return nil }
            if Self.isDirectRequest(method),
               let requestId = Self.requestId(object["id"]) {
                pendingDecisions[route.launchId, default: []].insert(requestId)
            }
            if method == "serverRequest/resolved",
               let resolved = object["params"]?.objectValue?["requestId"],
               let requestId = Self.requestId(resolved) {
                pendingDecisions[route.launchId]?.remove(requestId)
            }
            return (route, decisionSocketPath)
        }
        guard let (route, decisionSocketPath) = routeAndSocket else { return }
        let kind: CoveWireEventKind = switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestApproval":
            .approvalRequested
        case "item/tool/requestUserInput":
            .questionRequested
        case "serverRequest/resolved":
            .serverRequestResolved
        default:
            .appServer
        }
        let envelope = CoveWireEnvelope(
            eventId: "app-server-owned-\(UUID().uuidString.lowercased())",
            kind: kind,
            timestamp: Date(),
            source: identity.source,
            sessionId: sessionId,
            turnId: eventTurnId,
            launchId: route.launchId,
            payload: .object([
                "message": .object(object),
                "decisionSocket": .string(decisionSocketPath),
                "liveness": .string(
                    identity.source == .codexDesktop
                        ? CoveSessionLiveness.loaded.rawValue
                        : CoveSessionLiveness.live.rawValue
                ),
                "controlRoute": .string(
                    identity.source == .codexDesktop
                        ? CoveThreadControlRoute.desktop.rawValue
                        : CoveThreadControlRoute.localAppServer.rawValue
                ),
            ])
        )
        let handler = lock.withLock { eventHandler }
        handler(envelope)
    }

    static func sessionId(in object: [String: CoveJSONValue]) -> String? {
        let params = object["params"]?.objectValue ?? [:]
        return params["threadId"]?.scalarStringValue
            ?? params["thread"]?.objectValue?["id"]?.scalarStringValue
            ?? object["result"]?.objectValue?["thread"]?.objectValue?["id"]?
                .scalarStringValue
            ?? object["threadId"]?.scalarStringValue
    }

    static func requestId(_ value: CoveJSONValue?) -> CoveRequestID? {
        switch value {
        case let .string(value):
            return .string(value)
        case let .number(value):
            return Int64(exactly: value).map(CoveRequestID.integer)
        default:
            return nil
        }
    }

    static func isDirectRequest(_ method: String) -> Bool {
        [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "item/tool/requestApproval",
            "item/tool/requestUserInput",
        ].contains(method)
    }
}

private final class ResponseWaiter: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: [String: CoveJSONValue]?

    func resolve(_ value: [String: CoveJSONValue]) {
        lock.withLock { response = value }
        semaphore.signal()
    }

    func value() -> [String: CoveJSONValue]? {
        lock.withLock { response }
    }
}

private final class Connection: @unchecked Sendable {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let generation: UUID

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
        self.generation = UUID()
    }
}

private struct OwnedRoute: Sendable {
    var launchId: String
}

private enum OwnedRPCResult {
    case notWritten
    case writtenWithoutResponse
    case response([String: CoveJSONValue])
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
