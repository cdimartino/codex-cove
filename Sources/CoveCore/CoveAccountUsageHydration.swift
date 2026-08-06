import Darwin
import Foundation

public enum CoveRateLimitsResponseError: Error, Equatable, Sendable {
    case invalidJSON
    case unexpectedResponse
    case serverRejectedRequest
    case missingRateLimits
}

/// Shared parser for direct `account/rateLimits/read` responses and the
/// corresponding app-server notification. Unknown fields are ignored.
public enum CoveRateLimitsSnapshotParser {
    public static func parseResponse(
        _ data: Data,
        expectedID: String,
        capturedAt: Date
    ) throws -> CoveUsageSnapshot {
        let value: CoveJSONValue
        do {
            value = try JSONDecoder().decode(CoveJSONValue.self, from: data)
        } catch {
            throw CoveRateLimitsResponseError.invalidJSON
        }
        guard let response = value.objectValue,
              response["id"]?.scalarStringValue == expectedID else {
            throw CoveRateLimitsResponseError.unexpectedResponse
        }
        if let error = response["error"], error != .null {
            throw CoveRateLimitsResponseError.serverRejectedRequest
        }
        guard let result = response["result"] else {
            throw CoveRateLimitsResponseError.missingRateLimits
        }
        return try snapshot(fromResult: result, capturedAt: capturedAt)
    }

    public static func snapshot(
        fromResult value: CoveJSONValue,
        capturedAt: Date,
        forcePartial: Bool = false
    ) throws -> CoveUsageSnapshot {
        guard let result = value.objectValue,
              let rateLimits = result["rateLimits"]?.objectValue else {
            throw CoveRateLimitsResponseError.missingRateLimits
        }

        let primary = rateLimitWindow(rateLimits["primary"])
        let secondary = rateLimitWindow(rateLimits["secondary"])
        let resetCreditObject = result["rateLimitResetCredits"]?.objectValue
        let availableCount = resetCreditObject?["availableCount"]?.intValue
        let resetCredits: [CoveRateLimitResetCredit]? = {
            guard let creditsValue = resetCreditObject?["credits"] else {
                return nil
            }
            if creditsValue == .null {
                return nil
            }
            guard let rows = creditsValue.arrayValue else {
                return nil
            }
            return rows.compactMap(resetCredit)
        }()
        let credits = rateLimits["credits"]?.objectValue

        return CoveUsageSnapshot(
            primary: primary,
            secondary: secondary,
            resetCreditsAvailable: availableCount.map { max(0, $0) },
            resetCredits: resetCredits,
            creditBalance: credits?["balance"]?.scalarStringValue,
            capturedAt: capturedAt,
            isPartial: forcePartial
                || primary == nil
                || secondary == nil
                || availableCount == nil
                || resetCredits == nil
        )
    }

    private static func rateLimitWindow(_ value: CoveJSONValue?) -> CoveRateLimitWindow? {
        guard let object = value?.objectValue,
              let usedPercent = object["usedPercent"]?.intValue else {
            return nil
        }
        let resetsAt = object["resetsAt"]?.intValue.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return CoveRateLimitWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowDurationMinutes: object["windowDurationMins"]?.intValue
        )
    }

    private static func resetCredit(_ value: CoveJSONValue) -> CoveRateLimitResetCredit? {
        guard let object = value.objectValue else {
            return nil
        }
        let row = CoveRateLimitResetCredit(
            id: object["id"]?.stringValue,
            resetType: object["resetType"]?.stringValue,
            status: object["status"]?.stringValue,
            grantedAt: unixDate(object["grantedAt"]),
            expiresAt: unixDate(object["expiresAt"]),
            title: object["title"]?.stringValue,
            detail: object["description"]?.stringValue
        )
        guard row.id != nil
                || row.status != nil
                || row.expiresAt != nil
                || row.title != nil else {
            return nil
        }
        return row
    }

    private static func unixDate(_ value: CoveJSONValue?) -> Date? {
        value?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public enum CoveAccountTokenUsageResponseError: Error, Equatable, Sendable {
    case invalidJSON
    case unexpectedResponse
    case serverRejectedRequest
    case missingUsage
}

/// Parses the public `account/usage/read` response without consulting Codex UI
/// state or any private files. Unknown response fields are ignored.
public enum CoveAccountTokenUsageSnapshotParser {
    public static func parseResponse(
        _ data: Data,
        expectedID: String,
        capturedAt: Date
    ) throws -> CoveAccountTokenUsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CoveAccountTokenUsageResponseError.invalidJSON
        }
        guard response.id.scalarStringValue == expectedID else {
            throw CoveAccountTokenUsageResponseError.unexpectedResponse
        }
        if let error = response.error, error != .null {
            throw CoveAccountTokenUsageResponseError.serverRejectedRequest
        }
        guard let result = response.result else {
            throw CoveAccountTokenUsageResponseError.missingUsage
        }

        return CoveAccountTokenUsageSnapshot(
            summary: CoveAccountTokenUsageSummary(
                lifetimeTokens: result.summary.lifetimeTokens,
                peakDailyTokens: result.summary.peakDailyTokens,
                longestRunningTurnSeconds: result.summary.longestRunningTurnSec,
                currentStreakDays: result.summary.currentStreakDays,
                longestStreakDays: result.summary.longestStreakDays
            ),
            dailyUsageBuckets: result.dailyUsageBuckets?.compactMap { bucket in
                let startDate = bucket.startDate.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !startDate.isEmpty else { return nil }
                return CoveAccountTokenUsageDailyBucket(
                    startDate: startDate,
                    tokens: bucket.tokens
                )
            },
            capturedAt: capturedAt
        )
    }

    private struct Response: Decodable {
        var id: CoveJSONValue
        var result: Result?
        var error: CoveJSONValue?
    }

    private struct Result: Decodable {
        var summary: Summary
        var dailyUsageBuckets: [DailyBucket]?
    }

    private struct Summary: Decodable {
        var lifetimeTokens: Int64?
        var peakDailyTokens: Int64?
        var longestRunningTurnSec: Int64?
        var currentStreakDays: Int64?
        var longestStreakDays: Int64?
    }

    private struct DailyBucket: Decodable {
        var startDate: String
        var tokens: Int64
    }
}

public enum CoveUsageHydrationFailure: String, Error, Codable, Equatable, Sendable {
    case configurationUnavailable
    case executableUnavailable
    case launchFailed
    case timedOut
    case responseTooLarge
    case protocolUnavailable
}

public enum CoveUsageHydrationResult: Equatable, Sendable {
    case available(CoveUsageSnapshot)
    case unavailable(CoveUsageHydrationFailure)
}

public struct CoveAccountUsageConfiguration: Equatable, Sendable {
    public static let defaultRefreshInterval: TimeInterval = 300
    public static let defaultRequestTimeout: TimeInterval = 8
    public static let defaultMaximumLineBytes = 1_048_576

    public var realCodexURL: URL
    public var refreshInterval: TimeInterval
    public var requestTimeout: TimeInterval
    public var maximumLineBytes: Int
    public var clientVersion: String

    public init(
        realCodexURL: URL,
        refreshInterval: TimeInterval = defaultRefreshInterval,
        requestTimeout: TimeInterval = defaultRequestTimeout,
        maximumLineBytes: Int = defaultMaximumLineBytes,
        clientVersion: String = "0.5.1"
    ) {
        self.realCodexURL = realCodexURL
        self.refreshInterval = min(3_600, max(300, refreshInterval))
        self.requestTimeout = min(30, max(0.25, requestTimeout))
        self.maximumLineBytes = min(1_048_576, max(1_024, maximumLineBytes))
        self.clientVersion = clientVersion
    }

    public static func installed(
        configurationURL: URL = defaultInstalledConfigurationURL(),
        refreshInterval: TimeInterval = defaultRefreshInterval,
        requestTimeout: TimeInterval = defaultRequestTimeout,
        clientVersion: String = "0.5.1"
    ) throws -> Self {
        struct InstalledHelperConfiguration: Decodable {
            var realCodex: String?
            var maxFrameBytes: Int?
        }

        let data: Data
        let installed: InstalledHelperConfiguration
        do {
            data = try Data(contentsOf: configurationURL, options: [.mappedIfSafe])
            installed = try JSONDecoder().decode(InstalledHelperConfiguration.self, from: data)
        } catch {
            throw CoveUsageHydrationFailure.configurationUnavailable
        }
        guard let path = installed.realCodex,
              NSString(string: path).isAbsolutePath else {
            throw CoveUsageHydrationFailure.configurationUnavailable
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CoveUsageHydrationFailure.executableUnavailable
        }
        return Self(
            realCodexURL: url,
            refreshInterval: refreshInterval,
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

public struct CoveAccountUsageClient: Sendable {
    public let configuration: CoveAccountUsageConfiguration

    public init(configuration: CoveAccountUsageConfiguration) {
        self.configuration = configuration
    }

    public func fetch(capturedAt: Date = Date()) async -> CoveUsageHydrationResult {
        let configuration = configuration
        return await Task.detached(priority: .utility) {
            guard configuration.realCodexURL.isFileURL,
                  NSString(string: configuration.realCodexURL.path).isAbsolutePath else {
                return .unavailable(.configurationUnavailable)
            }
            guard FileManager.default.isExecutableFile(
                atPath: configuration.realCodexURL.path
            ) else {
                return .unavailable(.executableUnavailable)
            }

            do {
                let snapshot = try CoveAppServerUsageQuery.run(
                    configuration: configuration,
                    capturedAt: capturedAt
                )
                return .available(snapshot)
            } catch let failure as CoveUsageHydrationFailure {
                return .unavailable(failure)
            } catch {
                return .unavailable(.protocolUnavailable)
            }
        }.value
    }
}

/// Periodically refreshes account limits without retaining response data beyond
/// the latest in-memory snapshot owned by the caller.
@MainActor
public final class CoveAccountUsageHydrator {
    public typealias UpdateHandler = @MainActor (CoveUsageHydrationResult) -> Void

    private let client: CoveAccountUsageClient
    private var updateHandler: UpdateHandler?
    private var periodicTask: Task<Void, Never>?
    private var immediateTask: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshPending = false

    public init(configuration: CoveAccountUsageConfiguration) {
        self.client = CoveAccountUsageClient(configuration: configuration)
    }

    public convenience init(
        installedConfigurationURL: URL = CoveAccountUsageConfiguration
            .defaultInstalledConfigurationURL(),
        clientVersion: String = "0.5.1"
    ) throws {
        try self.init(
            configuration: CoveAccountUsageConfiguration.installed(
                configurationURL: installedConfigurationURL,
                clientVersion: clientVersion
            )
        )
    }

    public func start(onUpdate: @escaping UpdateHandler) {
        stop()
        updateHandler = onUpdate
        let refreshInterval = client.configuration.refreshInterval
        periodicTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.performRefresh()
                do {
                    try await Task.sleep(for: .seconds(refreshInterval))
                } catch {
                    return
                }
            }
        }
    }

    /// Use after wake/network recovery. Concurrent refreshes are coalesced.
    public func refreshNow() {
        guard updateHandler != nil else { return }
        immediateTask?.cancel()
        immediateTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    public func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        immediateTask?.cancel()
        immediateTask = nil
        updateHandler = nil
        refreshPending = false
    }

    private func performRefresh() async {
        guard !Task.isCancelled else { return }
        if isRefreshing {
            refreshPending = true
            return
        }
        isRefreshing = true

        let result = await client.fetch()
        isRefreshing = false
        guard !Task.isCancelled else {
            refreshPending = false
            return
        }
        updateHandler?(result)

        if refreshPending {
            refreshPending = false
            await performRefresh()
        }
    }
}

private enum CoveAppServerUsageQuery {
    private static let initializeID = "cove-usage-initialize"
    private static let rateLimitsID = "cove-usage-rate-limits"
    private static let accountUsageID = "cove-usage-account-token"
    private static let maximumMessagesPerRequest = 256

    static func run(
        configuration: CoveAccountUsageConfiguration,
        capturedAt: Date
    ) throws -> CoveUsageSnapshot {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = configuration.realCodexURL
        process.arguments = ["app-server", "--stdio"]
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
            throw CoveUsageHydrationFailure.launchFailed
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
            configuration.requestTimeout * 1_000_000_000
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : now + timeoutNanoseconds
        var reader = CoveBoundedLineReader(
            fileDescriptor: output.fileDescriptor,
            maximumLineBytes: configuration.maximumLineBytes
        )

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
            deadline: deadline
        )

        try writeJSON(
            ["method": "initialized", "params": [String: Any]()],
            to: input.fileDescriptor
        )
        try writeJSON(
            [
                "id": rateLimitsID,
                "method": "account/rateLimits/read",
                "params": NSNull(),
            ],
            to: input.fileDescriptor
        )
        let usageResponse = try response(
            withID: rateLimitsID,
            reader: &reader,
            deadline: deadline
        )
        var snapshot: CoveUsageSnapshot
        do {
            snapshot = try CoveRateLimitsSnapshotParser.parseResponse(
                usageResponse,
                expectedID: rateLimitsID,
                capturedAt: capturedAt
            )
        } catch {
            throw CoveUsageHydrationFailure.protocolUnavailable
        }

        // Profile usage is optional. A Codex version or account that does not
        // support it must not discard the already-hydrated rate-limit data.
        do {
            try writeJSON(
                [
                    "id": accountUsageID,
                    "method": "account/usage/read",
                ],
                to: input.fileDescriptor
            )
            let accountUsageResponse = try response(
                withID: accountUsageID,
                reader: &reader,
                deadline: deadline
            )
            snapshot.accountTokenUsage = try CoveAccountTokenUsageSnapshotParser
                .parseResponse(
                    accountUsageResponse,
                    expectedID: accountUsageID,
                    capturedAt: capturedAt
                )
            snapshot.accountTokenUsageAvailability = .available
        } catch {
            snapshot.accountTokenUsageAvailability = .unavailable
        }
        return snapshot
    }

    private static func response(
        withID expectedID: String,
        reader: inout CoveBoundedLineReader,
        deadline: UInt64
    ) throws -> Data {
        for _ in 0..<maximumMessagesPerRequest {
            let line = try reader.readLine(deadline: deadline)
            guard let value = try? JSONDecoder().decode(
                CoveJSONValue.self,
                from: line
            ), let object = value.objectValue else {
                continue
            }
            guard object["id"]?.scalarStringValue == expectedID else {
                continue
            }
            if let error = object["error"], error != .null {
                throw CoveUsageHydrationFailure.protocolUnavailable
            }
            return line
        }
        throw CoveUsageHydrationFailure.protocolUnavailable
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
            throw CoveUsageHydrationFailure.protocolUnavailable
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
                    throw CoveUsageHydrationFailure.protocolUnavailable
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

private struct CoveBoundedLineReader {
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
                    throw CoveUsageHydrationFailure.responseTooLarge
                }
                var line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                return Data(line)
            }
            guard buffered.count <= maximumLineBytes else {
                throw CoveUsageHydrationFailure.responseTooLarge
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw CoveUsageHydrationFailure.timedOut
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
                throw CoveUsageHydrationFailure.timedOut
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw CoveUsageHydrationFailure.protocolUnavailable
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
                throw CoveUsageHydrationFailure.protocolUnavailable
            } else if errno != EINTR {
                throw CoveUsageHydrationFailure.protocolUnavailable
            }
        }
    }
}
