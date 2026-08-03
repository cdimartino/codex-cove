import Darwin
import Foundation
import SQLite3

public protocol CoveStateStorage: Sendable {
    func load() throws -> CoveState?
    func save(_ state: CoveState) throws
}

public enum CovePersistenceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSettingsSchema(found: Int, supported: Int)
    case unsupportedDatabaseSchema(found: Int, supported: Int)
    case invalidMetadata(field: String)
    case unsafeFilesystemEntry(kind: String)
    case sqlite(operation: String, code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSettingsSchema(found, supported):
            return "Settings schema \(found) is newer than supported schema \(supported)."
        case let .unsupportedDatabaseSchema(found, supported):
            return "Session database schema \(found) is newer than supported schema \(supported)."
        case let .invalidMetadata(field):
            return "Invalid session metadata field: \(field)."
        case let .unsafeFilesystemEntry(kind):
            return "Refusing to use an unsafe \(kind) filesystem entry."
        case let .sqlite(operation, code, message):
            return "SQLite \(operation) failed (\(code)): \(message)"
        }
    }
}

/// Versioned settings envelope. Session identifiers and activity metadata never
/// belong in this JSON file; they are stored by `CoveSQLiteSessionMetadataStorage`.
public struct CovePersistedState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var settings: CoveSettings

    public init(
        schemaVersion: Int = CovePersistedState.currentSchemaVersion,
        settings: CoveSettings
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
    }
}

private struct CoveLegacyPersistedState: Decodable {
    var settings: CoveSettings
}

/// JSON-backed settings storage retained under the historical type name so
/// existing callers can migrate without an API break.
public struct CoveFileStateStorage: CoveStateStorage {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> CoveState? {
        let fileManager = FileManager.default
        let sourceURL: URL
        if fileManager.fileExists(atPath: url.path) {
            sourceURL = url
        } else {
            let legacyURL = url.deletingLastPathComponent().appendingPathComponent("state.json")
            guard legacyURL != url, fileManager.fileExists(atPath: legacyURL.path) else {
                return nil
            }
            sourceURL = legacyURL
        }

        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        let persisted: CovePersistedState

        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["schemaVersion"] != nil {
            persisted = try decoder.decode(CovePersistedState.self, from: data)
            guard persisted.schemaVersion <= CovePersistedState.currentSchemaVersion else {
                throw CovePersistenceError.unsupportedSettingsSchema(
                    found: persisted.schemaVersion,
                    supported: CovePersistedState.currentSchemaVersion
                )
            }
            guard persisted.schemaVersion > 0 else {
                throw CovePersistenceError.invalidMetadata(field: "settings.schemaVersion")
            }
        } else {
            // The first prototype wrote settings alongside transient UI state
            // without a schema version. Decode only its settings and discard
            // every other key.
            let legacy = try decoder.decode(CoveLegacyPersistedState.self, from: data)
            persisted = CovePersistedState(settings: legacy.settings)
        }

        let theme = CoveThemeCatalog.palette(
            for: persisted.settings.themeFamily,
            palette: persisted.settings.palette
        )
        return CoveState(settings: persisted.settings, theme: theme)
    }

    public func save(_ state: CoveState) throws {
        let persisted = CovePersistedState(settings: state.settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)
        let directory = url.deletingLastPathComponent()
        try CoveSecureFilesystem.prepareDirectory(directory)
        try data.write(to: url, options: [.atomic])
        try CoveSecureFilesystem.enforcePermissions(0o600, at: url, kind: "settings file")
    }
}

public struct CoveTerminalLocationMetadata: Codable, Equatable, Sendable {
    /// Adapter family such as `terminal`, `tmux`, `vscode`, or `cursor`.
    /// This is an adapter identifier, not a program path.
    public var adapter: String

    /// Opaque adapter-owned pane/task identifier. Filesystem paths are rejected
    /// when the record is written.
    public var locationIdentifier: String

    /// Public bundle identifier for the terminal/editor host. This is used only
    /// to reactivate the already-running application.
    public var hostBundleIdentifier: String?

    /// Opaque suffix of Cove's conventional editor-focus socket filename. The
    /// absolute socket path is reconstructed at runtime and is never persisted.
    public var focusSocketIdentifier: String?

    /// Adapter-specific identifiers retained independently so compound
    /// locations such as a tmux pane inside an editor terminal remain exact.
    public var tmuxPaneIdentifier: String?
    public var weztermPaneIdentifier: String?
    public var ttyIdentifier: String?
    public var oscMarkerIdentifier: String?
    public var editorTerminalIdentifier: String?

    public init(
        adapter: String,
        locationIdentifier: String,
        hostBundleIdentifier: String? = nil,
        focusSocketIdentifier: String? = nil,
        tmuxPaneIdentifier: String? = nil,
        weztermPaneIdentifier: String? = nil,
        ttyIdentifier: String? = nil,
        oscMarkerIdentifier: String? = nil,
        editorTerminalIdentifier: String? = nil
    ) {
        self.adapter = adapter
        self.locationIdentifier = locationIdentifier
        self.hostBundleIdentifier = hostBundleIdentifier
        self.focusSocketIdentifier = focusSocketIdentifier
        self.tmuxPaneIdentifier = tmuxPaneIdentifier
        self.weztermPaneIdentifier = weztermPaneIdentifier
        self.ttyIdentifier = ttyIdentifier
        self.oscMarkerIdentifier = oscMarkerIdentifier
        self.editorTerminalIdentifier = editorTerminalIdentifier
    }
}

private struct CoveStoredTerminalLocation: Codable {
    static let prefix = "cove@1:"

    var locationIdentifier: String
    var hostBundleIdentifier: String?
    var focusSocketIdentifier: String?
    var tmuxPaneIdentifier: String?
    var weztermPaneIdentifier: String?
    var ttyIdentifier: String?
    var oscMarkerIdentifier: String?
    var editorTerminalIdentifier: String?
}

/// The complete allowlist of session data that Cove may persist.
///
/// There are deliberately no prompt, response, command, diff, title, detail,
/// project, working-directory, or generic payload properties on this type.
public struct CoveSessionMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionId: String
    public var launchId: String?
    public var turnId: String?
    public var source: CoveWireSource
    public var status: CoveSessionStatus
    public var unread: Bool
    public var reminderAt: Date?
    public var terminalLocation: CoveTerminalLocationMetadata?
    public var hostId: String?
    public var parentSessionId: String?
    public var updatedAt: Date
    public var startedAt: Date

    public init(
        schemaVersion: Int = CoveSessionMetadata.currentSchemaVersion,
        sessionId: String,
        launchId: String? = nil,
        turnId: String? = nil,
        source: CoveWireSource,
        status: CoveSessionStatus,
        unread: Bool = false,
        reminderAt: Date? = nil,
        terminalLocation: CoveTerminalLocationMetadata? = nil,
        hostId: String? = nil,
        parentSessionId: String? = nil,
        updatedAt: Date,
        startedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.launchId = launchId
        self.turnId = turnId
        self.source = source
        self.status = status
        self.unread = unread
        self.reminderAt = reminderAt
        self.terminalLocation = terminalLocation
        self.hostId = hostId
        self.parentSessionId = parentSessionId
        self.updatedAt = updatedAt
        self.startedAt = startedAt
    }
}

/// Fixed-size, content-free diagnostic summary. It intentionally contains no
/// session, launch, host, parent, terminal, or filesystem identifiers.
public struct CoveSessionMetadataDiagnostics: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var databaseBytes: Int64
    public var directoryPermissions: Int
    public var databasePermissions: Int
    public var sessionCount: Int
    public var unreadCount: Int
    public var scheduledReminderCount: Int
    public var dueReminderCount: Int
    public var oldestStartedAt: Date?
    public var newestUpdatedAt: Date?
    public var statusCounts: [String: Int]

    public init(
        schemaVersion: Int,
        databaseBytes: Int64,
        directoryPermissions: Int,
        databasePermissions: Int,
        sessionCount: Int,
        unreadCount: Int,
        scheduledReminderCount: Int,
        dueReminderCount: Int,
        oldestStartedAt: Date?,
        newestUpdatedAt: Date?,
        statusCounts: [String: Int]
    ) {
        self.schemaVersion = schemaVersion
        self.databaseBytes = databaseBytes
        self.directoryPermissions = directoryPermissions
        self.databasePermissions = databasePermissions
        self.sessionCount = sessionCount
        self.unreadCount = unreadCount
        self.scheduledReminderCount = scheduledReminderCount
        self.dueReminderCount = dueReminderCount
        self.oldestStartedAt = oldestStartedAt
        self.newestUpdatedAt = newestUpdatedAt
        self.statusCounts = statusCounts
    }
}

public protocol CoveSessionMetadataStorage: Sendable {
    func upsert(_ metadata: CoveSessionMetadata) throws
    func metadata(sessionId: String) throws -> CoveSessionMetadata?
    func recent(limit: Int) throws -> [CoveSessionMetadata]
    func dueReminders(now: Date, limit: Int) throws -> [CoveSessionMetadata]
    func remove(sessionId: String) throws
    @discardableResult
    func prune(updatedBefore: Date, limit: Int) throws -> Int
    func diagnostics(now: Date) throws -> CoveSessionMetadataDiagnostics
}

public extension CoveSessionMetadataStorage {
    func diagnostics() throws -> CoveSessionMetadataDiagnostics {
        try diagnostics(now: Date())
    }
}

public struct CoveSQLiteSessionMetadataStorage: CoveSessionMetadataStorage {
    public static let currentDatabaseSchemaVersion = 1
    public static let defaultMaximumQueryRows = 200
    public static let hardMaximumQueryRows = 500

    public let url: URL
    public let maximumQueryRows: Int

    public init(
        url: URL = CoveStateFilesystem.sessionDatabaseURL(),
        maximumQueryRows: Int = CoveSQLiteSessionMetadataStorage.defaultMaximumQueryRows
    ) {
        self.url = url
        self.maximumQueryRows = min(
            max(1, maximumQueryRows),
            CoveSQLiteSessionMetadataStorage.hardMaximumQueryRows
        )
    }

    /// Creates the database and applies pending migrations without reading or
    /// writing a session row.
    public func initialize() throws {
        try withDatabase { _ in () }
    }

    public func upsert(_ metadata: CoveSessionMetadata) throws {
        try upsert(metadata, replacingSessionId: nil)
    }

    /// Atomically attributes a pending launch record to its real Codex session.
    /// The replacement row is committed before the pending primary key is
    /// removed, so an interruption can never leave Cove with neither record.
    public func upsert(
        _ metadata: CoveSessionMetadata,
        replacingSessionId: String?
    ) throws {
        try validate(metadata)
        if let replacingSessionId {
            try validateOpaqueIdentifier(
                replacingSessionId,
                field: "replacingSessionId",
                maximumBytes: 512
            )
        }
        try withDatabase { connection in
            let shouldReplace = replacingSessionId != nil
                && replacingSessionId != metadata.sessionId
            if shouldReplace {
                try connection.execute(
                    "BEGIN IMMEDIATE",
                    operation: "begin session attribution"
                )
            }
            do {
                var attributedMetadata = metadata
                if shouldReplace,
                   let replacingSessionId,
                   let pending = try self.metadata(
                       sessionId: replacingSessionId,
                       in: connection
                   ) {
                    attributedMetadata.launchId = attributedMetadata.launchId
                        ?? pending.launchId
                    attributedMetadata.turnId = attributedMetadata.turnId
                        ?? pending.turnId
                    attributedMetadata.unread = attributedMetadata.unread
                        || pending.unread
                    attributedMetadata.reminderAt = attributedMetadata.reminderAt
                        ?? pending.reminderAt
                    attributedMetadata.terminalLocation =
                        attributedMetadata.terminalLocation
                        ?? pending.terminalLocation
                    attributedMetadata.hostId = attributedMetadata.hostId
                        ?? pending.hostId
                    attributedMetadata.parentSessionId =
                        attributedMetadata.parentSessionId
                        ?? pending.parentSessionId
                    attributedMetadata.startedAt = min(
                        attributedMetadata.startedAt,
                        pending.startedAt
                    )
                    attributedMetadata.updatedAt = max(
                        attributedMetadata.updatedAt,
                        pending.updatedAt
                    )
                    try validate(attributedMetadata)
                }
                try upsert(attributedMetadata, in: connection)
                if shouldReplace, let replacingSessionId {
                    let statement = try connection.prepare(
                        "DELETE FROM session_metadata WHERE session_id = ?",
                        operation: "prepare pending attribution removal"
                    )
                    defer { sqlite3_finalize(statement) }
                    try connection.bind(
                        replacingSessionId,
                        to: 1,
                        in: statement,
                        operation: "bind pending attribution removal"
                    )
                    try connection.stepDone(
                        statement,
                        operation: "remove attributed pending session"
                    )
                }
                if shouldReplace {
                    try connection.execute(
                        "COMMIT",
                        operation: "commit session attribution"
                    )
                }
            } catch {
                if shouldReplace {
                    try? connection.execute(
                        "ROLLBACK",
                        operation: "rollback session attribution"
                    )
                }
                throw error
            }
        }
    }

    public func metadata(sessionId: String) throws -> CoveSessionMetadata? {
        try validateOpaqueIdentifier(sessionId, field: "sessionId", maximumBytes: 512)
        return try withDatabase { connection in
            let statement = try connection.prepare(
                "\(Self.selectColumnsSQL) WHERE session_id = ? LIMIT 1",
                operation: "prepare metadata lookup"
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(sessionId, to: 1, in: statement, operation: "bind metadata lookup")
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw connection.error(operation: "metadata lookup", code: result)
            }
            return try decodeMetadata(from: statement)
        }
    }

    public func recent(limit: Int = CoveSQLiteSessionMetadataStorage.defaultMaximumQueryRows) throws -> [CoveSessionMetadata] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, maximumQueryRows)
        return try withDatabase { connection in
            let statement = try connection.prepare(
                "\(Self.selectColumnsSQL) ORDER BY updated_at_ms DESC, session_id ASC LIMIT ?",
                operation: "prepare recent metadata"
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(Int64(boundedLimit), to: 1, in: statement, operation: "bind recent metadata")

            var records: [CoveSessionMetadata] = []
            records.reserveCapacity(boundedLimit)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw connection.error(operation: "read recent metadata", code: result)
                }
                records.append(try decodeMetadata(from: statement))
            }
            return records
        }
    }

    public func dueReminders(
        now: Date = Date(),
        limit: Int = CoveSQLiteSessionMetadataStorage.defaultMaximumQueryRows
    ) throws -> [CoveSessionMetadata] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, maximumQueryRows)
        let dueAt = try milliseconds(now)
        return try withDatabase { connection in
            let statement = try connection.prepare(
                """
                \(Self.selectColumnsSQL)
                WHERE reminder_at_ms IS NOT NULL
                  AND reminder_at_ms <= ?
                ORDER BY reminder_at_ms ASC, session_id ASC
                LIMIT ?
                """,
                operation: "prepare due reminders"
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(
                dueAt,
                to: 1,
                in: statement,
                operation: "bind due reminder time"
            )
            try connection.bind(
                Int64(boundedLimit),
                to: 2,
                in: statement,
                operation: "bind due reminder limit"
            )

            var records: [CoveSessionMetadata] = []
            records.reserveCapacity(boundedLimit)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw connection.error(
                        operation: "read due reminders",
                        code: result
                    )
                }
                records.append(try decodeMetadata(from: statement))
            }
            return records
        }
    }

    public func remove(sessionId: String) throws {
        try validateOpaqueIdentifier(sessionId, field: "sessionId", maximumBytes: 512)
        try withDatabase { connection in
            let statement = try connection.prepare(
                "DELETE FROM session_metadata WHERE session_id = ?",
                operation: "prepare remove"
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(sessionId, to: 1, in: statement, operation: "bind remove")
            try connection.stepDone(statement, operation: "remove")
        }
    }

    @discardableResult
    public func prune(updatedBefore: Date, limit: Int = CoveSQLiteSessionMetadataStorage.defaultMaximumQueryRows) throws -> Int {
        guard limit > 0 else { return 0 }
        let boundedLimit = min(limit, maximumQueryRows)
        let cutoff = try milliseconds(updatedBefore)
        return try withDatabase { connection in
            let statement = try connection.prepare(
                """
                DELETE FROM session_metadata
                WHERE session_id IN (
                    SELECT session_id
                    FROM session_metadata
                    WHERE updated_at_ms < ?
                    ORDER BY updated_at_ms ASC
                    LIMIT ?
                )
                """,
                operation: "prepare prune"
            )
            defer { sqlite3_finalize(statement) }
            try connection.bind(cutoff, to: 1, in: statement, operation: "bind prune")
            try connection.bind(Int64(boundedLimit), to: 2, in: statement, operation: "bind prune")
            try connection.stepDone(statement, operation: "prune")
            return Int(sqlite3_changes(connection.handle))
        }
    }

    public func diagnostics(now: Date) throws -> CoveSessionMetadataDiagnostics {
        let nowMilliseconds = try milliseconds(now)
        return try withDatabase { connection in
            let aggregate = try connection.prepare(
                """
                SELECT
                    COUNT(*),
                    COALESCE(SUM(unread), 0),
                    COALESCE(SUM(reminder_at_ms IS NOT NULL), 0),
                    COALESCE(SUM(reminder_at_ms IS NOT NULL AND reminder_at_ms <= ?), 0),
                    MIN(started_at_ms),
                    MAX(updated_at_ms)
                FROM session_metadata
                """,
                operation: "prepare diagnostics"
            )
            defer { sqlite3_finalize(aggregate) }
            try connection.bind(nowMilliseconds, to: 1, in: aggregate, operation: "bind diagnostics")
            let aggregateResult = sqlite3_step(aggregate)
            guard aggregateResult == SQLITE_ROW else {
                throw connection.error(operation: "read diagnostics", code: aggregateResult)
            }

            let sessionCount = Int(sqlite3_column_int64(aggregate, 0))
            let unreadCount = Int(sqlite3_column_int64(aggregate, 1))
            let scheduledReminderCount = Int(sqlite3_column_int64(aggregate, 2))
            let dueReminderCount = Int(sqlite3_column_int64(aggregate, 3))
            let oldestStartedAt = Self.dateColumn(aggregate, index: 4)
            let newestUpdatedAt = Self.dateColumn(aggregate, index: 5)

            let statuses = try connection.prepare(
                """
                SELECT status, COUNT(*)
                FROM session_metadata
                GROUP BY status
                ORDER BY status
                LIMIT 16
                """,
                operation: "prepare diagnostic status counts"
            )
            defer { sqlite3_finalize(statuses) }
            var statusCounts: [String: Int] = [:]
            while true {
                let result = sqlite3_step(statuses)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw connection.error(operation: "read diagnostic status counts", code: result)
                }
                guard let rawStatus = connection.textColumn(statuses, index: 0),
                      CoveSessionStatus(rawValue: rawStatus) != nil else {
                    continue
                }
                statusCounts[rawStatus] = Int(sqlite3_column_int64(statuses, 1))
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let databaseBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let databasePermissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: url.deletingLastPathComponent().path
            )
            let directoryPermissions = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0

            return CoveSessionMetadataDiagnostics(
                schemaVersion: Self.currentDatabaseSchemaVersion,
                databaseBytes: databaseBytes,
                directoryPermissions: directoryPermissions,
                databasePermissions: databasePermissions,
                sessionCount: sessionCount,
                unreadCount: unreadCount,
                scheduledReminderCount: scheduledReminderCount,
                dueReminderCount: dueReminderCount,
                oldestStartedAt: oldestStartedAt,
                newestUpdatedAt: newestUpdatedAt,
                statusCounts: statusCounts
            )
        }
    }

    private static let selectColumnsSQL = """
        SELECT
            record_schema_version,
            session_id,
            launch_id,
            turn_id,
            source,
            status,
            unread,
            reminder_at_ms,
            terminal_adapter,
            terminal_location_id,
            host_id,
            parent_session_id,
            updated_at_ms,
            started_at_ms
        FROM session_metadata
        """

    private func upsert(
        _ metadata: CoveSessionMetadata,
        in connection: CoveSQLiteConnection
    ) throws {
        let sql = """
            INSERT INTO session_metadata (
                record_schema_version,
                session_id,
                launch_id,
                turn_id,
                source,
                status,
                unread,
                reminder_at_ms,
                terminal_adapter,
                terminal_location_id,
                host_id,
                parent_session_id,
                updated_at_ms,
                started_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                record_schema_version = excluded.record_schema_version,
                launch_id = excluded.launch_id,
                turn_id = excluded.turn_id,
                source = excluded.source,
                status = excluded.status,
                unread = excluded.unread,
                reminder_at_ms = excluded.reminder_at_ms,
                terminal_adapter = excluded.terminal_adapter,
                terminal_location_id = excluded.terminal_location_id,
                host_id = excluded.host_id,
                parent_session_id = excluded.parent_session_id,
                updated_at_ms = excluded.updated_at_ms,
                started_at_ms = excluded.started_at_ms
            """
        let statement = try connection.prepare(sql, operation: "prepare upsert")
        defer { sqlite3_finalize(statement) }

        try connection.bind(Int64(metadata.schemaVersion), to: 1, in: statement, operation: "bind upsert")
        try connection.bind(metadata.sessionId, to: 2, in: statement, operation: "bind upsert")
        try connection.bind(metadata.launchId, to: 3, in: statement, operation: "bind upsert")
        try connection.bind(metadata.turnId, to: 4, in: statement, operation: "bind upsert")
        try connection.bind(metadata.source.rawValue, to: 5, in: statement, operation: "bind upsert")
        try connection.bind(metadata.status.rawValue, to: 6, in: statement, operation: "bind upsert")
        try connection.bind(metadata.unread ? 1 : 0, to: 7, in: statement, operation: "bind upsert")
        try connection.bind(try milliseconds(metadata.reminderAt), to: 8, in: statement, operation: "bind upsert")
        try connection.bind(metadata.terminalLocation?.adapter, to: 9, in: statement, operation: "bind upsert")
        try connection.bind(
            try storedLocationIdentifier(metadata.terminalLocation),
            to: 10,
            in: statement,
            operation: "bind upsert"
        )
        try connection.bind(metadata.hostId, to: 11, in: statement, operation: "bind upsert")
        try connection.bind(metadata.parentSessionId, to: 12, in: statement, operation: "bind upsert")
        try connection.bind(try milliseconds(metadata.updatedAt), to: 13, in: statement, operation: "bind upsert")
        try connection.bind(try milliseconds(metadata.startedAt), to: 14, in: statement, operation: "bind upsert")
        try connection.stepDone(statement, operation: "upsert")
    }

    private func metadata(
        sessionId: String,
        in connection: CoveSQLiteConnection
    ) throws -> CoveSessionMetadata? {
        let statement = try connection.prepare(
            "\(Self.selectColumnsSQL) WHERE session_id = ? LIMIT 1",
            operation: "prepare transactional metadata lookup"
        )
        defer { sqlite3_finalize(statement) }
        try connection.bind(
            sessionId,
            to: 1,
            in: statement,
            operation: "bind transactional metadata lookup"
        )
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw connection.error(
                operation: "transactional metadata lookup",
                code: result
            )
        }
        return try decodeMetadata(from: statement)
    }

    private func withDatabase<Result>(
        _ body: (CoveSQLiteConnection) throws -> Result
    ) throws -> Result {
        let directory = url.deletingLastPathComponent()
        try CoveSecureFilesystem.prepareDirectory(directory)
        try CoveSecureFilesystem.rejectSymbolicLinkIfPresent(
            at: url,
            kind: "session database"
        )
        let resolvedDatabaseURL = try CoveSecureFilesystem.canonicalDirectory(directory)
            .appendingPathComponent(url.lastPathComponent)
        let connection = try CoveSQLiteConnection(url: resolvedDatabaseURL)
        try CoveSecureFilesystem.enforcePermissions(0o600, at: url, kind: "session database")
        try connection.configure()
        try migrate(connection)
        let result = try body(connection)
        try CoveSecureFilesystem.enforcePermissions(0o600, at: url, kind: "session database")
        return result
    }

    private func migrate(_ connection: CoveSQLiteConnection) throws {
        var version = try connection.scalarInt("PRAGMA user_version", operation: "read schema version")
        guard version <= Self.currentDatabaseSchemaVersion else {
            throw CovePersistenceError.unsupportedDatabaseSchema(
                found: version,
                supported: Self.currentDatabaseSchemaVersion
            )
        }

        while version < Self.currentDatabaseSchemaVersion {
            let nextVersion = version + 1
            try connection.execute("BEGIN IMMEDIATE", operation: "begin migration")
            do {
                switch nextVersion {
                case 1:
                    try connection.execute(
                        """
                        CREATE TABLE IF NOT EXISTS session_metadata (
                            record_schema_version INTEGER NOT NULL DEFAULT 1
                                CHECK (record_schema_version > 0),
                            session_id TEXT PRIMARY KEY NOT NULL,
                            launch_id TEXT,
                            turn_id TEXT,
                            source TEXT NOT NULL,
                            status TEXT NOT NULL,
                            unread INTEGER NOT NULL CHECK (unread IN (0, 1)),
                            reminder_at_ms INTEGER,
                            terminal_adapter TEXT,
                            terminal_location_id TEXT,
                            host_id TEXT,
                            parent_session_id TEXT,
                            updated_at_ms INTEGER NOT NULL,
                            started_at_ms INTEGER NOT NULL,
                            CHECK (
                                (terminal_adapter IS NULL AND terminal_location_id IS NULL)
                                OR
                                (terminal_adapter IS NOT NULL AND terminal_location_id IS NOT NULL)
                            )
                        ) WITHOUT ROWID
                        """,
                        operation: "create session metadata schema"
                    )
                    try connection.execute(
                        """
                        CREATE INDEX IF NOT EXISTS session_metadata_updated_at
                        ON session_metadata(updated_at_ms DESC)
                        """,
                        operation: "create updated index"
                    )
                    try connection.execute(
                        """
                        CREATE INDEX IF NOT EXISTS session_metadata_reminder
                        ON session_metadata(reminder_at_ms)
                        WHERE reminder_at_ms IS NOT NULL
                        """,
                        operation: "create reminder index"
                    )
                default:
                    throw CovePersistenceError.unsupportedDatabaseSchema(
                        found: nextVersion,
                        supported: Self.currentDatabaseSchemaVersion
                    )
                }
                try connection.execute(
                    "PRAGMA user_version = \(nextVersion)",
                    operation: "record schema version"
                )
                try connection.execute("COMMIT", operation: "commit migration")
                version = nextVersion
            } catch {
                try? connection.execute("ROLLBACK", operation: "rollback migration")
                throw error
            }
        }

        try validateSchema(connection)
    }

    private func validateSchema(_ connection: CoveSQLiteConnection) throws {
        let statement = try connection.prepare(
            "PRAGMA table_info(session_metadata)",
            operation: "prepare schema validation"
        )
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw connection.error(operation: "validate schema", code: result)
            }
            if let name = connection.textColumn(statement, index: 1) {
                columns.insert(name)
            }
        }
        let required: Set<String> = [
            "record_schema_version",
            "session_id",
            "launch_id",
            "turn_id",
            "source",
            "status",
            "unread",
            "reminder_at_ms",
            "terminal_adapter",
            "terminal_location_id",
            "host_id",
            "parent_session_id",
            "updated_at_ms",
            "started_at_ms",
        ]
        guard required.isSubset(of: columns) else {
            throw CovePersistenceError.sqlite(
                operation: "validate schema",
                code: SQLITE_SCHEMA,
                message: "required metadata columns are missing"
            )
        }
    }

    private func validate(_ metadata: CoveSessionMetadata) throws {
        guard metadata.schemaVersion == CoveSessionMetadata.currentSchemaVersion else {
            throw CovePersistenceError.invalidMetadata(field: "schemaVersion")
        }
        try validateOpaqueIdentifier(metadata.sessionId, field: "sessionId", maximumBytes: 512)
        try validateOptionalOpaqueIdentifier(metadata.launchId, field: "launchId", maximumBytes: 512)
        try validateOptionalOpaqueIdentifier(metadata.turnId, field: "turnId", maximumBytes: 512)
        try validateOptionalOpaqueIdentifier(metadata.hostId, field: "hostId", maximumBytes: 512)
        try validateOptionalOpaqueIdentifier(
            metadata.parentSessionId,
            field: "parentSessionId",
            maximumBytes: 512
        )
        if let terminalLocation = metadata.terminalLocation {
            try validateOpaqueIdentifier(
                terminalLocation.adapter,
                field: "terminalLocation.adapter",
                maximumBytes: 64
            )
            try validateOpaqueIdentifier(
                terminalLocation.locationIdentifier,
                field: "terminalLocation.locationIdentifier",
                maximumBytes: 512
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.hostBundleIdentifier,
                field: "terminalLocation.hostBundleIdentifier",
                maximumBytes: 256
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.focusSocketIdentifier,
                field: "terminalLocation.focusSocketIdentifier",
                maximumBytes: 128
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.tmuxPaneIdentifier,
                field: "terminalLocation.tmuxPaneIdentifier",
                maximumBytes: 128
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.weztermPaneIdentifier,
                field: "terminalLocation.weztermPaneIdentifier",
                maximumBytes: 128
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.ttyIdentifier,
                field: "terminalLocation.ttyIdentifier",
                maximumBytes: 128
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.oscMarkerIdentifier,
                field: "terminalLocation.oscMarkerIdentifier",
                maximumBytes: 256
            )
            try validateOptionalOpaqueIdentifier(
                terminalLocation.editorTerminalIdentifier,
                field: "terminalLocation.editorTerminalIdentifier",
                maximumBytes: 256
            )
            _ = try storedLocationIdentifier(terminalLocation)
        }
        _ = try milliseconds(metadata.startedAt)
        _ = try milliseconds(metadata.updatedAt)
        _ = try milliseconds(metadata.reminderAt)
        guard metadata.updatedAt >= metadata.startedAt else {
            throw CovePersistenceError.invalidMetadata(field: "updatedAt")
        }
    }

    private func validateOptionalOpaqueIdentifier(
        _ value: String?,
        field: String,
        maximumBytes: Int
    ) throws {
        guard let value else { return }
        try validateOpaqueIdentifier(value, field: field, maximumBytes: maximumBytes)
    }

    private func validateOpaqueIdentifier(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw CovePersistenceError.invalidMetadata(field: field)
        }
        let isAllowed = value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return true
            case 37, 43, 45, 46, 58, 64, 95:
                return true
            default:
                return false
            }
        }
        guard isAllowed else {
            throw CovePersistenceError.invalidMetadata(field: field)
        }
    }

    private func decodeMetadata(from statement: OpaquePointer) throws -> CoveSessionMetadata {
        guard
            let sessionId = CoveSQLiteConnection.textColumn(statement, index: 1),
            let sourceRaw = CoveSQLiteConnection.textColumn(statement, index: 4),
            let source = CoveWireSource(rawValue: sourceRaw),
            let statusRaw = CoveSQLiteConnection.textColumn(statement, index: 5),
            let status = CoveSessionStatus(rawValue: statusRaw)
        else {
            throw CovePersistenceError.sqlite(
                operation: "decode metadata",
                code: SQLITE_CORRUPT,
                message: "invalid typed metadata"
            )
        }

        let terminalAdapter = CoveSQLiteConnection.textColumn(statement, index: 8)
        let terminalLocationId = CoveSQLiteConnection.textColumn(statement, index: 9)
        let terminalLocation: CoveTerminalLocationMetadata?
        switch (terminalAdapter, terminalLocationId) {
        case let (.some(adapter), .some(locationIdentifier)):
            terminalLocation = try decodedTerminalLocation(
                adapter: adapter,
                storedIdentifier: locationIdentifier
            )
        case (nil, nil):
            terminalLocation = nil
        default:
            throw CovePersistenceError.sqlite(
                operation: "decode metadata",
                code: SQLITE_CORRUPT,
                message: "incomplete terminal location metadata"
            )
        }

        let record = CoveSessionMetadata(
            schemaVersion: Int(sqlite3_column_int64(statement, 0)),
            sessionId: sessionId,
            launchId: CoveSQLiteConnection.textColumn(statement, index: 2),
            turnId: CoveSQLiteConnection.textColumn(statement, index: 3),
            source: source,
            status: status,
            unread: sqlite3_column_int64(statement, 6) == 1,
            reminderAt: Self.dateColumn(statement, index: 7),
            terminalLocation: terminalLocation,
            hostId: CoveSQLiteConnection.textColumn(statement, index: 10),
            parentSessionId: CoveSQLiteConnection.textColumn(statement, index: 11),
            updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 12)) / 1_000),
            startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 13)) / 1_000)
        )
        try validate(record)
        return record
    }

    private func storedLocationIdentifier(
        _ location: CoveTerminalLocationMetadata?
    ) throws -> String? {
        guard let location else { return nil }
        let hasExtendedIdentity = location.hostBundleIdentifier != nil
            || location.focusSocketIdentifier != nil
            || location.tmuxPaneIdentifier != nil
            || location.weztermPaneIdentifier != nil
            || location.ttyIdentifier != nil
            || location.oscMarkerIdentifier != nil
            || location.editorTerminalIdentifier != nil
        guard hasExtendedIdentity else {
            return location.locationIdentifier
        }

        let stored = CoveStoredTerminalLocation(
            locationIdentifier: location.locationIdentifier,
            hostBundleIdentifier: location.hostBundleIdentifier,
            focusSocketIdentifier: location.focusSocketIdentifier,
            tmuxPaneIdentifier: location.tmuxPaneIdentifier,
            weztermPaneIdentifier: location.weztermPaneIdentifier,
            ttyIdentifier: location.ttyIdentifier,
            oscMarkerIdentifier: location.oscMarkerIdentifier,
            editorTerminalIdentifier: location.editorTerminalIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let result = CoveStoredTerminalLocation.prefix + encoded
        guard result.utf8.count <= 2_048 else {
            throw CovePersistenceError.invalidMetadata(
                field: "terminalLocation"
            )
        }
        return result
    }

    private func decodedTerminalLocation(
        adapter: String,
        storedIdentifier: String
    ) throws -> CoveTerminalLocationMetadata {
        guard storedIdentifier.hasPrefix(CoveStoredTerminalLocation.prefix) else {
            return CoveTerminalLocationMetadata(
                adapter: adapter,
                locationIdentifier: storedIdentifier
            )
        }
        var encoded = String(
            storedIdentifier.dropFirst(CoveStoredTerminalLocation.prefix.count)
        )
        encoded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: encoded),
              let stored = try? JSONDecoder().decode(
                  CoveStoredTerminalLocation.self,
                  from: data
              ) else {
            throw CovePersistenceError.sqlite(
                operation: "decode metadata",
                code: SQLITE_CORRUPT,
                message: "invalid terminal location identity"
            )
        }
        return CoveTerminalLocationMetadata(
            adapter: adapter,
            locationIdentifier: stored.locationIdentifier,
            hostBundleIdentifier: stored.hostBundleIdentifier,
            focusSocketIdentifier: stored.focusSocketIdentifier,
            tmuxPaneIdentifier: stored.tmuxPaneIdentifier,
            weztermPaneIdentifier: stored.weztermPaneIdentifier,
            ttyIdentifier: stored.ttyIdentifier,
            oscMarkerIdentifier: stored.oscMarkerIdentifier,
            editorTerminalIdentifier: stored.editorTerminalIdentifier
        )
    }

    private func milliseconds(_ date: Date?) throws -> Int64? {
        guard let date else { return nil }
        return try milliseconds(date)
    }

    private func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else {
            throw CovePersistenceError.invalidMetadata(field: "timestamp")
        }
        return Int64(value.rounded())
    }

    private static func dateColumn(_ statement: OpaquePointer, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(
            timeIntervalSince1970: Double(sqlite3_column_int64(statement, index)) / 1_000
        )
    }
}

public enum CoveStateFilesystem {
    public static func applicationSupportDirectoryURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = nil
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(bundleIdentifier ?? "Codex Cove", isDirectory: true)
    }

    public static func settingsURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = nil
    ) -> URL {
        applicationSupportDirectoryURL(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        ).appendingPathComponent("settings.json")
    }

    public static func sessionDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = nil
    ) -> URL {
        applicationSupportDirectoryURL(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier
        ).appendingPathComponent("sessions.sqlite3")
    }

    /// Compatibility alias for callers that still construct only the settings
    /// store. New code should use `settingsURL`.
    public static func applicationSupportURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = nil
    ) -> URL {
        settingsURL(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
    }
}

private enum CoveSecureFilesystem {
    static func prepareDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CovePersistenceError.unsafeFilesystemEntry(kind: "application support directory")
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try enforcePermissions(0o700, at: url, kind: "application support directory")
    }

    static func enforcePermissions(_ permissions: Int, at url: URL, kind: String) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw CovePersistenceError.unsafeFilesystemEntry(kind: kind)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    static func rejectSymbolicLinkIfPresent(at url: URL, kind: String) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return
        }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw CovePersistenceError.unsafeFilesystemEntry(kind: kind)
        }
    }

    static func canonicalDirectory(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = url.path.withCString { path in
            realpath(path, &buffer)
        }
        guard result != nil else {
            throw CovePersistenceError.unsafeFilesystemEntry(
                kind: "application support directory"
            )
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(
            fileURLWithPath: String(decoding: bytes, as: UTF8.self),
            isDirectory: true
        )
    }
}

private final class CoveSQLiteConnection {
    let handle: OpaquePointer

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { Self.boundedMessage(sqlite3_errmsg($0)) }
                ?? "database could not be opened"
            if let database {
                sqlite3_close(database)
            }
            throw CovePersistenceError.sqlite(
                operation: "open",
                code: result,
                message: message
            )
        }
        self.handle = database
        sqlite3_extended_result_codes(database, 1)
    }

    deinit {
        sqlite3_close(handle)
    }

    func configure() throws {
        let busyResult = sqlite3_busy_timeout(handle, 1_000)
        guard busyResult == SQLITE_OK else {
            throw error(operation: "configure busy timeout", code: busyResult)
        }
        try execute("PRAGMA foreign_keys = ON", operation: "enable foreign keys")
        try execute("PRAGMA trusted_schema = OFF", operation: "disable trusted schema")
        try execute("PRAGMA journal_mode = DELETE", operation: "configure journal mode")
        try execute("PRAGMA synchronous = FULL", operation: "configure synchronization")
    }

    func execute(_ sql: String, operation: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message: String
            if let errorPointer {
                message = Self.boundedMessage(errorPointer)
                sqlite3_free(errorPointer)
            } else {
                message = Self.boundedMessage(sqlite3_errmsg(handle))
            }
            throw CovePersistenceError.sqlite(
                operation: operation,
                code: result,
                message: message
            )
        }
    }

    func scalarInt(_ sql: String, operation: String) throws -> Int {
        let statement = try prepare(sql, operation: operation)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw error(operation: operation, code: result)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw error(operation: operation, code: result)
        }
        return statement
    }

    func bind(_ value: String?, to index: Int32, in statement: OpaquePointer, operation: String) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else {
                throw error(operation: operation, code: result)
            }
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transient)
        }
        guard result == SQLITE_OK else {
            throw error(operation: operation, code: result)
        }
    }

    func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer, operation: String) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_int64(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw error(operation: operation, code: result)
        }
    }

    func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw error(operation: operation, code: result)
        }
    }

    func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        Self.textColumn(statement, index: index)
    }

    static func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    func error(operation: String, code: Int32) -> CovePersistenceError {
        CovePersistenceError.sqlite(
            operation: operation,
            code: code,
            message: Self.boundedMessage(sqlite3_errmsg(handle))
        )
    }

    private static func boundedMessage(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "unknown database error" }
        return String(String(cString: pointer).prefix(256))
    }

    private static func boundedMessage(_ pointer: UnsafeMutablePointer<CChar>) -> String {
        boundedMessage(UnsafePointer(pointer))
    }
}
