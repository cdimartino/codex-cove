import Foundation

public enum CoveWorkspaceMode: String, Codable, CaseIterable, Sendable {
    case grid
    case board
}

public enum CoveWorkspaceSort: String, Codable, CaseIterable, Sendable {
    case manual
    case attention
    case recentActivity
    case name
    case source
}

public enum CoveSessionLiveness: String, Codable, Sendable {
    case loaded
    case live
    case closed
}

public enum CoveThreadControlRoute: String, Codable, Sendable {
    case desktop
    case routedLocal
    case routedRemote
}

public struct CoveWorkspaceColumn: Codable, Equatable, Hashable, Sendable,
    Identifiable {
    public var id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CoveWorkspaceLink: Codable, Equatable, Hashable, Sendable,
    Identifiable {
    public var id: String
    public var label: String
    public var url: URL

    public init(
        id: String = UUID().uuidString,
        label: String,
        url: URL
    ) {
        self.id = id
        self.label = label
        self.url = url
    }
}

public struct CoveWorkspaceCardState: Codable, Equatable, Sendable,
    Identifiable {
    public var identity: CoveSessionIdentity
    public var alias: String?
    public var tags: [String]
    public var links: [CoveWorkspaceLink]

    public var id: CoveSessionIdentity { identity }

    public init(
        identity: CoveSessionIdentity,
        alias: String? = nil,
        tags: [String] = [],
        links: [CoveWorkspaceLink] = []
    ) {
        self.identity = identity
        self.alias = alias
        self.tags = tags
        self.links = links
    }
}

public struct CoveWorkspaceAssignment: Codable, Equatable, Hashable,
    Sendable {
    public var identity: CoveSessionIdentity
    public var columnId: String

    public init(identity: CoveSessionIdentity, columnId: String) {
        self.identity = identity
        self.columnId = columnId
    }
}

public struct CovePromptTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var body: String
    public var favorite: Bool
    public var manualOrder: Int
    public var lastUsedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        body: String,
        favorite: Bool = false,
        manualOrder: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.favorite = favorite
        self.manualOrder = manualOrder
        self.lastUsedAt = lastUsedAt
    }
}

/// Explicitly user-authored Workspace content. Unlike `sessions.sqlite3`,
/// this file may contain the local aliases, organizational metadata, and saved
/// prompt templates the user chose to retain.
public struct CoveWorkspaceState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let inboxColumnID = "inbox"

    public var schemaVersion: Int
    public var gridOrder: [CoveSessionIdentity]
    public var columns: [CoveWorkspaceColumn]
    public var assignments: [CoveWorkspaceAssignment]
    public var cards: [CoveWorkspaceCardState]
    public var promptTemplates: [CovePromptTemplate]
    public var lastSelectedView: CoveWorkspaceMode

    public init(
        schemaVersion: Int = CoveWorkspaceState.currentSchemaVersion,
        gridOrder: [CoveSessionIdentity] = [],
        columns: [CoveWorkspaceColumn] = CoveWorkspaceState.defaultColumns,
        assignments: [CoveWorkspaceAssignment] = [],
        cards: [CoveWorkspaceCardState] = [],
        promptTemplates: [CovePromptTemplate] = [],
        lastSelectedView: CoveWorkspaceMode = .grid
    ) {
        self.schemaVersion = schemaVersion
        self.gridOrder = gridOrder
        self.columns = columns
        self.assignments = assignments
        self.cards = cards
        self.promptTemplates = promptTemplates
        self.lastSelectedView = lastSelectedView
    }

    public static let defaultColumns = [
        CoveWorkspaceColumn(id: inboxColumnID, name: "Inbox"),
        CoveWorkspaceColumn(id: "doing", name: "Doing"),
        CoveWorkspaceColumn(id: "review", name: "Review"),
        CoveWorkspaceColumn(id: "blocked", name: "Blocked"),
    ]

    public func card(for identity: CoveSessionIdentity) -> CoveWorkspaceCardState? {
        cards.first { $0.identity == identity }
    }

    public func columnID(for identity: CoveSessionIdentity) -> String {
        assignments.first { $0.identity == identity }?.columnId
            ?? Self.inboxColumnID
    }

    public mutating func ensureMembership(_ identities: [CoveSessionIdentity]) {
        var known = Set(gridOrder)
        for identity in identities where known.insert(identity).inserted {
            gridOrder.append(identity)
        }
    }

    public mutating func setAlias(
        _ alias: String?,
        for identity: CoveSessionIdentity
    ) {
        mutateCard(identity) { card in
            card.alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
    }

    public mutating func setTags(
        _ tags: [String],
        for identity: CoveSessionIdentity
    ) {
        mutateCard(identity) { $0.tags = tags }
    }

    public mutating func setLinks(
        _ links: [CoveWorkspaceLink],
        for identity: CoveSessionIdentity
    ) {
        mutateCard(identity) { $0.links = links }
    }

    public mutating func assign(
        _ identity: CoveSessionIdentity,
        to columnID: String
    ) {
        assignments.removeAll { $0.identity == identity }
        assignments.append(.init(identity: identity, columnId: columnID))
    }

    public mutating func deleteColumn(id: String) {
        guard id != Self.inboxColumnID else { return }
        columns.removeAll { $0.id == id }
        for index in assignments.indices where assignments[index].columnId == id {
            assignments[index].columnId = Self.inboxColumnID
        }
    }

    private mutating func mutateCard(
        _ identity: CoveSessionIdentity,
        _ mutation: (inout CoveWorkspaceCardState) -> Void
    ) {
        if let index = cards.firstIndex(where: { $0.identity == identity }) {
            mutation(&cards[index])
        } else {
            var card = CoveWorkspaceCardState(identity: identity)
            mutation(&card)
            cards.append(card)
        }
    }
}

public enum CoveWorkspaceLimits {
    public static let templates = 500
    public static let templateBodyBytes = 32 * 1_024
    public static let templateNameBytes = 128
    public static let aliasBytes = 256
    public static let tagsPerCard = 32
    public static let linksPerCard = 32
    public static let tagBytes = 64
    public static let linkLabelBytes = 128
    public static let linkURLBytes = 2_048
    public static let columns = 32
    public static let columnNameBytes = 128
    public static let opaqueIDBytes = 512
    public static let storedIdentities = 10_000
    public static let fileBytes = 64 * 1_024 * 1_024
}

public protocol CoveWorkspaceStorage: Sendable {
    func load() throws -> CoveWorkspaceState?
    func save(_ state: CoveWorkspaceState) throws
}

public struct CoveWorkspaceFileStorage: CoveWorkspaceStorage {
    public let url: URL

    public init(url: URL = CoveStateFilesystem.workspaceURL()) {
        self.url = url
    }

    public func load() throws -> CoveWorkspaceState? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        try CoveSecureFilesystem.rejectSymbolicLinkIfPresent(
            at: url,
            kind: "workspace file"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= CoveWorkspaceLimits.fileBytes
        else {
            throw CovePersistenceError.invalidWorkspace(field: "fileSize")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(
            CoveWorkspaceState.self,
            from: Data(contentsOf: url)
        )
        guard state.schemaVersion <= CoveWorkspaceState.currentSchemaVersion else {
            throw CovePersistenceError.unsupportedWorkspaceSchema(
                found: state.schemaVersion,
                supported: CoveWorkspaceState.currentSchemaVersion
            )
        }
        try Self.validate(state)
        try CoveSecureFilesystem.enforcePermissions(
            0o600,
            at: url,
            kind: "workspace file"
        )
        return state
    }

    public func save(_ state: CoveWorkspaceState) throws {
        try Self.validate(state)
        let directory = url.deletingLastPathComponent()
        try CoveSecureFilesystem.prepareDirectory(directory)
        try CoveSecureFilesystem.rejectSymbolicLinkIfPresent(
            at: url,
            kind: "workspace file"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(state)
        guard data.count <= CoveWorkspaceLimits.fileBytes else {
            throw CovePersistenceError.invalidWorkspace(field: "fileSize")
        }
        try CoveSecureFilesystem.writeAtomically(
            data,
            to: url,
            permissions: 0o600,
            kind: "workspace file"
        )
    }

    public static func validate(_ state: CoveWorkspaceState) throws {
        guard state.schemaVersion == CoveWorkspaceState.currentSchemaVersion else {
            if state.schemaVersion > CoveWorkspaceState.currentSchemaVersion {
                throw CovePersistenceError.unsupportedWorkspaceSchema(
                    found: state.schemaVersion,
                    supported: CoveWorkspaceState.currentSchemaVersion
                )
            }
            throw CovePersistenceError.invalidWorkspace(field: "schemaVersion")
        }
        guard state.columns.count <= CoveWorkspaceLimits.columns,
              state.columns.contains(where: {
                  $0.id == CoveWorkspaceState.inboxColumnID
              })
        else { throw CovePersistenceError.invalidWorkspace(field: "columns") }
        try validateUnique(state.columns.map(\.id), field: "columns.id")
        for column in state.columns {
            try validateText(column.id, field: "columns.id", max: CoveWorkspaceLimits.opaqueIDBytes)
            try validateText(column.name, field: "columns.name", max: CoveWorkspaceLimits.columnNameBytes)
        }
        guard state.promptTemplates.count <= CoveWorkspaceLimits.templates else {
            throw CovePersistenceError.invalidWorkspace(field: "promptTemplates")
        }
        try validateUnique(state.promptTemplates.map(\.id), field: "promptTemplates.id")
        for template in state.promptTemplates {
            try validateText(template.id, field: "promptTemplates.id", max: CoveWorkspaceLimits.opaqueIDBytes)
            try validateText(template.name, field: "promptTemplates.name", max: CoveWorkspaceLimits.templateNameBytes)
            try validateText(template.body, field: "promptTemplates.body", max: CoveWorkspaceLimits.templateBodyBytes)
            guard template.manualOrder >= 0 else {
                throw CovePersistenceError.invalidWorkspace(field: "promptTemplates.manualOrder")
            }
        }
        try validateUnique(
            state.promptTemplates.map(\.manualOrder),
            field: "promptTemplates.manualOrder"
        )
        guard state.gridOrder.count <= CoveWorkspaceLimits.storedIdentities,
              state.cards.count <= CoveWorkspaceLimits.storedIdentities,
              state.assignments.count <= CoveWorkspaceLimits.storedIdentities
        else {
            throw CovePersistenceError.invalidWorkspace(field: "identities")
        }
        try validateIdentities(state.gridOrder, field: "gridOrder")
        try validateUnique(state.gridOrder.map(\.id), field: "gridOrder")
        try validateIdentities(
            state.cards.map(\.identity),
            field: "cards.identity"
        )
        try validateUnique(
            state.cards.map { $0.identity.id },
            field: "cards.identity"
        )
        let columnIDs = Set(state.columns.map(\.id))
        try validateIdentities(
            state.assignments.map(\.identity),
            field: "assignments.identity"
        )
        try validateUnique(
            state.assignments.map { $0.identity.id },
            field: "assignments.identity"
        )
        guard state.assignments.allSatisfy({ columnIDs.contains($0.columnId) }) else {
            throw CovePersistenceError.invalidWorkspace(field: "assignments.columnId")
        }
        for card in state.cards {
            if let alias = card.alias {
                try validateText(alias, field: "cards.alias", max: CoveWorkspaceLimits.aliasBytes)
            }
            guard card.tags.count <= CoveWorkspaceLimits.tagsPerCard,
                  card.links.count <= CoveWorkspaceLimits.linksPerCard
            else { throw CovePersistenceError.invalidWorkspace(field: "cards.metadata") }
            try validateUnique(card.tags.map { $0.lowercased() }, field: "cards.tags")
            for tag in card.tags {
                try validateText(tag, field: "cards.tags", max: CoveWorkspaceLimits.tagBytes)
            }
            try validateUnique(card.links.map(\.id), field: "cards.links.id")
            for link in card.links {
                try validateText(link.id, field: "cards.links.id", max: CoveWorkspaceLimits.opaqueIDBytes)
                try validateText(link.label, field: "cards.links.label", max: CoveWorkspaceLimits.linkLabelBytes)
                let absolute = link.url.absoluteString
                guard absolute.utf8.count <= CoveWorkspaceLimits.linkURLBytes,
                      let scheme = link.url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      link.url.host != nil,
                      link.url.user == nil,
                      link.url.password == nil
                else { throw CovePersistenceError.invalidWorkspace(field: "cards.links.url") }
            }
        }
    }

    private static func validateIdentities(
        _ identities: [CoveSessionIdentity],
        field: String
    ) throws {
        guard identities.allSatisfy({ identity in
            CoveSessionIdentity(
                source: identity.source,
                hostId: identity.remoteHostId,
                sessionId: identity.sessionId
            ) == identity
                && (identity.remoteHostId?.utf8.count ?? 0)
                    <= CoveWorkspaceLimits.opaqueIDBytes
        }) else {
            throw CovePersistenceError.invalidWorkspace(field: field)
        }
    }

    private static func validateText(
        _ value: String,
        field: String,
        max: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= max,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      && $0 != "\n" && $0 != "\t"
              })
        else { throw CovePersistenceError.invalidWorkspace(field: field) }
    }

    private static func validateUnique<T: Hashable>(
        _ values: [T],
        field: String
    ) throws {
        guard Set(values).count == values.count else {
            throw CovePersistenceError.invalidWorkspace(field: field)
        }
    }
}

public struct CoveWorkspaceFilter: Equatable, Sendable {
    public var statuses: Set<CoveSessionStatus>
    public var sources: Set<CoveWireSource>
    public var hosts: Set<String>
    public var tags: Set<String>
    public var columns: Set<String>
    public var unreadOnly: Bool
    public var pinnedOnly: Bool
    public var controllableOnly: Bool
    public var attentionOnly: Bool

    public init(
        statuses: Set<CoveSessionStatus> = [],
        sources: Set<CoveWireSource> = [],
        hosts: Set<String> = [],
        tags: Set<String> = [],
        columns: Set<String> = [],
        unreadOnly: Bool = false,
        pinnedOnly: Bool = false,
        controllableOnly: Bool = false,
        attentionOnly: Bool = false
    ) {
        self.statuses = statuses
        self.sources = sources
        self.hosts = hosts
        self.tags = tags
        self.columns = columns
        self.unreadOnly = unreadOnly
        self.pinnedOnly = pinnedOnly
        self.controllableOnly = controllableOnly
        self.attentionOnly = attentionOnly
    }

    public var isEmpty: Bool {
        statuses.isEmpty && sources.isEmpty && hosts.isEmpty && tags.isEmpty
            && columns.isEmpty && !unreadOnly && !pinnedOnly
            && !controllableOnly && !attentionOnly
    }
}

public struct CoveWorkspaceItem: Equatable, Sendable, Identifiable {
    public var identity: CoveSessionIdentity
    public var snapshot: CoveSessionSnapshot
    public var alias: String?
    public var tags: [String]
    public var links: [CoveWorkspaceLink]
    public var columnID: String
    public var isPinned: Bool
    public var descendantAttentionCount: Int
    public var children: [CoveSessionIdentity]

    public var id: CoveSessionIdentity { identity }
    public var displayName: String { alias ?? snapshot.title }
    public var isControllable: Bool { snapshot.canAcceptThreadControl }
}

/// Pure, origin-safe dashboard membership and hierarchy projection.
public struct CoveWorkspaceProjection: Equatable, Sendable {
    public var items: [CoveWorkspaceItem]
    public var roots: [CoveSessionIdentity]
    public var unattachedAgents: [CoveSessionIdentity]

    public init(
        snapshots: [CoveSessionSnapshot],
        workspace: CoveWorkspaceState,
        pinnedIdentities: Set<CoveSessionIdentity> = [],
        query: String = "",
        filter: CoveWorkspaceFilter = .init(),
        sort: CoveWorkspaceSort = .manual,
        redactSensitiveContent: Bool = false
    ) {
        let latest = Dictionary(
            snapshots.compactMap { snapshot -> (CoveSessionIdentity, CoveSessionSnapshot)? in
                guard let identity = snapshot.sessionIdentity,
                      Self.isWorkspaceMember(snapshot)
                else { return nil }
                return (identity, snapshot)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.timestamp >= rhs.timestamp ? lhs : rhs
            }
        )
        let identities = Set(latest.keys)
        let requestedParent = Dictionary(
            uniqueKeysWithValues: latest.compactMap { identity, snapshot in
                snapshot.parentIdentity.map { (identity, $0) }
            }
        )
        var validParent: [CoveSessionIdentity: CoveSessionIdentity] = [:]
        var unattached = Set<CoveSessionIdentity>()
        for (child, parent) in requestedParent {
            guard identities.contains(parent), parent != child,
                  !Self.createsCycle(child: child, parent: parent, parents: requestedParent)
            else {
                unattached.insert(child)
                continue
            }
            validParent[child] = parent
        }
        var children: [CoveSessionIdentity: [CoveSessionIdentity]] = [:]
        for (child, parent) in validParent {
            children[parent, default: []].append(child)
        }
        let attention = Self.descendantAttention(latest: latest, children: children)
        let columnNames = Dictionary(uniqueKeysWithValues: workspace.columns.map { ($0.id, $0.name) })
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let order = Dictionary(uniqueKeysWithValues: workspace.gridOrder.enumerated().map { ($1, $0) })
        var projected = latest.compactMap { identity, snapshot -> CoveWorkspaceItem? in
            let card = workspace.card(for: identity)
            let columnID = workspace.columnID(for: identity)
            let item = CoveWorkspaceItem(
                identity: identity,
                snapshot: snapshot,
                alias: card?.alias,
                tags: card?.tags ?? [],
                links: card?.links ?? [],
                columnID: columnID,
                isPinned: pinnedIdentities.contains(identity),
                descendantAttentionCount: attention[identity] ?? 0,
                children: (children[identity] ?? []).sorted()
            )
            guard Self.matches(
                item,
                query: normalizedQuery,
                filter: filter,
                columnName: columnNames[columnID],
                redact: redactSensitiveContent
            ) else { return nil }
            return item
        }
        projected.sort { lhs, rhs in
            switch sort {
            case .manual:
                return (order[lhs.identity] ?? Int.max, lhs.identity.id)
                    < (order[rhs.identity] ?? Int.max, rhs.identity.id)
            case .attention:
                let left = (Self.attentionStatus(lhs.snapshot.status) ? 0 : 1,
                            -lhs.descendantAttentionCount,
                            -lhs.snapshot.priority,
                            lhs.identity.id)
                let right = (Self.attentionStatus(rhs.snapshot.status) ? 0 : 1,
                             -rhs.descendantAttentionCount,
                             -rhs.snapshot.priority,
                             rhs.identity.id)
                return left < right
            case .recentActivity:
                if lhs.snapshot.timestamp != rhs.snapshot.timestamp {
                    return lhs.snapshot.timestamp > rhs.snapshot.timestamp
                }
                return lhs.identity < rhs.identity
            case .name:
                let left = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if left != .orderedSame { return left == .orderedAscending }
                return lhs.identity < rhs.identity
            case .source:
                let left = "\(lhs.identity.source.rawValue)\u{0}\(lhs.identity.remoteHostId ?? "")"
                let right = "\(rhs.identity.source.rawValue)\u{0}\(rhs.identity.remoteHostId ?? "")"
                return left == right ? lhs.identity < rhs.identity : left < right
            }
        }
        let visible = Set(projected.map(\.identity))
        self.items = projected
        self.roots = projected.map(\.identity).filter {
            validParent[$0].map { !visible.contains($0) } ?? true
        }
        self.unattachedAgents = unattached.intersection(visible).sorted()
    }

    public func item(_ identity: CoveSessionIdentity) -> CoveWorkspaceItem? {
        items.first { $0.identity == identity }
    }

    public static func isWorkspaceMember(_ snapshot: CoveSessionSnapshot) -> Bool {
        switch snapshot.liveness {
        case .loaded, .live:
            return true
        case .closed:
            return snapshot.unread
                && (snapshot.status == .failed || snapshot.status == .interrupted)
        case nil:
            return snapshot.unread
                && (snapshot.status == .failed || snapshot.status == .interrupted)
        }
    }

    private static func createsCycle(
        child: CoveSessionIdentity,
        parent: CoveSessionIdentity,
        parents: [CoveSessionIdentity: CoveSessionIdentity]
    ) -> Bool {
        var cursor: CoveSessionIdentity? = parent
        var visited = Set<CoveSessionIdentity>()
        while let current = cursor, visited.insert(current).inserted {
            if current == child { return true }
            cursor = parents[current]
        }
        return cursor != nil
    }

    private static func descendantAttention(
        latest: [CoveSessionIdentity: CoveSessionSnapshot],
        children: [CoveSessionIdentity: [CoveSessionIdentity]]
    ) -> [CoveSessionIdentity: Int] {
        var result: [CoveSessionIdentity: Int] = [:]
        func count(_ identity: CoveSessionIdentity) -> Int {
            if let cached = result[identity] { return cached }
            let value = (children[identity] ?? []).reduce(0) { total, child in
                total + (attentionStatus(latest[child]?.status) ? 1 : 0) + count(child)
            }
            result[identity] = value
            return value
        }
        latest.keys.forEach { _ = count($0) }
        return result
    }

    private static func matches(
        _ item: CoveWorkspaceItem,
        query: String,
        filter: CoveWorkspaceFilter,
        columnName: String?,
        redact: Bool
    ) -> Bool {
        let snapshot = item.snapshot
        if !filter.statuses.isEmpty && !filter.statuses.contains(snapshot.status) { return false }
        if filter.unreadOnly && !snapshot.unread { return false }
        if filter.pinnedOnly && !item.isPinned { return false }
        if filter.controllableOnly && !item.isControllable { return false }
        if filter.attentionOnly && !attentionStatus(snapshot.status)
            && item.descendantAttentionCount == 0 { return false }
        if !redact {
            if !filter.sources.isEmpty && !filter.sources.contains(item.identity.source) { return false }
            if !filter.hosts.isEmpty && !filter.hosts.contains(item.identity.remoteHostId ?? "") { return false }
            if !filter.columns.isEmpty && !filter.columns.contains(item.columnID) { return false }
            let itemTags = Set(item.tags.map { $0.lowercased() })
            if !filter.tags.isEmpty && !filter.tags.map({ $0.lowercased() }).allSatisfy(itemTags.contains) { return false }
        }
        guard !query.isEmpty else { return true }
        var values = [snapshot.status.rawValue]
        if !redact {
            values.append(contentsOf: [
                item.identity.source.rawValue,
                item.identity.source.displayName,
                item.identity.remoteHostId ?? "",
                columnName ?? "",
                item.displayName,
            ] + item.tags)
            values.append(contentsOf: item.links.flatMap { [$0.label, $0.url.host ?? ""] })
        }
        return values.contains { $0.lowercased().contains(query) }
    }

    private static func attentionStatus(_ status: CoveSessionStatus?) -> Bool {
        status == .waitingApproval || status == .waitingInput || status == .blocked
    }
}

public enum CoveThreadControlOperation: String, Codable, Sendable {
    case start
    case steer
}

public struct CoveThreadControlRequest: Codable, Equatable, Sendable {
    public static let maximumInputBytes = 32 * 1_024

    public var target: CoveSessionIdentity
    public var operation: CoveThreadControlOperation
    public var expectedTurnId: String?
    public var clientMessageId: String
    public var input: String

    public init(
        target: CoveSessionIdentity,
        operation: CoveThreadControlOperation,
        expectedTurnId: String? = nil,
        clientMessageId: String = UUID().uuidString,
        input: String
    ) {
        self.target = target
        self.operation = operation
        self.expectedTurnId = expectedTurnId
        self.clientMessageId = clientMessageId
        self.input = input
    }

    public func validate() throws {
        let validControlID = !clientMessageId.isEmpty
            && clientMessageId.utf8.count <= 128
            && clientMessageId.utf8.allSatisfy { byte in
                switch byte {
                case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                    true
                default:
                    false
                }
            }
        let validTarget = CoveSessionIdentity(
            source: target.source,
            hostId: target.remoteHostId,
            sessionId: target.sessionId
        ) == target
        let validOperation = switch operation {
        case .start:
            expectedTurnId == nil
        case .steer:
            expectedTurnId?.isEmpty == false
                && (expectedTurnId?.utf8.count ?? 0) <= 512
        }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.utf8.count <= Self.maximumInputBytes,
              validControlID,
              validTarget,
              validOperation
        else { throw CovePersistenceError.invalidMetadata(field: "threadControl") }
    }
}

public extension CoveSessionSnapshot {
    /// Whether Cove has enough authoritative state to choose start versus
    /// steer without guessing an active turn identifier.
    var canAcceptThreadControl: Bool {
        guard controlRoute != nil else { return false }
        if activeTurnId != nil { return true }
        switch status {
        case .working, .active, .waitingApproval, .waitingInput, .blocked,
             .compacting:
            return false
        case .idle, .listening, .quiet, .hidden, .completed, .failed,
             .interrupted:
            return true
        }
    }
}

public enum CoveThreadControlRejection: String, Codable, Sendable {
    case unavailable
    case unsupported
    case staleRoute
    case wrongOrigin
    case pendingRequest
    case turnMismatch
    case invalidInput
    case serverRejected
}

public enum CoveThreadControlResult: Codable, Equatable, Sendable {
    case accepted(turnId: String?)
    case rejected(CoveThreadControlRejection)
    case uncertain
}

public protocol CoveThreadControlling: Sendable {
    func send(_ request: CoveThreadControlRequest) async -> CoveThreadControlResult
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
