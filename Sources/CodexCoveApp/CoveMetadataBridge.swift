import Foundation
import CoveCore

@MainActor
final class CoveMetadataBridge {
    private let storage: CoveSQLiteSessionMetadataStorage
    private let pinStoreURL: URL

    init(
        storage: CoveSQLiteSessionMetadataStorage = .init(),
        pinStoreURL: URL = CoveStateFilesystem
            .applicationSupportDirectoryURL()
            .appendingPathComponent("session-pins.json")
    ) {
        self.storage = storage
        self.pinStoreURL = pinStoreURL
    }

    func initialize() {
        do {
            try storage.initialize()
            _ = try storage.prune(
                updatedBefore: Date().addingTimeInterval(-90 * 24 * 60 * 60),
                limit: CoveSQLiteSessionMetadataStorage.hardMaximumQueryRows
            )
        } catch {
            NSLog("Cove metadata initialization failed: \(error)")
        }
    }

    @discardableResult
    func restore(into store: CoveStore) -> [CoveSessionMetadata] {
        do {
            let records = try storage.recent(limit: 100)
            store.restore(metadata: records)
            do {
                store.restorePinnedSessionIDs(
                    Array(try loadPinnedSessionIDs())
                )
            } catch {
                // A damaged optional pin sidecar must never suppress restored
                // session/jump metadata from the primary database.
                NSLog("Cove pin restore failed: \(error)")
            }
            return records
        } catch {
            NSLog("Cove metadata restore failed: \(error)")
            return []
        }
    }

    func record(
        _ envelope: CoveWireEnvelope,
        state: CoveState,
        observedTerminalLocation: CoveTerminalLocationMetadata? = nil
    ) {
        guard !envelope.isPermanentlyHiddenInternalEvent else { return }
        // Editor registrations describe an adapter endpoint, not a Codex
        // session. The jump service keeps them in memory and attaches one to
        // the next matching launch; persisting the extension's stable ID as a
        // session would create a phantom card after restart.
        guard envelope.kind.rawValue != "terminal.registered" else { return }
        let sessionID = envelope.sessionId == "pending"
            ? (envelope.launchId ?? envelope.eventId)
            : envelope.sessionId
        guard !sessionID.isEmpty && sessionID != "unknown" else { return }
        do {
            let existing = try storage.metadata(sessionId: sessionID)
            let incomingOrigin = envelope.originScope
            // The v1 metadata table is keyed by the externally supplied
            // session ID. Until the on-disk schema can store the full origin
            // tuple, never blend or overwrite a record owned by another
            // source/remote host.
            if let existing, existing.originScope != incomingOrigin {
                NSLog(
                    "Cove metadata ignored a cross-origin session-ID collision"
                )
                return
            }
            let candidatePendingSessionID: String? = {
                guard envelope.sessionId != "pending",
                      let launchID = envelope.launchId,
                      launchID != sessionID else {
                    return nil
                }
                return launchID
            }()
            let candidatePending = try candidatePendingSessionID.flatMap {
                try storage.metadata(sessionId: $0)
            }
            let pending = candidatePending?.originScope == incomingOrigin
                ? candidatePending
                : nil
            let pendingSessionID = pending == nil
                ? nil
                : candidatePendingSessionID
            let eventIsCurrent = existing?.updatedAt ?? .distantPast
                <= envelope.timestamp
            let status = eventIsCurrent
                ? envelope.sessionStatusUpdate()?.status
                    ?? existing?.status
                    ?? pending?.status
                    ?? state.session.activeStatus
                : existing?.status
                    ?? pending?.status
                    ?? state.session.activeStatus
            let shouldBeUnread = existing?.unread == true
                || pending?.unread == true
                || status == .waitingApproval
                || status == .waitingInput
                || status == .completed
                || status == .failed
            let startedAt = [
                existing?.startedAt,
                pending?.startedAt,
                envelope.timestamp,
            ].compactMap { $0 }.min() ?? envelope.timestamp
            let updatedAt = max(
                envelope.timestamp,
                existing?.updatedAt ?? .distantPast,
                pending?.updatedAt ?? .distantPast
            )
            let metadata = CoveSessionMetadata(
                sessionId: sessionID,
                launchId: envelope.launchId
                    ?? existing?.launchId
                    ?? pending?.launchId,
                turnId: eventIsCurrent
                    ? envelope.turnId ?? existing?.turnId ?? pending?.turnId
                    : existing?.turnId ?? envelope.turnId ?? pending?.turnId,
                source: eventIsCurrent
                    ? envelope.source
                    : existing?.source ?? envelope.source,
                status: status,
                unread: shouldBeUnread,
                reminderAt: existing?.reminderAt ?? pending?.reminderAt,
                terminalLocation: observedTerminalLocation
                    ?? envelope.terminalLocationMetadata()
                    ?? existing?.terminalLocation
                    ?? pending?.terminalLocation,
                hostId: envelope.hostId
                    ?? existing?.hostId
                    ?? pending?.hostId,
                parentSessionId: envelope.parentSessionID()
                    ?? existing?.parentSessionId
                    ?? pending?.parentSessionId,
                updatedAt: updatedAt,
                startedAt: startedAt
            )
            try storage.upsert(
                metadata,
                replacingSessionId: pendingSessionID
            )
        } catch {
            NSLog("Cove metadata write failed: \(error)")
        }
    }

    func markRead(sessionID: String) {
        do {
            guard var metadata = try storage.metadata(sessionId: sessionID) else { return }
            metadata.unread = false
            metadata.updatedAt = Date()
            try storage.upsert(metadata)
        } catch {
            NSLog("Cove mark-read failed: \(error)")
        }
    }

    func remove(
        sessionID: String,
        source: CoveWireSource,
        hostID: String?
    ) {
        guard let origin = CoveOriginScope(source: source, hostId: hostID) else {
            return
        }
        do {
            guard let existing = try storage.metadata(sessionId: sessionID),
                  existing.originScope == origin else {
                return
            }
            try storage.remove(sessionId: sessionID)
        } catch {
            NSLog("Cove metadata removal failed: \(error)")
        }
    }

    @discardableResult
    func setPinned(sessionID: String, pinned: Bool) -> Bool {
        guard isValidSessionID(sessionID) else { return false }
        do {
            var sessionIDs = try loadPinnedSessionIDs()
            if pinned {
                sessionIDs.insert(sessionID)
            } else {
                sessionIDs.remove(sessionID)
            }
            try savePinnedSessionIDs(sessionIDs)
            return true
        } catch {
            NSLog("Cove pin persistence failed: \(error)")
            return false
        }
    }

    @discardableResult
    func scheduleReminder(sessionID: String, at date: Date) -> Bool {
        do {
            guard date.timeIntervalSince1970.isFinite,
                  var metadata = try storage.metadata(sessionId: sessionID)
            else { return false }
            metadata.reminderAt = date
            try storage.upsert(metadata)
            return true
        } catch {
            NSLog("Cove reminder scheduling failed: \(error)")
            return false
        }
    }

    @discardableResult
    func clearReminder(sessionID: String) -> Bool {
        do {
            guard var metadata = try storage.metadata(sessionId: sessionID) else {
                return false
            }
            metadata.reminderAt = nil
            try storage.upsert(metadata)
            return true
        } catch {
            NSLog("Cove reminder cancellation failed: \(error)")
            return false
        }
    }

    func dueReminders(now: Date = Date()) -> [CoveSessionMetadata] {
        do {
            return try storage.dueReminders(
                now: now,
                limit: CoveSQLiteSessionMetadataStorage
                    .hardMaximumQueryRows
            )
        } catch {
            NSLog("Cove due-reminder read failed: \(error)")
            return []
        }
    }

    func diagnostics() -> CoveSessionMetadataDiagnostics? {
        do {
            return try storage.diagnostics()
        } catch {
            NSLog("Cove metadata diagnostics failed: \(error)")
            return nil
        }
    }

    private struct PinDocument: Codable {
        var schemaVersion: Int
        var sessionIDs: [String]
    }

    private func loadPinnedSessionIDs() throws -> Set<String> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: pinStoreURL.path) else {
            return []
        }
        let values = try pinStoreURL.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
        )
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let data = try Data(contentsOf: pinStoreURL)
        guard data.count <= 256 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let document = try JSONDecoder().decode(PinDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Set(document.sessionIDs.prefix(1_000).filter(isValidSessionID))
    }

    private func savePinnedSessionIDs(_ sessionIDs: Set<String>) throws {
        let directory = pinStoreURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let document = PinDocument(
            schemaVersion: 1,
            sessionIDs: Array(sessionIDs).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: pinStoreURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pinStoreURL.path
        )
    }

    private func isValidSessionID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}
