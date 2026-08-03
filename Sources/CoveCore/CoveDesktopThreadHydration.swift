import Darwin
import Foundation

public enum CoveDesktopThreadHydrationFailure: String, Error, Codable, Equatable, Sendable {
    case configurationUnavailable
    case executableUnavailable
    case invalidThreadIdentifier
    case launchFailed
    case timedOut
    case responseTooLarge
    case protocolUnavailable
    case threadUnavailable
    case hiddenApprovalReviewThread
}

public struct CoveDesktopThreadDiscoveryBatch: Equatable, Sendable {
    public var snapshots: [CoveSessionSnapshot]
    public var hiddenApprovalReviewThreadIDs: [String]

    public init(
        snapshots: [CoveSessionSnapshot],
        hiddenApprovalReviewThreadIDs: [String] = []
    ) {
        self.snapshots = snapshots
        self.hiddenApprovalReviewThreadIDs = hiddenApprovalReviewThreadIDs
    }
}

public enum CoveDesktopThreadHydrationResult: Equatable, Sendable {
    case available(CoveSessionSnapshot)
    case unavailable(CoveDesktopThreadHydrationFailure)
}

public enum CoveDesktopThreadDiscoveryResult: Equatable, Sendable {
    case available(CoveDesktopThreadDiscoveryBatch)
    case unavailable(CoveDesktopThreadHydrationFailure)
}

public struct CoveDesktopThreadHydrationConfiguration: Equatable, Sendable {
    public static let defaultRequestTimeout: TimeInterval = 6
    public static let defaultMaximumLineBytes = 1_048_576

    public var realCodexURL: URL
    public var requestTimeout: TimeInterval
    public var maximumLineBytes: Int
    public var clientVersion: String

    public init(
        realCodexURL: URL,
        requestTimeout: TimeInterval = defaultRequestTimeout,
        maximumLineBytes: Int = defaultMaximumLineBytes,
        clientVersion: String = "0.2.0"
    ) {
        self.realCodexURL = realCodexURL
        self.requestTimeout = min(30, max(0.25, requestTimeout))
        self.maximumLineBytes = min(1_048_576, max(1_024, maximumLineBytes))
        self.clientVersion = clientVersion
    }

    public static func installed(
        configurationURL: URL = defaultInstalledConfigurationURL(),
        requestTimeout: TimeInterval = defaultRequestTimeout,
        clientVersion: String = "0.2.0"
    ) throws -> Self {
        struct InstalledHelperConfiguration: Decodable {
            var realCodex: String?
            var maxFrameBytes: Int?
        }

        let installed: InstalledHelperConfiguration
        do {
            installed = try JSONDecoder().decode(
                InstalledHelperConfiguration.self,
                from: Data(contentsOf: configurationURL, options: [.mappedIfSafe])
            )
        } catch {
            throw CoveDesktopThreadHydrationFailure.configurationUnavailable
        }
        guard let path = installed.realCodex,
              NSString(string: path).isAbsolutePath else {
            throw CoveDesktopThreadHydrationFailure.configurationUnavailable
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CoveDesktopThreadHydrationFailure.executableUnavailable
        }
        return Self(
            realCodexURL: url,
            requestTimeout: requestTimeout,
            maximumLineBytes: installed.maxFrameBytes ?? defaultMaximumLineBytes,
            clientVersion: clientVersion
        )
    }

    public static func defaultInstalledConfigurationURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Codex Cove/helper-config.json"
            )
    }
}

public struct CoveDesktopThreadClient: Sendable {
    public let configuration: CoveDesktopThreadHydrationConfiguration

    public init(configuration: CoveDesktopThreadHydrationConfiguration) {
        self.configuration = configuration
    }

    public func fetch(
        threadID: String,
        capturedAt: Date = Date()
    ) async -> CoveDesktopThreadHydrationResult {
        let result = await fetch(threadIDs: [threadID], capturedAt: capturedAt)
        switch result {
        case let .available(batch):
            if batch.hiddenApprovalReviewThreadIDs.contains(threadID) {
                return .unavailable(.hiddenApprovalReviewThread)
            }
            return batch.snapshots.first.map(CoveDesktopThreadHydrationResult.available)
                ?? .unavailable(.threadUnavailable)
        case let .unavailable(failure):
            return .unavailable(failure)
        }
    }

    public func fetch(
        threadIDs: [String],
        capturedAt: Date = Date()
    ) async -> CoveDesktopThreadDiscoveryResult {
        let configuration = configuration
        let uniqueThreadIDs = Array(Set(threadIDs)).sorted()
        return await Task.detached(priority: .utility) {
            guard !uniqueThreadIDs.isEmpty else {
                return .available(.init(snapshots: []))
            }
            guard uniqueThreadIDs.allSatisfy(Self.isSafeThreadIdentifier) else {
                return .unavailable(.invalidThreadIdentifier)
            }
            if let failure = Self.configurationIsUsable(configuration) {
                return .unavailable(failure)
            }

            do {
                let batch = try CoveAppServerThreadQuery.run(
                    operation: .read(threadIDs: uniqueThreadIDs),
                    configuration: configuration,
                    capturedAt: capturedAt
                )
                return .available(batch)
            } catch let failure as CoveDesktopThreadHydrationFailure {
                return .unavailable(failure)
            } catch {
                return .unavailable(.protocolUnavailable)
            }
        }.value
    }

    public func discoverRecentDesktopThreads(
        limit: Int = 3,
        capturedAt: Date = Date()
    ) async -> CoveDesktopThreadDiscoveryResult {
        let configuration = configuration
        let boundedLimit = min(10, max(1, limit))
        return await Task.detached(priority: .utility) {
            if let failure = Self.configurationIsUsable(configuration) {
                return .unavailable(failure)
            }
            do {
                let batch = try CoveAppServerThreadQuery.run(
                    operation: .discoverRecentDesktop(limit: boundedLimit),
                    configuration: configuration,
                    capturedAt: capturedAt
                )
                return .available(batch)
            } catch let failure as CoveDesktopThreadHydrationFailure {
                return .unavailable(failure)
            } catch {
                return .unavailable(.protocolUnavailable)
            }
        }.value
    }

    public static func isSafeThreadIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                return true
            default:
                return false
            }
        }
    }

    private static func configurationIsUsable(
        _ configuration: CoveDesktopThreadHydrationConfiguration
    ) -> CoveDesktopThreadHydrationFailure? {
        guard configuration.realCodexURL.isFileURL,
              NSString(string: configuration.realCodexURL.path).isAbsolutePath else {
            return .configurationUnavailable
        }
        guard FileManager.default.isExecutableFile(
            atPath: configuration.realCodexURL.path
        ) else {
            return .executableUnavailable
        }
        return nil
    }
}

@MainActor
public final class CoveDesktopThreadHydrator {
    public typealias UpdateHandler = @MainActor (CoveDesktopThreadHydrationResult, String) -> Void
    public typealias DiscoveryHandler = @MainActor (CoveDesktopThreadDiscoveryResult) -> Void

    private let client: CoveDesktopThreadClient
    private var queuedThreadIDs = Set<String>()
    private var updateHandler: UpdateHandler?
    private var discoveryHandler: DiscoveryHandler?
    private var hydrationTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?

    public init(configuration: CoveDesktopThreadHydrationConfiguration) {
        self.client = CoveDesktopThreadClient(configuration: configuration)
    }

    public func start(
        onUpdate: @escaping UpdateHandler,
        onDiscovery: DiscoveryHandler? = nil
    ) {
        updateHandler = onUpdate
        discoveryHandler = onDiscovery
    }

    public func stop() {
        hydrationTask?.cancel()
        hydrationTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        updateHandler = nil
        discoveryHandler = nil
        queuedThreadIDs.removeAll()
    }

    public func hydrate(threadID: String) {
        guard updateHandler != nil,
              CoveDesktopThreadClient.isSafeThreadIdentifier(threadID) else {
            return
        }
        queuedThreadIDs.insert(threadID)
        guard hydrationTask == nil else { return }
        hydrationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.queuedThreadIDs.isEmpty {
                let threadIDs = Array(self.queuedThreadIDs).sorted()
                self.queuedThreadIDs.removeAll()
                let result = await self.client.fetch(threadIDs: threadIDs)
                switch result {
                case let .available(batch):
                    let byID = Dictionary(
                        uniqueKeysWithValues: batch.snapshots.map {
                            (($0.sessionId ?? $0.snapshotId), $0)
                        }
                    )
                    for threadID in threadIDs {
                        if let snapshot = byID[threadID] {
                            self.updateHandler?(.available(snapshot), threadID)
                        } else if batch.hiddenApprovalReviewThreadIDs.contains(threadID) {
                            self.updateHandler?(
                                .unavailable(.hiddenApprovalReviewThread),
                                threadID
                            )
                        } else {
                            self.updateHandler?(.unavailable(.threadUnavailable), threadID)
                        }
                    }
                case let .unavailable(failure):
                    for threadID in threadIDs {
                        self.updateHandler?(.unavailable(failure), threadID)
                    }
                }
            }
            self.hydrationTask = nil
        }
    }

    public func discoverRecentDesktopThreads(limit: Int = 3) {
        guard discoveryHandler != nil, discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.client.discoverRecentDesktopThreads(limit: limit)
            self.discoveryTask = nil
            self.discoveryHandler?(result)
        }
    }
}

public enum CoveDesktopThreadSnapshotParser {
    public struct ThreadListSelection: Equatable, Sendable {
        public var discoverableDesktopThreadIDs: [String]
        public var hiddenApprovalReviewThreadIDs: [String]

        public init(
            discoverableDesktopThreadIDs: [String],
            hiddenApprovalReviewThreadIDs: [String]
        ) {
            self.discoverableDesktopThreadIDs = discoverableDesktopThreadIDs
            self.hiddenApprovalReviewThreadIDs = hiddenApprovalReviewThreadIDs
        }
    }

    public static func parseResponse(
        _ data: Data,
        expectedID: String,
        expectedThreadID: String,
        capturedAt: Date
    ) throws -> CoveSessionSnapshot {
        let value: CoveJSONValue
        do {
            value = try JSONDecoder().decode(CoveJSONValue.self, from: data)
        } catch {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        guard let response = value.objectValue,
              response["id"]?.scalarStringValue == expectedID else {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        if let error = response["error"], error != .null {
            throw CoveDesktopThreadHydrationFailure.threadUnavailable
        }
        guard let result = response["result"]?.objectValue,
              let thread = result["thread"]?.objectValue,
              let threadID = thread["id"]?.scalarStringValue,
              threadID == expectedThreadID else {
            throw CoveDesktopThreadHydrationFailure.threadUnavailable
        }
        guard !isApprovalReviewThread(thread) else {
            throw CoveDesktopThreadHydrationFailure.hiddenApprovalReviewThread
        }
        guard isConfidentlyDesktopOpenable(thread) else {
            throw CoveDesktopThreadHydrationFailure.threadUnavailable
        }

        return try snapshot(
            fromThread: thread,
            expectedThreadID: expectedThreadID,
            capturedAt: capturedAt
        )
    }

    public static func discoverableDesktopThreadIDs(
        fromThreadListResponse data: Data,
        expectedID: String,
        limit: Int
    ) throws -> [String] {
        try threadListSelection(
            fromThreadListResponse: data,
            expectedID: expectedID,
            limit: limit
        ).discoverableDesktopThreadIDs
    }

    /// Startup hydration may validate records already known to have originated
    /// in Codex Desktop. Local and remote records retain their exact terminal
    /// identity and are never sent through the Desktop reader.
    public static func startupDesktopThreadIDs(
        from records: [CoveSessionMetadata]
    ) -> [String] {
        Array(
            Set(
                records.lazy
                    .filter { $0.source == .codexDesktop }
                    .map(\.sessionId)
                    .filter(CoveDesktopThreadClient.isSafeThreadIdentifier)
            )
        ).sorted()
    }

    /// A Desktop discovery/read must not replace a session whose source is
    /// already known to be a CLI or remote origin.
    public static func canApplyDesktopSnapshot(
        _ snapshot: CoveSessionSnapshot,
        excluding knownNonDesktopSessionIDs: Set<String>,
        currentSnapshots: [CoveSessionSnapshot]
    ) -> Bool {
        let sessionID = snapshot.sessionId ?? snapshot.snapshotId
        guard snapshot.source == .codexDesktop,
              !knownNonDesktopSessionIDs.contains(sessionID) else {
            return false
        }
        return !currentSnapshots.contains { current in
            let currentSessionID = current.sessionId ?? current.snapshotId
            return currentSessionID == sessionID
                && current.source != nil
                && current.source != .codexDesktop
        }
    }

    public static func threadListSelection(
        fromThreadListResponse data: Data,
        expectedID: String,
        limit: Int
    ) throws -> ThreadListSelection {
        let value: CoveJSONValue
        do {
            value = try JSONDecoder().decode(CoveJSONValue.self, from: data)
        } catch {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        guard let response = value.objectValue,
              response["id"]?.scalarStringValue == expectedID else {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        if let error = response["error"], error != .null {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        guard let result = response["result"]?.objectValue else {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        let rows = result["data"]?.arrayValue
            ?? result["threads"]?.arrayValue
            ?? []
        var ids: [String] = []
        var hiddenApprovalReviewThreadIDs: [String] = []
        for row in rows {
            guard let thread = row.objectValue else { continue }
            if isApprovalReviewThread(thread) {
                if let id = thread["id"]?.scalarStringValue,
                   CoveDesktopThreadClient.isSafeThreadIdentifier(id),
                   !hiddenApprovalReviewThreadIDs.contains(id) {
                    hiddenApprovalReviewThreadIDs.append(id)
                }
                continue
            }
            guard ids.count < limit,
                  isDesktopDiscoveryCandidate(thread),
                  isDiscoverableThread(thread),
                  let id = thread["id"]?.scalarStringValue,
                  CoveDesktopThreadClient.isSafeThreadIdentifier(id),
                  !ids.contains(id) else {
                continue
            }
            ids.append(id)
        }
        return ThreadListSelection(
            discoverableDesktopThreadIDs: ids,
            hiddenApprovalReviewThreadIDs: hiddenApprovalReviewThreadIDs
        )
    }

    private static func snapshot(
        fromThread thread: [String: CoveJSONValue],
        expectedThreadID: String,
        capturedAt: Date
    ) throws -> CoveSessionSnapshot {
        guard let threadID = thread["id"]?.scalarStringValue,
              threadID == expectedThreadID else {
            throw CoveDesktopThreadHydrationFailure.threadUnavailable
        }
        guard !isApprovalReviewThread(thread) else {
            throw CoveDesktopThreadHydrationFailure.hiddenApprovalReviewThread
        }
        let status = status(from: thread)
        let timestamp = threadTimestamp(from: thread, fallback: capturedAt)
        let title = [
            thread["name"]?.stringValue,
            thread["title"]?.stringValue,
            thread["summary"]?.stringValue,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
            ?? "Codex Desktop task"
        let detail = detail(from: thread)
        return CoveSessionSnapshot(
            snapshotId: threadID,
            status: status.status,
            priority: status.priority,
            title: title,
            detail: detail,
            timestamp: timestamp,
            sessionId: threadID,
            source: .codexDesktop,
            parentSessionId: thread["parentThreadId"]?.scalarStringValue
                ?? thread["parentSessionId"]?.scalarStringValue,
            unread: capturedAt.timeIntervalSince(timestamp) <= 10 * 60
                && (
                    status.status == .waitingApproval
                        || status.status == .waitingInput
                        || status.status == .blocked
                        || status.status == .failed
                )
        )
    }

    private static func threadTimestamp(
        from thread: [String: CoveJSONValue],
        fallback: Date
    ) -> Date {
        for key in ["updatedAt", "updated_at", "recencyAt", "createdAt"] {
            guard let value = thread[key] else { continue }
            let rawSeconds: Double?
            switch value {
            case let .number(value):
                rawSeconds = value
            case let .string(value):
                rawSeconds = Double(value)
            default:
                rawSeconds = nil
            }
            guard var seconds = rawSeconds,
                  seconds.isFinite,
                  seconds > 0 else { continue }
            if seconds > 10_000_000_000 {
                seconds /= 1_000
            }
            let date = Date(timeIntervalSince1970: seconds)
            return min(date, fallback)
        }
        return fallback
    }

    private static func isDiscoverableThread(_ thread: [String: CoveJSONValue]) -> Bool {
        let status = status(from: thread)
        if status.isNotLoaded {
            return true
        }
        switch status.status {
        case .working, .active, .waitingApproval, .waitingInput, .blocked, .compacting:
            return true
        case .idle, .listening, .quiet, .hidden, .completed, .failed, .interrupted:
            return false
        }
    }

    private static func isApprovalReviewThread(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        if thread["model"]?.scalarStringValue == "codex-auto-review" {
            return true
        }
        guard let source = thread["source"]?.objectValue else { return false }
        let subagent = source["subAgent"]?.objectValue
            ?? source["subagent"]?.objectValue
            ?? source["sub_agent"]?.objectValue
        return subagent?["other"]?.scalarStringValue == "guardian"
    }

    private static func isDesktopDiscoveryCandidate(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        isConfidentlyDesktopOpenable(thread)
    }

    private static func isConfidentlyDesktopOpenable(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        let candidates = scalarStrings(thread["source"])
            + scalarStrings(thread["sourceKind"])
            + scalarStrings(thread["sourceKinds"])
            + scalarStrings(thread["source_kind"])
            + scalarStrings(thread["source_kinds"])
            + scalarStrings(thread["client"])
            + scalarStrings(thread["origin"])
            + scalarStrings(thread["app"])
        let nestedSource = thread["source"]?.objectValue
        let nestedCandidates = scalarStrings(nestedSource?["kind"])
            + scalarStrings(nestedSource?["name"])
        let normalized = (candidates + nestedCandidates).map {
                $0.replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
            }
        if normalized.contains(where: {
            $0 == "localcli" || $0 == "remotecli"
        }) {
            return false
        }
        if normalized.contains(where: {
            $0.contains("desktop") || $0.contains("codexapp")
        }) {
            return true
        }
        // This is the public source/status shape currently emitted for a
        // Codex Desktop task whose state has not been loaded into the app UI.
        // A bare `vscode` marker is not sufficient for an active CLI task.
        return status(from: thread).isNotLoaded
            && normalized.contains("vscode")
    }

    private static func status(
        from thread: [String: CoveJSONValue]
    ) -> (status: CoveSessionStatus, priority: Int, isNotLoaded: Bool) {
        let value = thread["status"]
        let raw: String
        let flags: [String]
        if let object = value?.objectValue {
            raw = object["type"]?.scalarStringValue
                ?? object["state"]?.scalarStringValue
                ?? object["status"]?.scalarStringValue
                ?? ""
            flags = object["activeFlags"]?.arrayValue?.compactMap(\.scalarStringValue)
                ?? object["flags"]?.arrayValue?.compactMap(\.scalarStringValue)
                ?? []
        } else {
            raw = value?.scalarStringValue
                ?? thread["statusKind"]?.scalarStringValue
                ?? thread["status_kind"]?.scalarStringValue
                ?? ""
            flags = scalarStrings(thread["statusKinds"])
                + scalarStrings(thread["status_kinds"])
        }
        let normalized = raw.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let normalizedFlags = flags.map {
            $0.replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
        }
        if normalized == "notloaded"
            || normalizedFlags.contains("notloaded") {
            return (.idle, 5, true)
        }
        if normalizedFlags.contains(where: { $0.contains("approval") })
            || normalized.contains("approval") {
            return (.waitingApproval, 100, false)
        }
        if normalizedFlags.contains(where: { $0.contains("input") || $0.contains("question") })
            || normalized.contains("input")
            || normalized.contains("question") {
            return (.waitingInput, 95, false)
        }
        if normalized.contains("blocked") {
            return (.blocked, 100, false)
        }
        if normalized.contains("failed") || normalized.contains("error") {
            return (.failed, 90, false)
        }
        if normalized.contains("interrupt") || normalized.contains("abort") {
            return (.interrupted, 85, false)
        }
        if normalized.contains("complete") || normalized.contains("done") {
            return (.completed, 80, false)
        }
        if normalized.contains("compact") {
            return (.compacting, 60, false)
        }
        if normalized.contains("idle") {
            return (.idle, 5, false)
        }
        if normalized.isEmpty {
            return (.active, 40, false)
        }
        return (.working, 40, false)
    }

    private static func detail(from thread: [String: CoveJSONValue]) -> String? {
        let candidates = [
            thread["cwd"]?.scalarStringValue,
            thread["model"]?.scalarStringValue,
            thread["sourceKind"]?.scalarStringValue,
        ]
        let values = (candidates
            + scalarStrings(thread["sourceKinds"]))
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "Codex Desktop" : values.joined(separator: " · ")
    }

    private static func scalarStrings(_ value: CoveJSONValue?) -> [String] {
        if let scalar = value?.scalarStringValue {
            return [scalar]
        }
        return value?.arrayValue?.compactMap(\.scalarStringValue) ?? []
    }
}

private enum CoveAppServerThreadOperation {
    case read(threadIDs: [String])
    case discoverRecentDesktop(limit: Int)
}

private enum CoveAppServerMode: CaseIterable {
    case proxy
    case directStdio

    var arguments: [String] {
        switch self {
        case .proxy:
            return ["app-server", "proxy"]
        case .directStdio:
            return ["app-server", "--stdio"]
        }
    }
}

private enum CoveAppServerThreadQuery {
    private static let initializeID = "cove-desktop-initialize"
    private static let threadListID = "cove-desktop-thread-list"
    private static let threadReadID = "cove-desktop-thread-read"
    private static let maximumMessagesPerRequest = 256
    private static let proxyProbeTimeout: TimeInterval = 0.75

    static func run(
        operation: CoveAppServerThreadOperation,
        configuration: CoveDesktopThreadHydrationConfiguration,
        capturedAt: Date
    ) throws -> CoveDesktopThreadDiscoveryBatch {
        var lastFailure: CoveDesktopThreadHydrationFailure = .protocolUnavailable
        for mode in CoveAppServerMode.allCases {
            do {
                return try run(
                    operation: operation,
                    configuration: configuration,
                    capturedAt: capturedAt,
                    mode: mode,
                    requestTimeout: requestTimeout(for: mode, configuration: configuration)
                )
            } catch let failure as CoveDesktopThreadHydrationFailure {
                lastFailure = failure
                continue
            }
        }
        throw lastFailure
    }

    private static func run(
        operation: CoveAppServerThreadOperation,
        configuration: CoveDesktopThreadHydrationConfiguration,
        capturedAt: Date,
        mode: CoveAppServerMode,
        requestTimeout: TimeInterval
    ) throws -> CoveDesktopThreadDiscoveryBatch {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = configuration.realCodexURL
        process.arguments = mode.arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_COVE_BYPASS"] = "1"
        environment["RUST_LOG"] = "off"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CoveDesktopThreadHydrationFailure.launchFailed
        }

        let input = standardInput.fileHandleForWriting
        let output = standardOutput.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            try? input.close()
            try? output.close()
            stopAndReap(process)
        }

        let timeoutNanoseconds = UInt64(
            requestTimeout * 1_000_000_000
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : now + timeoutNanoseconds
        var reader = CoveDesktopBoundedLineReader(
            fileDescriptor: output.fileDescriptor,
            maximumLineBytes: configuration.maximumLineBytes
        )
        var responses = CoveDesktopResponseBuffer()

        try writeJSON(
            [
                "id": initializeID,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex_cove",
                        "title": "Codex Cove",
                        "version": configuration.clientVersion,
                    ],
                    "capabilities": ["experimentalApi": false],
                ],
            ],
            to: input.fileDescriptor
        )
        _ = try response(
            withID: initializeID,
            reader: &reader,
            responses: &responses,
            deadline: deadline
        )

        try writeJSON(
            ["method": "initialized", "params": [String: Any]()],
            to: input.fileDescriptor
        )
        let threadIDs: [String]
        var hiddenApprovalReviewThreadIDs: [String] = []
        switch operation {
        case let .read(ids):
            threadIDs = ids
        case let .discoverRecentDesktop(limit):
            try writeJSON(
                [
                    "id": threadListID,
                    "method": "thread/list",
                    "params": [
                        "limit": max(1, limit * 4),
                        "archived": false,
                        "sourceKinds": ["vscode"],
                        "sortKey": "updated_at",
                        "sortDirection": "desc",
                        "useStateDbOnly": true,
                    ],
                ],
                to: input.fileDescriptor
            )
            let listResponse = try response(
                withID: threadListID,
                reader: &reader,
                responses: &responses,
                deadline: deadline
            )
            let selection = try CoveDesktopThreadSnapshotParser
                .threadListSelection(
                    fromThreadListResponse: listResponse,
                    expectedID: threadListID,
                    limit: limit
                )
            threadIDs = selection.discoverableDesktopThreadIDs
            hiddenApprovalReviewThreadIDs =
                selection.hiddenApprovalReviewThreadIDs
        }
        guard !threadIDs.isEmpty else {
            return .init(
                snapshots: [],
                hiddenApprovalReviewThreadIDs: hiddenApprovalReviewThreadIDs
            )
        }
        for threadID in threadIDs {
            try writeJSON(
                [
                    "id": "\(threadReadID)-\(threadID)",
                    "method": "thread/read",
                    "params": [
                        "threadId": threadID,
                        "includeTurns": false,
                    ],
                ],
                to: input.fileDescriptor
            )
        }
        var snapshots: [CoveSessionSnapshot] = []
        for threadID in threadIDs {
            let expectedID = "\(threadReadID)-\(threadID)"
            let threadResponse = try response(
                withID: expectedID,
                reader: &reader,
                responses: &responses,
                deadline: deadline
            )
            do {
                let snapshot = try CoveDesktopThreadSnapshotParser.parseResponse(
                    threadResponse,
                    expectedID: expectedID,
                    expectedThreadID: threadID,
                    capturedAt: capturedAt
                )
                snapshots.append(snapshot)
            } catch CoveDesktopThreadHydrationFailure.hiddenApprovalReviewThread {
                hiddenApprovalReviewThreadIDs.append(threadID)
            } catch {
                // A missing/deleted ordinary task should not make the whole
                // discovery batch unavailable or delete persisted jump data.
            }
        }
        return .init(
            snapshots: snapshots,
            hiddenApprovalReviewThreadIDs: Array(
                Set(hiddenApprovalReviewThreadIDs)
            ).sorted()
        )
    }

    private static func requestTimeout(
        for mode: CoveAppServerMode,
        configuration: CoveDesktopThreadHydrationConfiguration
    ) -> TimeInterval {
        switch mode {
        case .proxy:
            return min(configuration.requestTimeout, proxyProbeTimeout)
        case .directStdio:
            return configuration.requestTimeout
        }
    }

    private static func response(
        withID expectedID: String,
        reader: inout CoveDesktopBoundedLineReader,
        responses: inout CoveDesktopResponseBuffer,
        deadline: UInt64
    ) throws -> Data {
        if let buffered = responses.removeResponse(withID: expectedID) {
            let object = try responseObject(from: buffered)
            return try checkedResponse(buffered, object: object)
        }
        for _ in 0..<maximumMessagesPerRequest {
            let line = try reader.readLine(deadline: deadline)
            guard let object = try? responseObject(from: line),
                  let id = object["id"]?.scalarStringValue else {
                continue
            }
            guard id == expectedID else {
                responses.storeResponse(line, withID: id)
                continue
            }
            return try checkedResponse(line, object: object)
        }
        throw CoveDesktopThreadHydrationFailure.protocolUnavailable
    }

    private static func responseObject(from data: Data) throws -> [String: CoveJSONValue] {
        guard let value = try? JSONDecoder().decode(
            CoveJSONValue.self,
            from: data
        ), let object = value.objectValue else {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        return object
    }

    private static func checkedResponse(
        _ data: Data,
        object: [String: CoveJSONValue]
    ) throws -> Data {
        if let error = object["error"], error != .null {
            throw CoveDesktopThreadHydrationFailure.threadUnavailable
        }
        return data
    }

    private static func writeJSON(
        _ object: [String: Any],
        to fileDescriptor: Int32
    ) throws {
        var data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        } catch {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        data.append(0x0A)

        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, pointer, remaining)
                if written > 0 {
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw CoveDesktopThreadHydrationFailure.protocolUnavailable
                }
            }
        }
    }

    private static func stopAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            while process.isRunning,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                usleep(10_000)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }
}

private struct CoveDesktopResponseBuffer {
    private var responsesByID = [String: Data]()

    mutating func storeResponse(_ data: Data, withID id: String) {
        guard responsesByID.count < 256 else { return }
        responsesByID[id] = data
    }

    mutating func removeResponse(withID id: String) -> Data? {
        responsesByID.removeValue(forKey: id)
    }
}

private struct CoveDesktopBoundedLineReader {
    let fileDescriptor: Int32
    let maximumLineBytes: Int
    private var buffered = Data()

    init(fileDescriptor: Int32, maximumLineBytes: Int) {
        self.fileDescriptor = fileDescriptor
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func readLine(deadline: UInt64) throws -> Data {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                guard newline <= maximumLineBytes else {
                    throw CoveDesktopThreadHydrationFailure.responseTooLarge
                }
                var line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                return Data(line)
            }
            guard buffered.count <= maximumLineBytes else {
                throw CoveDesktopThreadHydrationFailure.responseTooLarge
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw CoveDesktopThreadHydrationFailure.timedOut
            }
            let remainingMilliseconds = min(
                UInt64(Int32.max),
                max(1, (deadline - now + 999_999) / 1_000_000)
            )
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(remainingMilliseconds)
            )
            if pollResult == 0 {
                throw CoveDesktopThreadHydrationFailure.timedOut
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw CoveDesktopThreadHydrationFailure.protocolUnavailable
            }

            var chunk = [UInt8](
                repeating: 0,
                count: min(8_192, maximumLineBytes + 1)
            )
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                buffered.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                throw CoveDesktopThreadHydrationFailure.protocolUnavailable
            } else if errno != EINTR {
                throw CoveDesktopThreadHydrationFailure.protocolUnavailable
            }
        }
    }
}
