import Foundation
import CoveCore

@MainActor
final class CoveWorkspaceStore: ObservableObject {
    typealias ControlHandler = @Sendable (
        CoveThreadControlRequest
    ) async -> CoveThreadControlResult

    @Published private(set) var state: CoveWorkspaceState
    @Published var selectedIdentity: CoveSessionIdentity?
    @Published var query = ""
    @Published var sort: CoveWorkspaceSort = .manual
    @Published var filter = CoveWorkspaceFilter()
    @Published var composerText = ""
    @Published private(set) var isSending = false
    @Published private(set) var message: String?

    var onControl: ControlHandler?
    var onReconcileRequested: (() -> Void)?

    private let storage: any CoveWorkspaceStorage
    private let writesEnabled: Bool

    struct PreparedThreadControl: Equatable {
        var request: CoveThreadControlRequest
        var route: CoveThreadControlRoute
    }

    init(
        storage: any CoveWorkspaceStorage = CoveWorkspaceFileStorage(),
        initialState: CoveWorkspaceState? = nil,
        writesEnabled: Bool = true
    ) {
        self.storage = storage
        self.writesEnabled = writesEnabled
        if let initialState {
            state = initialState
        } else {
            do {
                state = try storage.load() ?? CoveWorkspaceState()
            } catch {
                state = CoveWorkspaceState()
                message = "Workspace content could not be loaded and was left untouched."
            }
        }
    }

    func projection(
        coveState: CoveState,
        redactsSensitiveContent: Bool
    ) -> CoveWorkspaceProjection {
        CoveWorkspaceProjection(
            snapshots: coveState.session.snapshots,
            workspace: state,
            pinnedIdentities: Set(
                coveState.session.snapshots.compactMap { snapshot in
                    guard let identity = snapshot.sessionIdentity else { return nil }
                    return coveState.pinnedSessionIDs.contains(identity.id)
                        ? identity : nil
                }
            ),
            query: query,
            filter: filter,
            sort: sort,
            redactSensitiveContent: redactsSensitiveContent
        )
    }

    func reconcileMembership(with snapshots: [CoveSessionSnapshot]) {
        let identities = snapshots.compactMap { snapshot in
            CoveWorkspaceProjection.isWorkspaceMember(snapshot)
                ? snapshot.sessionIdentity : nil
        }
        if let selectedIdentity, !identities.contains(selectedIdentity) {
            select(nil)
        }
        let missing = identities.filter { !state.gridOrder.contains($0) }
        guard !missing.isEmpty else { return }
        mutate { $0.ensureMembership(missing) }
    }

    func select(_ identity: CoveSessionIdentity?) {
        if selectedIdentity != identity { composerText = "" }
        selectedIdentity = identity
    }

    func setView(_ view: CoveWorkspaceMode) {
        mutate { $0.lastSelectedView = view }
    }

    func setAlias(_ alias: String?, for identity: CoveSessionIdentity) {
        mutate { $0.setAlias(alias, for: identity) }
    }

    func setTags(_ tags: [String], for identity: CoveSessionIdentity) {
        var seen = Set<String>()
        let normalized = tags.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty,
                  seen.insert(trimmed.lowercased()).inserted
            else { return nil }
            return trimmed
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        mutate { $0.setTags(normalized, for: identity) }
    }

    func setLinks(
        _ links: [CoveWorkspaceLink],
        for identity: CoveSessionIdentity
    ) {
        mutate { $0.setLinks(links, for: identity) }
    }

    func move(
        _ identity: CoveSessionIdentity,
        relativeOffset: Int
    ) {
        guard let index = state.gridOrder.firstIndex(of: identity) else { return }
        let destination = min(
            max(0, index + relativeOffset),
            state.gridOrder.count - 1
        )
        guard destination != index else { return }
        mutate { workspace in
            workspace.gridOrder.remove(at: index)
            workspace.gridOrder.insert(identity, at: destination)
        }
    }

    func move(
        _ identity: CoveSessionIdentity,
        before destination: CoveSessionIdentity
    ) {
        guard identity != destination,
              let sourceIndex = state.gridOrder.firstIndex(of: identity),
              let rawDestination = state.gridOrder.firstIndex(of: destination)
        else { return }
        mutate { workspace in
            workspace.gridOrder.remove(at: sourceIndex)
            let destinationIndex = sourceIndex < rawDestination
                ? rawDestination - 1 : rawDestination
            workspace.gridOrder.insert(identity, at: destinationIndex)
        }
    }

    func restoreGridOrder(_ order: [CoveSessionIdentity]) {
        guard Set(order) == Set(state.gridOrder), order.count == state.gridOrder.count
        else { return }
        mutate { $0.gridOrder = order }
    }

    func assign(_ identity: CoveSessionIdentity, to columnID: String) {
        guard state.columns.contains(where: { $0.id == columnID }) else { return }
        mutate { $0.assign(identity, to: columnID) }
    }

    func addColumn(named name: String) {
        guard state.columns.count < CoveWorkspaceLimits.columns else {
            message = "A Workspace can contain at most 32 columns."
            return
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { $0.columns.append(.init(name: normalized)) }
    }

    func renameColumn(id: String, name: String) {
        mutate { workspace in
            guard let index = workspace.columns.firstIndex(where: { $0.id == id }) else { return }
            workspace.columns[index].name = name
        }
    }

    func deleteColumn(id: String) {
        mutate { $0.deleteColumn(id: id) }
    }

    func moveColumn(id: String, offset: Int) {
        guard let index = state.columns.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(0, index + offset), state.columns.count - 1)
        guard index != destination else { return }
        mutate { workspace in
            let column = workspace.columns.remove(at: index)
            workspace.columns.insert(column, at: destination)
        }
    }

    func saveTemplate(
        id: String? = nil,
        name: String,
        body: String,
        favorite: Bool = false
    ) {
        mutate { workspace in
            if let id,
               let index = workspace.promptTemplates.firstIndex(where: {
                   $0.id == id
               }) {
                workspace.promptTemplates[index].name = name
                workspace.promptTemplates[index].body = body
                workspace.promptTemplates[index].favorite = favorite
            } else {
                let nextOrder = (workspace.promptTemplates.map(\.manualOrder).max() ?? -1) + 1
                workspace.promptTemplates.append(
                    .init(
                        name: name,
                        body: body,
                        favorite: favorite,
                        manualOrder: nextOrder
                    )
                )
            }
        }
    }

    func deleteTemplate(id: String) {
        mutate { $0.promptTemplates.removeAll { $0.id == id } }
    }

    func moveTemplate(id: String, offset: Int) {
        let ordered = state.promptTemplates.sorted {
            $0.manualOrder < $1.manualOrder
        }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else {
            return
        }
        let destination = min(max(0, index + offset), ordered.count - 1)
        guard destination != index else { return }
        var reordered = ordered
        let template = reordered.remove(at: index)
        reordered.insert(template, at: destination)
        mutate { workspace in
            let orderByID = Dictionary(uniqueKeysWithValues: reordered.enumerated().map {
                ($0.element.id, $0.offset)
            })
            for itemIndex in workspace.promptTemplates.indices {
                workspace.promptTemplates[itemIndex].manualOrder =
                    orderByID[workspace.promptTemplates[itemIndex].id]
                    ?? workspace.promptTemplates[itemIndex].manualOrder
            }
        }
    }

    func useTemplate(_ template: CovePromptTemplate) {
        composerText = template.body
        mutate { workspace in
            guard let index = workspace.promptTemplates.firstIndex(where: {
                $0.id == template.id
            }) else { return }
            workspace.promptTemplates[index].lastUsedAt = Date()
        }
    }

    var favoriteAndRecentTemplates: [CovePromptTemplate] {
        state.promptTemplates.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return (lhs.lastUsedAt ?? .distantPast)
                    > (rhs.lastUsedAt ?? .distantPast)
            }
            return lhs.manualOrder < rhs.manualOrder
        }
    }

    func canPrepareSend(
        to snapshot: CoveSessionSnapshot,
        pendingRequests: [CoveDirectRequest]
    ) -> Bool {
        !isSending
            && snapshot.canAcceptThreadControl
            && snapshot.sessionIdentity == selectedIdentity
            && pendingRequests.allSatisfy({
                $0.sessionIdentity != snapshot.sessionIdentity
            })
            && !composerText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    func prepareSend(
        to snapshot: CoveSessionSnapshot,
        pendingRequests: [CoveDirectRequest]
    ) -> PreparedThreadControl? {
        guard canPrepareSend(
            to: snapshot,
            pendingRequests: pendingRequests
        ),
              let identity = snapshot.sessionIdentity,
              let route = snapshot.controlRoute
        else {
            message = "This task cannot accept a prompt here. Open it in Codex to continue."
            return nil
        }
        let operation: CoveThreadControlOperation
        let expectedTurnID: String?
        if let activeTurnID = snapshot.activeTurnId {
            operation = .steer
            expectedTurnID = activeTurnID
        } else {
            operation = .start
            expectedTurnID = nil
        }
        let request = CoveThreadControlRequest(
            target: identity,
            operation: operation,
            expectedTurnId: expectedTurnID,
            input: composerText
        )
        do {
            try request.validate()
        } catch {
            message = "Enter a prompt no larger than 32 KiB."
            return nil
        }
        message = nil
        return PreparedThreadControl(request: request, route: route)
    }

    func confirmSend(
        _ prepared: PreparedThreadControl,
        currentSnapshots: [CoveSessionSnapshot],
        pendingRequests: [CoveDirectRequest]
    ) {
        guard !isSending,
              selectedIdentity == prepared.request.target,
              composerText == prepared.request.input,
              let snapshot = currentSnapshots.first(where: {
                  $0.sessionIdentity == prepared.request.target
              }),
              snapshot.controlRoute == prepared.route,
              snapshot.canAcceptThreadControl,
              pendingRequests.allSatisfy({
                  $0.sessionIdentity != prepared.request.target
              })
        else {
            message = "The task changed before Send. Review its current state and try again."
            return
        }
        let currentOperation: CoveThreadControlOperation =
            snapshot.activeTurnId == nil ? .start : .steer
        guard currentOperation == prepared.request.operation,
              snapshot.activeTurnId == prepared.request.expectedTurnId,
              let onControl
        else {
            message = "The task changed before Send. Review its current state and try again."
            return
        }
        isSending = true
        message = nil
        Task {
            let result = await onControl(prepared.request)
            guard self.selectedIdentity == prepared.request.target else {
                self.isSending = false
                return
            }
            self.isSending = false
            switch result {
            case .accepted:
                self.composerText = ""
                self.message = prepared.request.operation == .start
                    ? "Turn started." : "Prompt steered to the active turn."
            case let .rejected(reason):
                self.message = "Prompt was not sent (\(reason.rawValue))."
            case .uncertain:
                self.message = "Delivery is uncertain. Check Codex before trying again."
            }
        }
    }

    func clearMessage() { message = nil }

    private func mutate(_ body: (inout CoveWorkspaceState) -> Void) {
        var candidate = state
        body(&candidate)
        guard candidate != state else { return }
        do {
            try CoveWorkspaceFileStorage.validate(candidate)
            if writesEnabled { try storage.save(candidate) }
            state = candidate
        } catch {
            message = error.localizedDescription
        }
    }
}
