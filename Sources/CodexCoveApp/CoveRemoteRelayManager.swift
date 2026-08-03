import Foundation
import Network
import CoveCore

/// Owns one persistent SSH relay for each explicitly enabled alias in Cove's
/// helper configuration. It never enumerates SSH configuration or connects to
/// a host that was not selected with `codex-cove remote add`.
final class CoveRemoteRelayManager: CoveDecisionSending, @unchecked Sendable {
    static let maximumFrameBytes = 1_048_576
    static let decisionAcknowledgementTimeout: TimeInterval = 3

    typealias EventHandler = @Sendable (CoveWireEnvelope) -> Void

    private static let routePrefix = "cove-remote://"
    private static let remoteCommand =
        "~/.local/share/codex-cove/current/codex-cove remote-relay-server"

    private let queue = DispatchQueue(
        label: "local.chris.codexcove.remote-relays",
        qos: .utility
    )
    private let localSender: any CoveDecisionSending
    private let configurationURL: URL
    private var eventHandler: EventHandler = { _ in }
    private var hosts: [String: HostState] = [:]
    private var selectedAliases: Set<String> = []
    private var routes: [String: DecisionRoute] = [:]
    private var pendingDecisions: [String: PendingDecision] = [:]
    private var running = false
    private var networkAvailable = true
    private var observedNetworkStatus: NWPath.Status?
    private var pathMonitor: NWPathMonitor?

    init(
        configurationURL: URL = CoveRemoteRelayManager.defaultConfigurationURL,
        localSender: any CoveDecisionSending = CoveDecisionSocketClient()
    ) {
        self.configurationURL = configurationURL
        self.localSender = localSender
    }

    /// The callback is delivered on the main queue with remote source and host
    /// attribution already applied. Any remote decision socket has been
    /// replaced by an opaque, in-memory route.
    func setEventHandler(_ handler: @escaping EventHandler) {
        queue.async { [weak self] in
            self?.eventHandler = handler
        }
    }

    /// Loads only enabled aliases from the private helper configuration and
    /// starts at most one SSH process for each alias.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            self.reloadSelectedHosts()
            self.startPathMonitorIfNeeded()
            self.connectSelectedHosts()
        }
    }

    /// Terminates relays and invalidates all opaque remote decision routes.
    /// Closing SSH stdin also tells the remote relay to remove its event socket.
    func stop() {
        queue.sync {
            self.running = false
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.observedNetworkStatus = nil
            self.selectedAliases.removeAll()
            self.failAllPendingDecisions(with: CoveRemoteRelayError.disconnected)
            self.routes.removeAll()
            for host in self.hosts.values {
                self.stop(host)
            }
        }
    }

    /// Call after wake or an explicit remote configuration change.
    func resumeAndReload() {
        start()
    }

    /// Call before sleep. Unlike a permanent stop, a later
    /// `resumeAndReload()` re-reads the selected alias list.
    func prepareForSleep() {
        stop()
    }

    func send(_ frame: CoveDecisionFrame, to socketPath: String) async throws {
        guard socketPath.hasPrefix(Self.routePrefix) else {
            try await localSender.send(frame, to: socketPath)
            return
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CoveRemoteRelayError.disconnected)
                    return
                }
                do {
                    try self.beginRemoteSend(
                        frame,
                        routePath: socketPath,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func reloadSelectedHosts() {
        let aliases = (try? loadSelectedAliases()) ?? []
        let selected = Set(aliases)
        selectedAliases = selected

        for alias in aliases where hosts[alias] == nil {
            hosts[alias] = HostState(alias: alias)
        }
        for host in hosts.values where !selected.contains(host.alias) {
            stop(host)
            removeRoutes(for: host.alias)
        }
    }

    private func loadSelectedAliases() throws -> [String] {
        var metadata = stat()
        guard lstat(configurationURL.path, &metadata) == 0 else {
            if errno == ENOENT {
                return []
            }
            throw CoveRemoteRelayError.invalidConfiguration
        }
        guard metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0
        else {
            throw CoveRemoteRelayError.invalidConfiguration
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: configurationURL.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumFrameBytes
        else {
            throw CoveRemoteRelayError.invalidConfiguration
        }
        let data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
        let configuration = try JSONDecoder().decode(HelperConfiguration.self, from: data)
        guard configuration.schemaVersion == 1 else {
            throw CoveRemoteRelayError.invalidConfiguration
        }
        return Array(
            Set(
                configuration.remoteHosts
                    .filter(\.enabled)
                    .map(\.alias)
                    .filter(Self.isValidAlias)
            )
        ).sorted()
    }

    private static func isValidAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty,
              alias.utf8.count <= 255,
              alias.first != "-"
        else {
            return false
        }
        return alias.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private func connectSelectedHosts() {
        guard running, networkAvailable else { return }
        for alias in selectedAliases.sorted() {
            if let host = hosts[alias] {
                connect(host)
            }
        }
    }

    private func connect(_ host: HostState) {
        guard shouldRun(host),
              host.process == nil,
              host.reconnectWorkItem == nil
        else {
            return
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        let generation = UUID()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = CoveRemoteRelayProtocol.persistentSSHArguments(
            alias: host.alias,
            remoteCommand: Self.remoteCommand
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.connectionTerminated(alias: host.alias, generation: generation)
            }
        }

        host.process = process
        host.input = inputPipe.fileHandleForWriting
        host.output = outputPipe.fileHandleForReading
        host.generation = generation

        do {
            try process.run()
        } catch {
            host.process = nil
            host.input = nil
            host.output = nil
            host.generation = nil
            scheduleReconnect(host)
            return
        }

        let alias = host.alias
        let output = outputPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                while let frame = try Self.readFrame(from: output) {
                    guard let self else { return }
                    self.queue.async {
                        self.receive(frame, alias: alias, generation: generation)
                    }
                }
            } catch {
                // Payloads and SSH stderr are intentionally never logged.
            }
            guard let self else { return }
            self.queue.async {
                self.outputEnded(alias: alias, generation: generation)
            }
        }
    }

    private func receive(_ data: Data, alias: String, generation: UUID) {
        guard let host = hosts[alias],
              host.generation == generation,
              data.count <= Self.maximumFrameBytes
        else {
            terminateConnection(alias: alias, generation: generation)
            return
        }

        if let acknowledgement = try? JSONDecoder().decode(
            CoveRemoteDecisionAcknowledgement.self,
            from: data
        ) {
            guard acknowledgement.isSupported else {
                terminateConnection(alias: alias, generation: generation)
                return
            }
            host.reconnectAttempt = 0
            receive(
                acknowledgement,
                alias: alias,
                generation: generation
            )
            return
        }

        guard let line = String(data: data, encoding: .utf8),
              let decoded = CoveEventDecoder.decodeLine(line)
        else {
            terminateConnection(alias: alias, generation: generation)
            return
        }
        host.reconnectAttempt = 0
        let envelope = routeRemoteDecisionIfNeeded(decoded, alias: alias)
        let handler = eventHandler
        DispatchQueue.main.async {
            handler(envelope)
        }
    }

    private func routeRemoteDecisionIfNeeded(
        _ incoming: CoveWireEnvelope,
        alias: String
    ) -> CoveWireEnvelope {
        var envelope = incoming
        envelope.source = .remoteCli
        envelope.hostId = alias

        guard var object = envelope.payload.objectValue,
              let socketPath = object["decisionSocket"]?.stringValue,
              !socketPath.isEmpty,
              envelope.directRequest() != nil
        else {
            return envelope
        }
        let token = UUID().uuidString.lowercased()
        routes[token] = DecisionRoute(
            alias: alias,
            socketPath: socketPath,
            createdAt: Date()
        )
        trimRoutesIfNeeded()
        object["decisionSocket"] = .string(Self.routePrefix + token)
        envelope.payload = .object(object)
        return envelope
    }

    private func beginRemoteSend(
        _ frame: CoveDecisionFrame,
        routePath: String,
        continuation: CheckedContinuation<Void, Error>
    ) throws {
        let token = String(routePath.dropFirst(Self.routePrefix.count))
        guard !token.isEmpty,
              let route = routes[token],
              selectedAliases.contains(route.alias),
              let host = hosts[route.alias],
              shouldRun(host),
              let process = host.process,
              process.isRunning,
              let input = host.input,
              let generation = host.generation
        else {
            throw CoveRemoteRelayError.disconnected
        }
        guard !pendingDecisions.values.contains(where: { $0.routeToken == token }) else {
            throw CoveRemoteRelayError.decisionPending
        }

        let controlID = UUID().uuidString.lowercased()
        let control = CoveRemoteDecisionControl(
            controlId: controlID,
            decisionSocket: route.socketPath,
            decision: frame
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(control)
        guard payload.count <= Self.maximumFrameBytes else {
            throw CoveRemoteRelayError.frameTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        let framedControl = framed

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.decisionTimedOut(controlID: controlID)
        }
        pendingDecisions[controlID] = PendingDecision(
            alias: route.alias,
            generation: generation,
            routeToken: token,
            continuation: continuation,
            timeoutWorkItem: timeoutWorkItem
        )
        queue.asyncAfter(
            deadline: .now() + Self.decisionAcknowledgementTimeout,
            execute: timeoutWorkItem
        )

        let alias = route.alias
        host.writeQueue.async { [weak self] in
            do {
                try input.write(contentsOf: framedControl)
            } catch {
                self?.queue.async { [weak self] in
                    self?.controlWriteFailed(
                        controlID: controlID,
                        alias: alias,
                        generation: generation
                    )
                }
            }
        }
    }

    private func receive(
        _ acknowledgement: CoveRemoteDecisionAcknowledgement,
        alias: String,
        generation: UUID
    ) {
        guard let pending = pendingDecisions[acknowledgement.controlId],
              pending.alias == alias,
              pending.generation == generation
        else {
            // A timed-out response or a control ID from another relay
            // generation cannot affect current UI state.
            return
        }
        pendingDecisions.removeValue(forKey: acknowledgement.controlId)
        pending.timeoutWorkItem.cancel()

        switch acknowledgement.status {
        case .delivered:
            routes.removeValue(forKey: pending.routeToken)
            pending.continuation.resume()
        case .failed:
            // The remote helper retains its advertised request after a failed
            // socket delivery, so keep the opaque route available for retry.
            pending.continuation.resume(
                throwing: CoveRemoteRelayError.deliveryFailed
            )
        }
    }

    private func decisionTimedOut(controlID: String) {
        guard let pending = pendingDecisions.removeValue(forKey: controlID) else {
            return
        }
        // Delivery is unknown after a timeout. Do not consume the route, and
        // ignore any acknowledgement that arrives after this continuation.
        pending.continuation.resume(
            throwing: CoveRemoteRelayError.acknowledgementTimedOut
        )
    }

    private func controlWriteFailed(
        controlID: String,
        alias: String,
        generation: UUID
    ) {
        guard let pending = pendingDecisions.removeValue(forKey: controlID),
              pending.alias == alias,
              pending.generation == generation
        else {
            return
        }
        pending.timeoutWorkItem.cancel()
        pending.continuation.resume(throwing: CoveRemoteRelayError.disconnected)
        terminateConnection(alias: alias, generation: generation)
    }

    private static func readFrame(from handle: FileHandle) throws -> Data? {
        guard let header = try readExactly(
            MemoryLayout<UInt32>.size,
            from: handle,
            allowCleanEOF: true
        ) else {
            return nil
        }
        let length = header.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length <= maximumFrameBytes else {
            throw CoveRemoteRelayError.frameTooLarge
        }
        return try readExactly(Int(length), from: handle, allowCleanEOF: false)
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle,
        allowCleanEOF: Bool
    ) throws -> Data? {
        var result = Data()
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            if chunk.isEmpty {
                if allowCleanEOF, result.isEmpty {
                    return nil
                }
                throw CoveRemoteRelayError.truncatedFrame
            }
            result.append(chunk)
        }
        return result
    }

    private func outputEnded(alias: String, generation: UUID) {
        guard let host = hosts[alias], host.generation == generation else { return }
        if let process = host.process, process.isRunning {
            process.terminate()
        } else {
            connectionTerminated(alias: alias, generation: generation)
        }
    }

    private func terminateConnection(alias: String, generation: UUID?) {
        guard let host = hosts[alias],
              generation == nil || host.generation == generation
        else {
            return
        }
        if let process = host.process, process.isRunning {
            process.terminate()
        } else if let generation = host.generation {
            connectionTerminated(alias: alias, generation: generation)
        }
    }

    private func connectionTerminated(alias: String, generation: UUID) {
        guard let host = hosts[alias], host.generation == generation else { return }
        failPendingDecisions(
            for: alias,
            generation: generation,
            with: CoveRemoteRelayError.disconnected
        )
        try? host.input?.close()
        try? host.output?.close()
        host.process = nil
        host.input = nil
        host.output = nil
        host.generation = nil
        removeRoutes(for: alias)
        scheduleReconnect(host)
    }

    private func stop(_ host: HostState) {
        host.reconnectWorkItem?.cancel()
        host.reconnectWorkItem = nil
        failPendingDecisions(
            for: host.alias,
            generation: host.generation,
            with: CoveRemoteRelayError.disconnected
        )
        try? host.input?.close()
        if let process = host.process, process.isRunning {
            process.terminate()
        } else if let generation = host.generation {
            connectionTerminated(alias: host.alias, generation: generation)
        }
    }

    private func scheduleReconnect(_ host: HostState) {
        guard shouldRun(host), host.reconnectWorkItem == nil else { return }
        let exponent = min(host.reconnectAttempt, 5)
        let base = min(30.0, pow(2.0, Double(exponent)))
        let jitter = Double.random(in: 0 ... min(1.0, base * 0.2))
        host.reconnectAttempt = min(host.reconnectAttempt + 1, 6)
        let item = DispatchWorkItem { [weak self, weak host] in
            guard let self, let host else { return }
            host.reconnectWorkItem = nil
            self.connect(host)
        }
        host.reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + base + jitter, execute: item)
    }

    private func shouldRun(_ host: HostState) -> Bool {
        running && networkAvailable && selectedAliases.contains(host.alias)
    }

    private func removeRoutes(for alias: String) {
        routes = routes.filter { $0.value.alias != alias }
    }

    private func failPendingDecisions(
        for alias: String,
        generation: UUID?,
        with error: Error
    ) {
        let controlIDs: [String] = pendingDecisions.compactMap { element in
            let (controlID, pending) = element
            guard pending.alias == alias,
                  generation == nil || pending.generation == generation
            else {
                return nil
            }
            return controlID
        }
        for controlID in controlIDs {
            guard let pending = pendingDecisions.removeValue(forKey: controlID) else {
                continue
            }
            pending.timeoutWorkItem.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func failAllPendingDecisions(with error: Error) {
        let pending = Array(pendingDecisions.values)
        pendingDecisions.removeAll()
        for decision in pending {
            decision.timeoutWorkItem.cancel()
            decision.continuation.resume(throwing: error)
        }
    }

    private func trimRoutesIfNeeded() {
        while routes.count > 4_096,
              let oldest = routes.min(by: { $0.value.createdAt < $1.value.createdAt })
        {
            routes.removeValue(forKey: oldest.key)
        }
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                let previous = self.observedNetworkStatus
                self.observedNetworkStatus = path.status
                self.networkAvailable = path.status == .satisfied
                if path.status == .satisfied {
                    if previous != .satisfied {
                        self.connectSelectedHosts()
                    }
                } else {
                    for host in self.hosts.values {
                        self.stop(host)
                    }
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private static var defaultConfigurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Codex Cove",
                isDirectory: true
            )
            .appendingPathComponent("helper-config.json")
    }
}

private final class HostState: @unchecked Sendable {
    let alias: String
    let writeQueue: DispatchQueue
    var process: Process?
    var input: FileHandle?
    var output: FileHandle?
    var generation: UUID?
    var reconnectAttempt = 0
    var reconnectWorkItem: DispatchWorkItem?

    init(alias: String) {
        self.alias = alias
        self.writeQueue = DispatchQueue(
            label: "local.chris.codexcove.remote-relay-writes.\(alias)",
            qos: .utility
        )
    }
}

private struct HelperConfiguration: Decodable {
    var schemaVersion: Int
    var remoteHosts: [HelperRemoteHost]
}

private struct HelperRemoteHost: Decodable {
    var alias: String
    var enabled: Bool
}

private struct DecisionRoute {
    var alias: String
    var socketPath: String
    var createdAt: Date
}

private struct PendingDecision {
    var alias: String
    var generation: UUID
    var routeToken: String
    var continuation: CheckedContinuation<Void, Error>
    var timeoutWorkItem: DispatchWorkItem
}

enum CoveRemoteRelayError: LocalizedError, Sendable {
    case invalidConfiguration
    case disconnected
    case decisionPending
    case deliveryFailed
    case acknowledgementTimedOut
    case frameTooLarge
    case truncatedFrame

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Remote hosts are unavailable because Cove's helper configuration is invalid."
        case .disconnected:
            "The remote task is disconnected. Answer in its native Codex prompt."
        case .decisionPending:
            "Cove is still waiting for the remote host to confirm this response."
        case .deliveryFailed:
            "The remote host could not deliver this response. Try again or answer in native Codex."
        case .acknowledgementTimedOut:
            "The remote host did not confirm this response in time. Check native Codex before retrying."
        case .frameTooLarge:
            "The remote response exceeds Cove's 1 MiB limit."
        case .truncatedFrame:
            "The remote relay closed during a message."
        }
    }
}
