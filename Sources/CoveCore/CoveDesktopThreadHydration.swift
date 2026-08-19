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
    public var loadedThreadIDs: [String]
    /// False when reconciliation hit its page/task bound. An incomplete set
    /// may add or refresh tasks but must never be used to close unseen ones.
    public var loadedThreadSetIsComplete: Bool

    public init(
        snapshots: [CoveSessionSnapshot],
        hiddenApprovalReviewThreadIDs: [String] = [],
        loadedThreadIDs: [String] = [],
        loadedThreadSetIsComplete: Bool = true
    ) {
        self.snapshots = snapshots
        self.hiddenApprovalReviewThreadIDs = hiddenApprovalReviewThreadIDs
        self.loadedThreadIDs = loadedThreadIDs
        self.loadedThreadSetIsComplete = loadedThreadSetIsComplete
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
        clientVersion: String = "0.9.0"
    ) {
        self.realCodexURL = realCodexURL
        self.requestTimeout = min(30, max(0.25, requestTimeout))
        self.maximumLineBytes = min(1_048_576, max(1_024, maximumLineBytes))
        self.clientVersion = clientVersion
    }

    public static func installed(
        configurationURL: URL = defaultInstalledConfigurationURL(),
        requestTimeout: TimeInterval = defaultRequestTimeout,
        clientVersion: String = "0.9.0"
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

    public func reconcileLoadedDesktopThreads(
        capturedAt: Date = Date()
    ) async -> CoveDesktopThreadDiscoveryResult {
        let configuration = configuration
        return await Task.detached(priority: .utility) {
            if let failure = Self.configurationIsUsable(configuration) {
                return .unavailable(failure)
            }
            do {
                let batch = try CoveAppServerThreadQuery.run(
                    operation: .reconcileLoadedDesktop,
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

    public func reconcileLoadedDesktopThreads() {
        guard discoveryHandler != nil, discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.client.reconcileLoadedDesktopThreads()
            self.discoveryTask = nil
            self.discoveryHandler?(result)
        }
    }
}

public enum CoveDesktopThreadSnapshotParser {
    public struct ThreadTurnSummary: Equatable, Sendable {
        public var latestOutput: String?
        public var activeTurnID: String?

        public init(latestOutput: String?, activeTurnID: String?) {
            self.latestOutput = latestOutput
            self.activeTurnID = activeTurnID
        }
    }

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
        capturedAt: Date,
        acceptingTrustedThreadSpawn: Bool = false
    ) throws -> CoveSessionSnapshot {
        let thread = try self.thread(
            fromResponse: data,
            expectedID: expectedID,
            expectedThreadID: expectedThreadID
        )
        guard !isHiddenInternalThread(thread) else {
            throw CoveDesktopThreadHydrationFailure.hiddenApprovalReviewThread
        }
        guard isConfidentlyDesktopOpenable(thread)
                || (acceptingTrustedThreadSpawn
                    && CoveThreadProvenance.isThreadSpawnAgent(thread)) else {
            throw CoveDesktopThreadHydrationFailure.threadUnavailable
        }
        return try snapshot(
            fromThread: thread,
            expectedThreadID: expectedThreadID,
            capturedAt: capturedAt
        )
    }

    static func thread(
        fromResponse data: Data,
        expectedID: String,
        expectedThreadID: String
    ) throws -> [String: CoveJSONValue] {
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
        return thread
    }

    public static func latestOutput(
        fromThreadTurnsListResponse data: Data,
        expectedID: String
    ) throws -> String? {
        try turnSummary(
            fromThreadTurnsListResponse: data,
            expectedID: expectedID
        ).latestOutput
    }

    public static func turnSummary(
        fromThreadTurnsListResponse data: Data,
        expectedID: String
    ) throws -> ThreadTurnSummary {
        guard let response = try? JSONDecoder().decode(
            CoveJSONValue.self,
            from: data
        ).objectValue,
            response["id"]?.scalarStringValue == expectedID,
            response["error"] == nil || response["error"] == .null,
            let turns = response["result"]?.objectValue?["data"]?.arrayValue
        else {
            throw CoveDesktopThreadHydrationFailure.protocolUnavailable
        }
        let activeTurnID = turns.first(where: {
            $0.objectValue?["status"]?.stringValue == "inProgress"
        })?.objectValue?["id"]?.scalarStringValue.flatMap { value in
            !value.isEmpty && value.utf8.count <= 512 ? value : nil
        }
        var latestOutput: String?
        for turn in turns {
            let items = turn.objectValue?["items"]?.arrayValue ?? []
            for item in items.reversed() {
                guard let object = item.objectValue,
                      object["type"]?.stringValue == "agentMessage",
                      let text = object["text"]?.stringValue
                else { continue }
                let trimmed = text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !trimmed.isEmpty {
                    latestOutput = String(trimmed.prefix(4_000))
                    break
                }
            }
            if latestOutput != nil { break }
        }
        return ThreadTurnSummary(
            latestOutput: latestOutput,
            activeTurnID: activeTurnID
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
        // Composite identity makes an identical opaque ID at another origin a
        // distinct task. Retain the legacy parameters for source compatibility
        // with older callers, but never use them to suppress the Desktop row.
        _ = knownNonDesktopSessionIDs
        _ = currentSnapshots
        return snapshot.source == .codexDesktop
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
            if isHiddenInternalThread(thread) {
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
        guard !isHiddenInternalThread(thread) else {
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
            parentSessionId: CoveThreadProvenance.parentID(in: thread),
            parentProvenanceConflict: CoveThreadProvenance
                .hasConflictingParentID(in: thread),
            liveness: .loaded,
            activeTurnId: activeTurnID(from: thread),
            controlRoute: .desktop,
            unread: capturedAt.timeIntervalSince(timestamp) <= 10 * 60
                && status.status.requiresUnreadAcknowledgement
        )
    }

    public static func loadedThreadPage(
        from data: Data,
        expectedID: String
    ) throws -> (ids: [String], nextCursor: String?) {
        guard let response = try? JSONDecoder().decode(
            CoveJSONValue.self,
            from: data
        ).objectValue,
              response["id"]?.scalarStringValue == expectedID,
              response["error"] == nil || response["error"] == .null,
              let result = response["result"]?.objectValue
        else { throw CoveDesktopThreadHydrationFailure.protocolUnavailable }
        let rows = result["data"]?.arrayValue
            ?? result["threadIds"]?.arrayValue
            ?? result["threads"]?.arrayValue
            ?? []
        let ids = rows.compactMap { row -> String? in
            let value = row.scalarStringValue
                ?? row.objectValue?["id"]?.scalarStringValue
                ?? row.objectValue?["threadId"]?.scalarStringValue
            guard let value,
                  CoveDesktopThreadClient.isSafeThreadIdentifier(value)
            else { return nil }
            return value
        }
        return (
            Array(Set(ids)).sorted(),
            result["nextCursor"]?.scalarStringValue
                ?? result["next_cursor"]?.scalarStringValue
        )
    }

    private static func activeTurnID(
        from thread: [String: CoveJSONValue]
    ) -> String? {
        thread["activeTurnId"]?.scalarStringValue
            ?? thread["activeTurn"]?.objectValue?["id"]?.scalarStringValue
            ?? thread["status"]?.objectValue?["activeTurnId"]?.scalarStringValue
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

    private static func isHiddenInternalThread(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        if thread["model"]?.scalarStringValue == "codex-auto-review" {
            return true
        }
        return CoveThreadProvenance.isExcludedAgent(thread)
    }

    private static func isDesktopDiscoveryCandidate(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        isConfidentlyDesktopOpenable(thread)
    }

    static func isConfidentlyDesktopOpenable(
        _ thread: [String: CoveJSONValue]
    ) -> Bool {
        let authoritativeSource = thread["source"]?.scalarStringValue?
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        if authoritativeSource == "vscode" || authoritativeSource == "appserver" {
            return true
        }
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
    case reconcileLoadedDesktop

    func loadedThreadIDs(fallback: [String]) -> [String] {
        switch self {
        case .read:
            return []
        case .reconcileLoadedDesktop:
            return fallback
        }
    }

    var isReconciliation: Bool {
        if case .reconcileLoadedDesktop = self { return true }
        return false
    }
}

private enum CoveAppServerMode: CaseIterable, Equatable {
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
    private static let loadedListID = "cove-desktop-thread-loaded"
    private static let threadReadID = "cove-desktop-thread-read"
    private static let threadTurnsListID = "cove-desktop-thread-turns"
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
                    initializationTimeout: requestTimeout(
                        for: mode,
                        configuration: configuration
                    )
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
        initializationTimeout: TimeInterval
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

        var deadline = Self.deadline(after: initializationTimeout)
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
                    "capabilities": ["experimentalApi": true],
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
        // Proxy availability must be probed quickly, but a successful proxy
        // gets a separately bounded window for pagination and hydration.
        deadline = Self.deadline(
            after: operation.isReconciliation
                ? 30 : configuration.requestTimeout
        )
        let threadIDs: [String]
        var hiddenApprovalReviewThreadIDs: [String] = []
        // Only the public Desktop proxy owns the Desktop process's in-memory
        // loaded set. A direct-stdio fallback can enrich known IDs, but its
        // empty private process must never unload cards owned by Desktop.
        var loadedThreadSetIsComplete = mode == .proxy
        switch operation {
        case let .read(ids):
            threadIDs = ids
        case .reconcileLoadedDesktop:
            var loaded: [String] = []
            var cursor: String?
            for page in 0..<20 {
                let requestID = "\(loadedListID)-\(page)"
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                try writeJSON(
                    [
                        "id": requestID,
                        "method": "thread/loaded/list",
                        "params": params,
                    ],
                    to: input.fileDescriptor
                )
                let pageResponse = try response(
                    withID: requestID,
                    reader: &reader,
                    responses: &responses,
                    deadline: deadline
                )
                let parsed = try CoveDesktopThreadSnapshotParser.loadedThreadPage(
                    from: pageResponse,
                    expectedID: requestID
                )
                loaded.append(contentsOf: parsed.ids)
                guard let next = parsed.nextCursor else { break }
                guard next != cursor,
                      loaded.count < 500,
                      page < 19
                else {
                    loadedThreadSetIsComplete = false
                    break
                }
                cursor = next
            }
            threadIDs = Array(Set(loaded.prefix(500))).sorted()
        }
        guard !threadIDs.isEmpty else {
            return .init(
                snapshots: [],
                hiddenApprovalReviewThreadIDs: hiddenApprovalReviewThreadIDs,
                loadedThreadIDs: threadIDs,
                loadedThreadSetIsComplete: loadedThreadSetIsComplete
            )
        }
        var snapshots: [CoveSessionSnapshot] = []
        let hydrationBatchSize = 8
        for start in stride(
            from: 0,
            to: threadIDs.count,
            by: hydrationBatchSize
        ) {
            let end = min(start + hydrationBatchSize, threadIDs.count)
            let batchIDs = Array(threadIDs[start..<end])
            for threadID in batchIDs {
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
            var batchSnapshots: [CoveSessionSnapshot] = []
            for threadID in batchIDs {
                let expectedID = "\(threadReadID)-\(threadID)"
                do {
                    let threadResponse = try response(
                        withID: expectedID,
                        reader: &reader,
                        responses: &responses,
                        deadline: deadline
                    )
                    let thread = try CoveDesktopThreadSnapshotParser.thread(
                        fromResponse: threadResponse,
                        expectedID: expectedID,
                        expectedThreadID: threadID
                    )
                    guard try hasTrustedDesktopRoot(
                        for: thread,
                        expectedThreadID: threadID,
                        reader: &reader,
                        responses: &responses,
                        input: input.fileDescriptor,
                        deadline: deadline
                    ) else { continue }
                    batchSnapshots.append(
                        try CoveDesktopThreadSnapshotParser.parseResponse(
                            threadResponse,
                            expectedID: expectedID,
                            expectedThreadID: threadID,
                            capturedAt: capturedAt,
                            acceptingTrustedThreadSpawn: true
                        )
                    )
                } catch CoveDesktopThreadHydrationFailure
                    .hiddenApprovalReviewThread {
                    hiddenApprovalReviewThreadIDs.append(threadID)
                } catch {
                    // A missing/deleted ordinary task should not make the
                    // entire reconciliation unavailable.
                }
            }
            var requestedTurnIDs = Set<String>()
            for snapshot in batchSnapshots {
                let threadID = snapshot.sessionId ?? snapshot.snapshotId
                do {
                    try writeJSON(
                        [
                            "id": "\(threadTurnsListID)-\(threadID)",
                            "method": "thread/turns/list",
                            "params": [
                                "threadId": threadID,
                                "limit": 8,
                                "sortDirection": "desc",
                                "itemsView": "summary",
                            ],
                        ],
                        to: input.fileDescriptor
                    )
                    requestedTurnIDs.insert(threadID)
                } catch {
                    // This optional public method may be unavailable on an
                    // older app-server connection.
                }
            }
            for var snapshot in batchSnapshots {
                let threadID = snapshot.sessionId ?? snapshot.snapshotId
                let expectedID = "\(threadTurnsListID)-\(threadID)"
                if requestedTurnIDs.contains(threadID) {
                    do {
                        let turnsResponse = try response(
                            withID: expectedID,
                            reader: &reader,
                            responses: &responses,
                            deadline: deadline
                        )
                        let summary = try CoveDesktopThreadSnapshotParser
                            .turnSummary(
                                fromThreadTurnsListResponse: turnsResponse,
                                expectedID: expectedID
                            )
                        snapshot.latestOutput = summary.latestOutput
                        snapshot.activeTurnId = summary.activeTurnID
                    } catch {
                        // Output and active-turn enrichment are optional. An
                        // active task without an exact ID stays read-only.
                    }
                }
                snapshots.append(snapshot)
            }
        }
        return .init(
            snapshots: snapshots,
            hiddenApprovalReviewThreadIDs: Array(
                Set(hiddenApprovalReviewThreadIDs)
            ).sorted(),
            loadedThreadIDs: operation.loadedThreadIDs(fallback: threadIDs),
            loadedThreadSetIsComplete: loadedThreadSetIsComplete
        )
    }

    private static func hasTrustedDesktopRoot(
        for initial: [String: CoveJSONValue],
        expectedThreadID: String,
        reader: inout CoveDesktopBoundedLineReader,
        responses: inout CoveDesktopResponseBuffer,
        input: Int32,
        deadline: UInt64
    ) throws -> Bool {
        var thread = initial
        var expected = expectedThreadID
        var visited = Set<String>()
        for _ in 0..<32 {
            guard thread["id"]?.scalarStringValue == expected,
                  visited.insert(expected).inserted,
                  !CoveThreadProvenance.hasConflictingParentID(in: thread),
                  !CoveThreadProvenance.isExcludedAgent(thread)
            else { return false }
            if !CoveThreadProvenance.isThreadSpawnAgent(thread) {
                return CoveDesktopThreadSnapshotParser
                    .isConfidentlyDesktopOpenable(thread)
            }
            guard
                  let parent = CoveThreadProvenance.parentID(in: thread),
                  CoveDesktopThreadClient.isSafeThreadIdentifier(parent),
                  !visited.contains(parent)
            else { return false }
            let requestID = "cove-desktop-thread-root-\(UUID().uuidString.lowercased())"
            try writeJSON(
                [
                    "id": requestID,
                    "method": "thread/read",
                    "params": ["threadId": parent, "includeTurns": false],
                ],
                to: input
            )
            let data = try response(
                withID: requestID,
                reader: &reader,
                responses: &responses,
                deadline: deadline
            )
            thread = try CoveDesktopThreadSnapshotParser.thread(
                fromResponse: data,
                expectedID: requestID,
                expectedThreadID: parent
            )
            expected = parent
        }
        return false
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

    private static func deadline(after timeout: TimeInterval) -> UInt64 {
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        return now > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : now + timeoutNanoseconds
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

struct CoveDesktopBoundedLineReader {
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
