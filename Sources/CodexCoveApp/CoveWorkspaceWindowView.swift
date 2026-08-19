import SwiftUI
import CoveCore

struct CoveWorkspaceWindowView: View {
    @Environment(\.undoManager) private var undoManager
    @ObservedObject var store: CoveStore
    @ObservedObject var workspace: CoveWorkspaceStore
    let onClose: @MainActor () -> Void

    @State private var showsPromptLibrary = false
    @State private var showsColumnManager = false

    private var redactsSensitiveContent: Bool {
        store.state.settings.privacyMode == .on
            || store.state.privacyScene != .normal
    }

    private var privacyRedactionExplanation: String? {
        guard redactsSensitiveContent else { return nil }
        if store.state.settings.privacyMode == .on {
            return "Privacy Mode is On, so Workspace titles and user-authored details are hidden."
        }
        switch store.state.privacyScene {
        case .locked:
            return "Cove is waiting for macOS to confirm this session is unlocked, so Workspace details are hidden."
        case .redacted:
            return "Automatic capture-app privacy is active, so Workspace details are hidden."
        case .normal:
            return nil
        }
    }

    private var projection: CoveWorkspaceProjection {
        workspace.projection(
            coveState: store.state,
            redactsSensitiveContent: redactsSensitiveContent
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if workspace.state.lastSelectedView == .grid {
                    grid
                } else {
                    board
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selected = workspace.selectedIdentity,
               let item = projection.item(selected)
                    ?? unfilteredItem(selected) {
                Divider()
                CoveWorkspaceInspector(
                    item: item,
                    projection: unfilteredProjection,
                    store: store,
                    workspace: workspace,
                    undoManager: undoManager,
                    redactsSensitiveContent: redactsSensitiveContent
                )
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
            }
        }
        .searchable(
            text: $workspace.query,
            placement: .toolbar,
            prompt: "Search tasks, tags, artifacts, and origins"
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button {
                        workspace.setView(.grid)
                    } label: {
                        Label("Grid", systemImage: "square.grid.2x2")
                    }
                    .disabled(workspace.state.lastSelectedView == .grid)
                    .help("Show tasks as a responsive card grid.")
                    .accessibilityIdentifier("cove.workspace.grid")
                    Button {
                        workspace.setView(.board)
                    } label: {
                        Label("Board", systemImage: "rectangle.3.group")
                    }
                    .disabled(workspace.state.lastSelectedView == .board)
                    .help("Show parent tasks in independent workflow columns.")
                    .accessibilityIdentifier("cove.workspace.board")
                }
                .controlGroupStyle(.navigation)
                .accessibilityLabel("Workspace view")
                .accessibilityIdentifier("cove.workspace.view")
            }

            ToolbarItemGroup {
                Picker("Appearance", selection: workspaceAppearanceBinding) {
                    ForEach(CoveWorkspaceAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .frame(width: 140)
                .help("Follow the macOS appearance or force Light or Dark for this Workspace window.")
                .accessibilityIdentifier("cove.workspace.appearance")

                Picker("Sort", selection: $workspace.sort) {
                    ForEach(CoveWorkspaceSort.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                            .disabled(
                                redactsSensitiveContent
                                    && (value == .name || value == .source)
                            )
                    }
                }
                .frame(width: 150)
                .help(
                    workspace.sort == .manual
                        ? "Manual order can be changed only with no active search or filter."
                        : "Choose how the current Workspace projection is ordered."
                )
                .accessibilityIdentifier("cove.workspace.sort")

                Menu {
                    Toggle("Needs attention", isOn: $workspace.filter.attentionOnly)
                    Toggle("Unread", isOn: $workspace.filter.unreadOnly)
                    Toggle("Pinned", isOn: $workspace.filter.pinnedOnly)
                    Toggle("Controllable here", isOn: $workspace.filter.controllableOnly)
                    Divider()
                    Menu("Status") {
                        ForEach(CoveSessionStatus.allCases, id: \.self) { status in
                            Toggle(
                                status.displayName,
                                isOn: statusFilterBinding(status)
                            )
                        }
                    }
                    Menu("Source") {
                        ForEach(CoveWireSource.allCases, id: \.self) { source in
                            Toggle(
                                source.displayName,
                                isOn: sourceFilterBinding(source)
                            )
                        }
                    }
                    if !redactsSensitiveContent, !availableHosts.isEmpty {
                        Menu("Host") {
                            ForEach(availableHosts, id: \.self) { host in
                                Toggle(host, isOn: hostFilterBinding(host))
                            }
                        }
                    }
                    if !redactsSensitiveContent, !availableTags.isEmpty {
                        Menu("Tag") {
                            ForEach(availableTags, id: \.self) { tag in
                                Toggle(tag, isOn: tagFilterBinding(tag))
                            }
                        }
                    }
                    Menu("Column") {
                        ForEach(workspace.state.columns) { column in
                            let index = workspace.state.columns.firstIndex {
                                $0.id == column.id
                            } ?? 0
                            Toggle(
                                redactsSensitiveContent
                                    ? "Workflow column \(index + 1)"
                                    : column.name,
                                isOn: columnFilterBinding(column.id)
                            )
                        }
                    }
                    if !workspace.filter.isEmpty {
                        Divider()
                        Button("Clear Filters") { workspace.filter = .init() }
                    }
                } label: {
                    Label("Filters", systemImage: workspace.filter.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter by attention, status, origin, tags, workflow, unread, pin, or controllability.")
                .accessibilityIdentifier("cove.workspace.filters")

                Button {
                    showsPromptLibrary = true
                } label: {
                    Label("Prompt Library", systemImage: "text.book.closed")
                }
                .help("Manage saved templates or copy one into the selected task's composer.")
                .accessibilityIdentifier("cove.workspace.prompt-library")
                .disabled(redactsSensitiveContent)

                if workspace.state.lastSelectedView == .board {
                    Button {
                        showsColumnManager = true
                    } label: {
                        Label("Columns", systemImage: "rectangle.3.group.bubble")
                    }
                    .help("Add, rename, reorder, or delete Board workflow columns.")
                    .accessibilityIdentifier("cove.workspace.columns")
                    .disabled(redactsSensitiveContent)
                }

                Button(action: onClose) {
                    Label("Close Workspace", systemImage: "xmark")
                }
                .help("Close Workspace and return Cove to menu-bar accessory mode.")
                .accessibilityIdentifier("cove.workspace.close")

                CoveHelpLink(
                    "Workspace",
                    destination: CoveHelp.workspaceURL,
                    accessibilityIdentifier: "cove.workspace.help"
                )
            }
        }
        .preferredColorScheme(workspaceColorScheme)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let privacyRedactionExplanation {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                        Text(privacyRedactionExplanation)
                            .font(.callout)
                        Spacer()
                        CoveHelpLink(
                            "Workspace privacy",
                            destination: CoveHelp.settingsURL(
                                anchor: "privacy-and-quiet"
                            ),
                            accessibilityIdentifier: "cove.workspace.privacy-help"
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityIdentifier("cove.workspace.privacy-reason")
            }
        }
        .sheet(isPresented: $showsPromptLibrary) {
            CovePromptLibraryView(
                workspace: workspace,
                redactsSensitiveContent: redactsSensitiveContent
            )
                .frame(minWidth: 620, minHeight: 520)
        }
        .sheet(isPresented: $showsColumnManager) {
            CoveColumnManagerView(
                workspace: workspace,
                redactsSensitiveContent: redactsSensitiveContent
            )
                .frame(minWidth: 480, minHeight: 420)
        }
        .overlay(alignment: .bottom) {
            if let message = workspace.message {
                HStack {
                    Text(message)
                    Button("Dismiss") { workspace.clearMessage() }
                }
                .padding(10)
                .background(.regularMaterial, in: Capsule())
                .padding()
                .accessibilityIdentifier("cove.workspace.message")
            }
        }
        .onAppear {
            enforcePrivacyStateIfNeeded()
            workspace.reconcileMembership(with: store.state.session.snapshots)
            workspace.onReconcileRequested?()
            workspace.refreshSelectedControlTarget()
        }
        .onChange(of: store.state.session.snapshots) { _, snapshots in
            workspace.reconcileMembership(with: snapshots)
        }
        .onChange(of: redactsSensitiveContent) { _, redacts in
            guard redacts else { return }
            enforcePrivacyStateIfNeeded()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.workspace")
    }

    private var grid: some View {
        ScrollView {
            if visibleCardItems.isEmpty {
                ContentUnavailableView(
                    "No matching tasks",
                    systemImage: "rectangle.stack",
                    description: Text("Loaded Desktop and live Cove tasks appear here automatically.")
                )
                .padding(.top, 100)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(visibleCardItems) { item in
                        gridCard(item)
                    }
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func gridCard(_ item: CoveWorkspaceItem) -> some View {
        let card = CoveWorkspaceCard(
            item: item,
            redactsSensitiveContent: redactsSensitiveContent,
            isSelected: selectedRootIdentity == item.identity,
            onSelect: { workspace.select(item.identity) }
        )
        .contextMenu { cardMenu(item) }
        .dropDestination(for: String.self) { values, _ in
            guard canManuallyReorder,
                  let source = values.first.flatMap(identity(withKey:))
            else { return false }
            moveWithUndo(source, before: item.identity)
            return true
        }
        if canManuallyReorder {
            card.draggable(item.identity.id)
        } else {
            card
        }
    }

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(
                    Array(workspace.state.columns.enumerated()),
                    id: \.element.id
                ) { entry in
                    CoveWorkspaceBoardColumn(
                        column: entry.element,
                        columnIndex: entry.offset,
                        items: items(in: entry.element.id),
                        selectedRootIdentity: selectedRootIdentity,
                        redactsSensitiveContent: redactsSensitiveContent,
                        store: store,
                        workspace: workspace
                    )
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func cardMenu(_ item: CoveWorkspaceItem) -> some View {
        Button("Open in Codex") { store.open(item.snapshot) }
        Button(item.isPinned ? "Unpin" : "Pin") {
            store.togglePinned(item.snapshot)
        }
        Menu("Move to Column") {
            ForEach(
                Array(workspace.state.columns.enumerated()),
                id: \.element.id
            ) { index, column in
                Button(
                    redactsSensitiveContent
                        ? "Workflow column \(index + 1)"
                        : column.name
                ) {
                    workspace.assign(item.identity, to: column.id)
                }
                .disabled(item.columnID == column.id)
            }
        }
        if canManuallyReorder {
            Divider()
            Button("Move Earlier") { moveWithUndo(item.identity, offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Move Later") { moveWithUndo(item.identity, offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
        }
        let templates = Array(workspace.favoriteAndRecentTemplates.prefix(8))
        if !redactsSensitiveContent, !templates.isEmpty {
            Divider()
            Menu("Use Prompt") {
                ForEach(templates) { template in
                    Button(template.name) {
                        workspace.select(item.identity)
                        workspace.useTemplate(template)
                    }
                }
            }
        }
    }

    private func moveWithUndo(
        _ identity: CoveSessionIdentity,
        offset: Int
    ) {
        let previous = workspace.state.gridOrder
        workspace.move(identity, relativeOffset: offset)
        registerGridUndo(previous)
    }

    private func moveWithUndo(
        _ identity: CoveSessionIdentity,
        before destination: CoveSessionIdentity
    ) {
        let previous = workspace.state.gridOrder
        workspace.move(identity, before: destination)
        registerGridUndo(previous)
    }

    private func registerGridUndo(_ previous: [CoveSessionIdentity]) {
        guard previous != workspace.state.gridOrder else { return }
        undoManager?.registerUndo(withTarget: workspace) { target in
            let inverse = target.state.gridOrder
            target.restoreGridOrder(previous)
            registerGridUndo(inverse)
        }
        undoManager?.setActionName("Reorder Workspace")
    }

    private var canManuallyReorder: Bool {
        workspace.sort == .manual
            && workspace.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && workspace.filter.isEmpty
    }

    private var unfilteredProjection: CoveWorkspaceProjection {
        CoveWorkspaceProjection(
            snapshots: store.state.session.snapshots,
            workspace: workspace.state,
            pinnedIdentities: Set(
                store.state.session.snapshots.compactMap { snapshot in
                    guard let identity = snapshot.sessionIdentity else {
                        return nil
                    }
                    return store.state.pinnedSessionIDs.contains(identity.id)
                        ? identity : nil
                }
            ),
            dismissedIdentities: Set(
                workspace.state.gridOrder.filter {
                    store.state.dismissedSessionIDs.contains($0.id)
                }
            ),
            redactSensitiveContent: redactsSensitiveContent
        )
    }

    private var selectedRootIdentity: CoveSessionIdentity? {
        workspace.selectedIdentity.flatMap {
            unfilteredProjection.owningTaskIdentity(for: $0) ?? $0
        }
    }

    private func unfilteredItem(_ identity: CoveSessionIdentity) -> CoveWorkspaceItem? {
        unfilteredProjection.item(identity)
    }

    private func identity(withKey key: String) -> CoveSessionIdentity? {
        workspace.state.gridOrder.first {
            $0.id == key
        }
    }

    private var availableHosts: [String] {
        Array(Set(unfilteredProjection.items.compactMap {
            $0.identity.remoteHostId
        })).sorted()
    }

    private var availableTags: [String] {
        Array(Set(unfilteredProjection.items.flatMap(\.tags))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func statusFilterBinding(_ value: CoveSessionStatus) -> Binding<Bool> {
        filterBinding(value, keyPath: \.statuses)
    }

    private var workspaceAppearanceBinding: Binding<CoveWorkspaceAppearance> {
        Binding(
            get: { store.state.settings.workspaceAppearance },
            set: { store.dispatch(.setWorkspaceAppearance($0)) }
        )
    }

    private var workspaceColorScheme: ColorScheme? {
        switch store.state.settings.workspaceAppearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private func sourceFilterBinding(_ value: CoveWireSource) -> Binding<Bool> {
        filterBinding(value, keyPath: \.sources)
    }

    private func hostFilterBinding(_ value: String) -> Binding<Bool> {
        filterBinding(value, keyPath: \.hosts)
    }

    private func tagFilterBinding(_ value: String) -> Binding<Bool> {
        filterBinding(value, keyPath: \.tags)
    }

    private func columnFilterBinding(_ value: String) -> Binding<Bool> {
        filterBinding(value, keyPath: \.columns)
    }

    private func filterBinding<Value: Hashable>(
        _ value: Value,
        keyPath: WritableKeyPath<CoveWorkspaceFilter, Set<Value>>
    ) -> Binding<Bool> {
        Binding(
            get: { workspace.filter[keyPath: keyPath].contains(value) },
            set: { enabled in
                var filter = workspace.filter
                if enabled {
                    filter[keyPath: keyPath].insert(value)
                } else {
                    filter[keyPath: keyPath].remove(value)
                }
                workspace.filter = filter
            }
        )
    }

    private func itemCount(in columnID: String) -> Int {
        visibleCardItems.reduce(into: 0) { count, item in
            if item.columnID == columnID { count += 1 }
        }
    }

    private func items(in columnID: String) -> [CoveWorkspaceItem] {
        visibleCardItems.filter { $0.columnID == columnID }
    }

    /// Parent tasks own cards. Authoritatively attached agents remain in the
    /// inspector hierarchy; a search that hides their parent can still promote
    /// the matching descendant to a temporary result card.
    private var visibleCardItems: [CoveWorkspaceItem] {
        projection.roots.compactMap(projection.item)
    }

    private func enforcePrivacyStateIfNeeded() {
        guard redactsSensitiveContent else { return }
        workspace.query = ""
        workspace.filter.sources.removeAll()
        workspace.filter.hosts.removeAll()
        workspace.filter.tags.removeAll()
        workspace.filter.columns.removeAll()
        if workspace.sort == .name || workspace.sort == .source {
            workspace.sort = .manual
        }
        showsPromptLibrary = false
        showsColumnManager = false
        workspace.clearArtifactSuggestions()
        workspace.clearMessage()
    }
}

private struct CoveWorkspaceCard: View {
    let item: CoveWorkspaceItem
    let redactsSensitiveContent: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            cardContent
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : Color(nsColor: .separatorColor).opacity(0.5),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Open the task inspector without marking this task read.")
        .accessibilityLabel(
            redactsSensitiveContent
                ? "Codex task, \(item.snapshot.status.displayName)"
                : "\(item.displayName), \(item.snapshot.status.displayName), \(item.identity.source.displayName)"
        )
        .accessibilityHint("Opens the task inspector without marking it read")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier(
            redactsSensitiveContent
                ? "cove.workspace.card.redacted"
                : "cove.workspace.card.\(item.identity.id)"
        )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
            statusRow
            CoveWorkspaceOriginRow(
                item: item,
                redactsSensitiveContent: redactsSensitiveContent
            )
            if showsBadges {
                CoveWorkspaceBadges(tags: item.tags, links: item.links)
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .top) {
            Text(redactsSensitiveContent ? "Codex task" : item.displayName)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if item.isPinned { Image(systemName: "pin.fill") }
            if item.snapshot.unread {
                Circle().fill(.blue).frame(width: 8, height: 8)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 7) {
            Label(
                item.isRetainedOnly ? "Retained" : item.snapshot.status.displayName,
                systemImage: item.isRetainedOnly ? "archivebox" : item.snapshot.status.workspaceIcon
            )
            .foregroundStyle(item.isRetainedOnly ? .secondary : item.snapshot.status.workspaceColor)
            Spacer()
            if !item.isRetainedOnly {
                Text(item.snapshot.timestamp, style: .relative)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var showsBadges: Bool {
        !redactsSensitiveContent && (!item.tags.isEmpty || !item.links.isEmpty)
    }
}

private struct CoveWorkspaceOriginRow: View {
    let item: CoveWorkspaceItem
    let redactsSensitiveContent: Bool

    var body: some View {
        HStack(spacing: 6) {
            if redactsSensitiveContent {
                Text("Origin hidden")
            } else {
                Text(item.identity.source.displayName)
                if let host = item.identity.remoteHostId {
                    Text("· " + host)
                }
            }
            Spacer()
            if item.descendantAttentionCount > 0 {
                Image(systemName: "person.2.badge.exclamationmark")
                Text(countText)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var countText: String {
        String(item.descendantAttentionCount)
    }
}

private struct CoveWorkspaceBoardColumn: View {
    let column: CoveWorkspaceColumn
    let columnIndex: Int
    let items: [CoveWorkspaceItem]
    let selectedRootIdentity: CoveSessionIdentity?
    let redactsSensitiveContent: Bool
    @ObservedObject var store: CoveStore
    @ObservedObject var workspace: CoveWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(redactsSensitiveContent ? "Workflow column" : column.name)
                    .font(.headline)
                Spacer()
                Text(String(items.count)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        CoveWorkspaceCard(
                            item: item,
                            redactsSensitiveContent: redactsSensitiveContent,
                            isSelected: selectedRootIdentity == item.identity,
                            onSelect: { workspace.select(item.identity) }
                        )
                        .contextMenu {
                            Button("Open in Codex") { store.open(item.snapshot) }
                            Button(item.isPinned ? "Unpin" : "Pin") {
                                store.togglePinned(item.snapshot)
                            }
                            Menu("Move to Column") {
                                ForEach(
                                    Array(workspace.state.columns.enumerated()),
                                    id: \.element.id
                                ) { index, destination in
                                    Button(
                                        redactsSensitiveContent
                                            ? "Workflow column \(index + 1)"
                                            : destination.name
                                    ) {
                                        workspace.assign(item.identity, to: destination.id)
                                    }
                                    .disabled(item.columnID == destination.id)
                                }
                            }
                            let templates = Array(workspace.favoriteAndRecentTemplates.prefix(8))
                            if !redactsSensitiveContent, !templates.isEmpty {
                                Menu("Use Prompt") {
                                    ForEach(templates) { template in
                                        Button(template.name) {
                                            workspace.select(item.identity)
                                            workspace.useTemplate(template)
                                        }
                                    }
                                }
                            }
                        }
                        .draggable(item.identity.id)
                        .help("Open the inspector, or drag this card to another workflow column.")
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: String.self) { values, _ in
            guard let key = values.first,
                  let identity = workspace.state.gridOrder.first(where: {
                      $0.id == key
                  }) else { return false }
            workspace.assign(identity, to: column.id)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            redactsSensitiveContent
                ? "Workflow column \(columnIndex + 1)"
                : "\(column.name) column"
        )
    }
}

private struct CoveWorkspaceBadges: View {
    let tags: [String]
    let links: [CoveWorkspaceLink]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            ForEach(Array(links.prefix(3))) { link in
                CoveFaviconView(
                    artifactURL: link.url,
                    fallbackSystemImage: link.url.isFileURL ? "doc" : "link",
                    presentationContext: "card"
                )
                    .frame(width: 14, height: 14)
                    .help(link.label)
            }
        }
    }
}

private struct CoveWorkspaceInspector: View {
    let item: CoveWorkspaceItem
    let projection: CoveWorkspaceProjection
    @ObservedObject var store: CoveStore
    @ObservedObject var workspace: CoveWorkspaceStore
    let undoManager: UndoManager?
    let redactsSensitiveContent: Bool

    @State private var tagsText = ""
    @State private var linkLabel = ""
    @State private var linkURL = ""
    @State private var preparedSend: CoveWorkspaceStore.PreparedThreadControl?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Task Inspector").font(.headline)
                Spacer()
                Button { workspace.select(nil) } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Close inspector")
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    hierarchy
                    ForEach(pendingRequests, id: \.key) { request in
                        CoveFocusedDirectRequestView(
                            request: request,
                            matchingSnapshot: request.sessionIdentity.flatMap {
                                projection.item($0)?.snapshot
                            }
                                ?? item.snapshot,
                            theme: store.state.theme,
                            redactsSensitiveContent: redactsSensitiveContent
                        )
                        .environmentObject(store)
                    }
                    metadataEditor
                    artifactShelf
                    composer
                    actions
                }
                .padding()
            }
        }
        .onAppear {
            tagsText = item.tags.joined(separator: ", ")
            refreshArtifactSuggestions()
        }
        .onChange(of: item.identity) { _, _ in
            tagsText = item.tags.joined(separator: ", ")
            linkLabel = ""
            linkURL = ""
            preparedSend = nil
            refreshArtifactSuggestions()
        }
        .onChange(of: redactsSensitiveContent) { _, redacts in
            if redacts {
                preparedSend = nil
                workspace.clearArtifactSuggestions()
                workspace.clearMessage()
            } else {
                refreshArtifactSuggestions()
            }
        }
        .onChange(of: projection.items) { _, _ in refreshArtifactSuggestions() }
        .confirmationDialog(
            redactsSensitiveContent
                ? "Send this prompt?"
                : "Send this prompt to \(item.displayName)?",
            isPresented: Binding(
                get: { preparedSend != nil },
                set: { if !$0 { preparedSend = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Send") { confirmPreparedSend() }
                .accessibilityIdentifier("cove.workspace.confirm-send")
            Button("Cancel", role: .cancel) { preparedSend = nil }
        } message: {
            Text("Cove will send it once and will not retry automatically if delivery is uncertain.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.workspace.inspector")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(redactsSensitiveContent ? "Codex task" : item.displayName)
                .font(.title2.weight(.semibold))
            Label(
                item.isRetainedOnly ? "Retained" : item.snapshot.status.displayName,
                systemImage: item.isRetainedOnly ? "archivebox" : item.snapshot.status.workspaceIcon
            )
            .foregroundStyle(item.isRetainedOnly ? .secondary : item.snapshot.status.workspaceColor)
            Text(
                redactsSensitiveContent
                    ? "Origin hidden"
                    : [item.identity.source.displayName, item.identity.remoteHostId]
                        .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.caption).foregroundStyle(.secondary)
            if redactsSensitiveContent {
                Text("Sensitive task details are hidden by Cove privacy protection.")
                    .foregroundStyle(.secondary)
            } else if item.isRetainedOnly {
                Text("This task is retained locally and is not currently observed by Codex.")
                    .foregroundStyle(.secondary)
            } else if let output = item.snapshot.latestOutput, !output.isEmpty {
                Text(output).textSelection(.enabled)
            }
        }
    }

    private var hierarchy: some View {
        GroupBox("Agents") {
            VStack(alignment: .leading, spacing: 6) {
                CoveWorkspaceHierarchyNode(
                    identity: owningTaskIdentity,
                    projection: projection,
                    store: store,
                    workspace: workspace,
                    redactsSensitiveContent: redactsSensitiveContent
                )
                let unattached = projection.unattachedAgents.filter {
                    $0 != owningTaskIdentity
                }
                if !unattached.isEmpty {
                    DisclosureGroup("Unattached agents") {
                        ForEach(unattached) { identity in
                            CoveWorkspaceHierarchyNode(
                                identity: identity,
                                projection: projection,
                                store: store,
                                workspace: workspace,
                                redactsSensitiveContent: redactsSensitiveContent
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadataEditor: some View {
        if !redactsSensitiveContent {
            GroupBox("Workspace Details") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "Cove alias",
                        text: Binding(
                            get: { workspace.state.card(for: item.identity)?.alias ?? "" },
                            set: { workspace.setAlias($0, for: item.identity) }
                        )
                    )
                    .help("Set a Cove-only name. The upstream Codex task title is unchanged.")
                    .accessibilityIdentifier("cove.workspace.alias")
                    TextField("Tags separated by commas", text: $tagsText)
                        .help("Press Return to save up to 32 Cove-only tags.")
                        .accessibilityIdentifier("cove.workspace.tags")
                        .onSubmit {
                            workspace.setTags(tagsText.split(separator: ",").map(String.init), for: item.identity)
                        }
                    Picker(
                        "Board column",
                        selection: Binding(
                            get: { workspace.state.columnID(for: owningTaskIdentity) },
                            set: { workspace.assign(owningTaskIdentity, to: $0) }
                        )
                    ) {
                        ForEach(workspace.state.columns) { column in
                            Text(column.name).tag(column.id)
                        }
                    }
                    .help("Move this card without changing the task's live Codex status.")
                    .accessibilityIdentifier("cove.workspace.assignment")
                }
            }
        }
    }

    @ViewBuilder
    private var artifactShelf: some View {
        if !redactsSensitiveContent {
            GroupBox("Artifacts") {
                VStack(alignment: .leading, spacing: 10) {
                    if artifacts.isEmpty {
                        Text("Attach a web link, local plan, file, or folder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(artifacts.enumerated()), id: \.element.id) {
                        index, artifact in
                        CoveWorkspaceArtifactRow(
                            artifact: artifact,
                            canMoveEarlier: index > 0,
                            canMoveLater: index + 1 < artifacts.count,
                            destination: artifactDestination(artifact.link.url),
                            onRename: { workspace.renameArtifact(artifact, label: $0) },
                            onMoveEarlier: { moveArtifact(artifact, offset: -1) },
                            onMoveLater: { moveArtifact(artifact, offset: 1) },
                            onOpen: { workspace.openArtifact(artifact) },
                            onRemove: { workspace.removeArtifact(artifact) }
                        )
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { values, _ in
                            guard let sourceID = values.first,
                                  let source = artifacts.first(where: {
                                      $0.id == sourceID
                                  })
                            else { return false }
                            moveArtifact(source, droppingOn: artifact)
                            return true
                        }
                    }
                    if !workspace.artifactSuggestions.isEmpty {
                        Divider()
                        Text("Suggested from live agent output")
                            .font(.caption.weight(.semibold))
                        ForEach(workspace.artifactSuggestions) { suggestion in
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.link.url.isFileURL ? "doc.badge.plus" : "link.badge.plus")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.link.label)
                                    Text(artifactDestination(suggestion.link.url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Add") {
                                    workspace.addArtifact(
                                        label: suggestion.link.label,
                                        url: suggestion.link.url,
                                        to: owningTaskIdentity,
                                        requireExistingLocalFile: suggestion.link.url.isFileURL
                                    )
                                    refreshArtifactSuggestions()
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("Artifact label", text: $linkLabel)
                            .accessibilityIdentifier("cove.workspace.link-label")
                        TextField("https://…", text: $linkURL)
                            .accessibilityIdentifier("cove.workspace.link-url")
                        Button("Add Link") { addLink() }
                            .disabled(candidateLinkURL == nil)
                            .accessibilityIdentifier("cove.workspace.link-add")
                        Button("Add File or Folder…") { addFilesAndDirectories() }
                            .accessibilityIdentifier("cove.workspace.artifact.choose")
                    }
                }
            }
        }
    }

    private var composer: some View {
        GroupBox(redactsSensitiveContent ? "Prompt" : "Prompt · \(item.displayName)") {
            if redactsSensitiveContent {
                Text("Prompt drafts and templates are hidden by Cove privacy protection.")
                    .foregroundStyle(.secondary)
            } else if item.isRetainedOnly {
                Text("This retained task cannot receive a prompt until Codex observes it again.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $workspace.composerText)
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .help("This draft remains in memory and is cleared when you select another task.")
                        .accessibilityIdentifier("cove.workspace.composer")
                    HStack {
                        Menu("Insert Template") {
                            ForEach(workspace.favoriteAndRecentTemplates) { template in
                                Button(template.name) { workspace.useTemplate(template) }
                            }
                        }
                        .help("Copy a saved template into the editable composer.")
                        Spacer()
                        Button(promptTarget.activeTurnId == nil ? "Start Turn" : "Steer Active Turn") {
                            preparedSend = workspace.prepareSend(
                                to: promptTarget,
                                pendingRequests: store.state.pendingDirectRequests
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !workspace.canPrepareSend(
                                to: promptTarget,
                                pendingRequests: store.state.pendingDirectRequests
                            )
                        )
                        .help("Preview a one-time start or exact-turn steer. Delivery is never retried automatically.")
                        .accessibilityIdentifier("cove.workspace.send")
                    }
                    if workspace.refreshingControlIdentity == item.identity {
                        Text("Checking current agent state…")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("cove.workspace.control-refresh")
                    } else if store.state.pendingDirectRequests.contains(where: {
                        $0.sessionIdentity == item.identity
                    }) {
                        Text("Resolve this agent's approval or question before sending a prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if promptTarget.controlRoute == nil {
                        Text("Prompting is unavailable for this route. Open the exact task in Codex.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if promptTarget.status == .waitingApproval
                        || promptTarget.status == .waitingInput {
                        Text("Resolve this agent's pending approval or question before sending a prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !promptTarget.canAcceptThreadControl {
                        Text("Cove does not have the exact active turn ID. Open the task in Codex to continue.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if promptTarget.controlRoute == .localAppServer {
                        Text("Cove will verify and resume this local task with Codex before starting the turn.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Open in Codex") { store.open(item.snapshot) }
                    .buttonStyle(.borderedProminent)
                    .help("Open this exact task at its originating Codex location.")
                Button(item.isPinned ? "Unpin" : "Pin") { store.togglePinned(item.snapshot) }
                    .help("Keep or remove this task at the front of Cove's queue ordering.")
                Button("Mark Read") { store.markRead(item.snapshot) }
                    .disabled(item.isRetainedOnly || !item.snapshot.unread)
                    .help("Acknowledge this task without opening it.")
                Menu("More") {
                    Button("Remind Me") { store.scheduleFollowUp(item.snapshot) }
                        .disabled(item.isRetainedOnly)
                    Button("Archive", role: .destructive) { store.dismiss(item.snapshot) }
                }
            }
            if let failure = store.sessionOpenFailureMessage(for: item.snapshot) {
                CoveSessionOpenFailureView(
                    message: failure,
                    theme: store.state.theme,
                    redactsSensitiveContent: redactsSensitiveContent
                )
                if let parent = nearestOpenableParent {
                    Button("Open Parent Location") {
                        store.open(parent.snapshot, reportingFor: item.snapshot)
                    }
                        .help("Open the nearest authoritative same-origin parent location. This does not open the selected agent itself.")
                        .accessibilityIdentifier("cove.workspace.open-parent")
                }
            }
        }
    }

    private var pendingRequests: [CoveDirectRequest] {
        let identities = Set(descendantIdentities)
        return store.state.pendingDirectRequests.filter {
            $0.sessionIdentity.map(identities.contains) == true
        }.sorted {
            ($0.sessionIdentity == workspace.attentionIdentity ? 0 : 1)
                < ($1.sessionIdentity == workspace.attentionIdentity ? 0 : 1)
        }
    }

    private var promptTarget: CoveSessionSnapshot {
        workspace.promptTarget(for: item.snapshot)
    }

    private var owningTaskIdentity: CoveSessionIdentity {
        projection.owningTaskIdentity(for: item.identity) ?? item.identity
    }

    private var nearestOpenableParent: CoveWorkspaceItem? {
        guard item.identity != owningTaskIdentity else { return nil }
        var parentID = item.snapshot.parentSessionId
        var visited = Set<CoveSessionIdentity>()
        while let sessionID = parentID,
              let identity = CoveSessionIdentity(
                  source: item.identity.source,
                  hostId: item.identity.remoteHostId,
                  sessionId: sessionID
              ),
              visited.insert(identity).inserted,
              let parent = projection.item(identity) {
            if store.canOpen(parent.snapshot) {
                return parent
            }
            parentID = parent.snapshot.parentSessionId
        }
        return nil
    }

    private func addLink() {
        guard let url = candidateLinkURL else { return }
        workspace.addArtifact(
            label: linkLabel,
            url: url,
            to: owningTaskIdentity
        )
        linkLabel = ""
        linkURL = ""
        refreshArtifactSuggestions()
    }

    private var candidateLinkURL: URL? {
        guard let url = URL(string: linkURL),
              let canonical = CoveWorkspaceArtifactPolicy.canonicalPersistentURL(url),
              !canonical.isFileURL,
              !linkLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              linkLabel.utf8.count <= CoveWorkspaceLimits.linkLabelBytes,
              (workspace.state.card(for: owningTaskIdentity)?.links.count ?? 0)
                < CoveWorkspaceLimits.linksPerCard
        else { return nil }
        return canonical
    }

    private var artifacts: [CoveWorkspaceStore.ArtifactReference] {
        workspace.artifacts(for: item.identity, projection: projection)
    }

    private var descendantIdentities: [CoveSessionIdentity] {
        var result = [owningTaskIdentity]
        var index = 0
        while index < result.count {
            for child in projection.item(result[index])?.children ?? [] where !result.contains(child) {
                result.append(child)
            }
            index += 1
        }
        return result
    }

    private func refreshArtifactSuggestions() {
        guard !redactsSensitiveContent else { return }
        workspace.refreshArtifactSuggestions(for: item.identity, projection: projection)
    }

    private func addFilesAndDirectories() {
        for url in CoveWorkspaceArtifactPanels.chooseFilesAndDirectories() {
            workspace.addArtifact(
                label: url.lastPathComponent,
                url: url,
                to: owningTaskIdentity,
                requireExistingLocalFile: true
            )
        }
        refreshArtifactSuggestions()
    }

    private func artifactDestination(_ url: URL) -> String {
        url.isFileURL ? url.path : (url.host ?? url.absoluteString)
    }

    private func moveArtifact(
        _ artifact: CoveWorkspaceStore.ArtifactReference,
        offset: Int
    ) {
        guard let index = artifacts.firstIndex(where: { $0.id == artifact.id }) else {
            return
        }
        let destination = min(max(0, index + offset), artifacts.count - 1)
        guard destination != index else { return }
        let previous = workspace.artifactOrder
        if offset < 0 {
            workspace.moveArtifact(artifact, before: artifacts[destination])
        } else {
            workspace.moveArtifact(artifact, after: artifacts[destination])
        }
        registerArtifactUndo(previous)
    }

    private func moveArtifact(
        _ artifact: CoveWorkspaceStore.ArtifactReference,
        before destination: CoveWorkspaceStore.ArtifactReference
    ) {
        let previous = workspace.artifactOrder
        workspace.moveArtifact(artifact, before: destination)
        registerArtifactUndo(previous)
    }

    private func moveArtifact(
        _ artifact: CoveWorkspaceStore.ArtifactReference,
        droppingOn destination: CoveWorkspaceStore.ArtifactReference
    ) {
        guard let sourceIndex = artifacts.firstIndex(where: {
            $0.id == artifact.id
        }), let destinationIndex = artifacts.firstIndex(where: {
            $0.id == destination.id
        }), sourceIndex != destinationIndex else { return }
        let previous = workspace.artifactOrder
        if sourceIndex < destinationIndex {
            workspace.moveArtifact(artifact, after: destination)
        } else {
            workspace.moveArtifact(artifact, before: destination)
        }
        registerArtifactUndo(previous)
    }

    private func registerArtifactUndo(
        _ previous: [CoveWorkspaceStore.ArtifactReference]
    ) {
        guard previous != workspace.artifactOrder else { return }
        undoManager?.registerUndo(withTarget: workspace) { target in
            let inverse = target.artifactOrder
            target.restoreArtifactOrder(previous)
            registerArtifactUndo(inverse)
        }
        undoManager?.setActionName("Reorder Artifacts")
    }

    private func confirmPreparedSend() {
        guard let preparedSend else { return }
        self.preparedSend = nil
        workspace.confirmSend(
            preparedSend,
            currentSnapshots: store.state.session.snapshots,
            pendingRequests: store.state.pendingDirectRequests
        )
    }
}

private struct CoveWorkspaceArtifactRow: View {
    let artifact: CoveWorkspaceStore.ArtifactReference
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let destination: String
    let onRename: (String) -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var draftLabel: String
    @FocusState private var labelIsFocused: Bool

    init(
        artifact: CoveWorkspaceStore.ArtifactReference,
        canMoveEarlier: Bool,
        canMoveLater: Bool,
        destination: String,
        onRename: @escaping (String) -> Void,
        onMoveEarlier: @escaping () -> Void,
        onMoveLater: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.artifact = artifact
        self.canMoveEarlier = canMoveEarlier
        self.canMoveLater = canMoveLater
        self.destination = destination
        self.onRename = onRename
        self.onMoveEarlier = onMoveEarlier
        self.onMoveLater = onMoveLater
        self.onOpen = onOpen
        self.onRemove = onRemove
        _draftLabel = State(initialValue: artifact.link.label)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 18)
                .draggable(artifact.id)
                .accessibilityHidden(true)
            CoveFaviconView(
                artifactURL: artifact.link.url,
                fallbackSystemImage: artifact.link.url.isFileURL ? "doc" : "link",
                presentationContext: "row"
            )
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Artifact label", text: $draftLabel)
                    .focused($labelIsFocused)
                    .onSubmit(commitLabel)
                    .onExitCommand {
                        draftLabel = artifact.link.label
                        labelIsFocused = false
                    }
                    .accessibilityIdentifier(
                        "cove.workspace.artifact.label.\(artifact.id)"
                    )
                Text(destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Move Earlier", action: onMoveEarlier)
                    .disabled(!canMoveEarlier)
                Button("Move Later", action: onMoveLater)
                    .disabled(!canMoveLater)
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .menuStyle(.borderlessButton)
            .help("Reorder this artifact.")
            .accessibilityLabel("Reorder \(artifact.link.label)")
            .accessibilityIdentifier(
                "cove.workspace.artifact.reorder.\(artifact.id)"
            )
            Button("Open", action: onOpen)
                .accessibilityIdentifier("cove.workspace.artifact.open.\(artifact.id)")
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .accessibilityIdentifier("cove.workspace.artifact.remove.\(artifact.id)")
        }
        .onChange(of: labelIsFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused { commitLabel() }
        }
        .onChange(of: artifact.link.label) { _, label in
            if !labelIsFocused { draftLabel = label }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.workspace.artifact.row.\(artifact.id)")
    }

    private func commitLabel() {
        let normalized = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= CoveWorkspaceLimits.linkLabelBytes
        else {
            onRename(draftLabel)
            draftLabel = artifact.link.label
            return
        }
        guard normalized != artifact.link.label else {
            draftLabel = normalized
            return
        }
        onRename(normalized)
        draftLabel = normalized
    }
}

private struct CoveWorkspaceHierarchyNode: View {
    let identity: CoveSessionIdentity
    let projection: CoveWorkspaceProjection
    @ObservedObject var store: CoveStore
    @ObservedObject var workspace: CoveWorkspaceStore
    let redactsSensitiveContent: Bool

    @State private var isExpanded = false

    var body: some View {
        if let item = projection.item(identity) {
            if item.children.isEmpty {
                row(item)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Button { isExpanded.toggle() } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            redactsSensitiveContent
                                ? (isExpanded ? "Collapse child agents" : "Expand child agents")
                                : (isExpanded
                                    ? "Collapse child agents for \(item.displayName)"
                                    : "Expand child agents for \(item.displayName)")
                        )
                        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                        .accessibilityIdentifier(
                            redactsSensitiveContent
                                ? "cove.workspace.agent.disclosure.redacted"
                                : "cove.workspace.agent.disclosure.\(item.identity.id)"
                        )
                        row(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isExpanded {
                        ForEach(item.children) { child in
                            CoveWorkspaceHierarchyNode(
                                identity: child,
                                projection: projection,
                                store: store,
                                workspace: workspace,
                                redactsSensitiveContent: redactsSensitiveContent
                            )
                        }
                        .padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func row(_ item: CoveWorkspaceItem) -> some View {
        HStack {
            Button {
                workspace.select(item.identity)
            } label: {
                HStack {
                    Image(systemName: item.snapshot.status.workspaceIcon)
                        .foregroundStyle(item.snapshot.status.workspaceColor)
                    Text(redactsSensitiveContent ? "Codex agent" : item.displayName)
                        .lineLimit(1)
                    Text(item.snapshot.status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                redactsSensitiveContent
                    ? "Inspect Codex agent"
                    : "Inspect \(item.displayName)"
            )
            .accessibilityValue(
                workspace.selectedIdentity == item.identity ? "Selected" : ""
            )
            .accessibilityIdentifier(
                redactsSensitiveContent
                    ? "cove.workspace.agent.redacted"
                    : "cove.workspace.agent.\(item.identity.id)"
            )
            Spacer()
            Button {
                workspace.select(item.identity)
                store.open(item.snapshot)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help("Open this exact agent in Codex")
            .accessibilityLabel("Open agent in Codex")
        }
    }
}

private struct CovePromptLibraryView: View {
    @ObservedObject var workspace: CoveWorkspaceStore
    let redactsSensitiveContent: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var name = ""
    @State private var bodyText = ""
    @State private var favorite = false
    @State private var query = ""

    private var templates: [CovePromptTemplate] {
        workspace.state.promptTemplates
            .filter {
                query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.body.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.manualOrder < $1.manualOrder }
    }

    var body: some View {
        Group {
            if redactsSensitiveContent {
                ContentUnavailableView(
                    "Prompt Library Hidden",
                    systemImage: "eye.slash",
                    description: Text("Saved prompt content is hidden by Cove privacy protection.")
                )
            } else {
                libraryContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.workspace.prompt-library.sheet")
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Prompt Library").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("cove.workspace.template.done")
            }.padding()
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(templates) { template in
                        HStack {
                            Label(
                                template.name,
                                systemImage: template.favorite
                                    ? "star.fill" : "text.quote"
                            )
                            Spacer()
                            Button {
                                workspace.moveTemplate(id: template.id, offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .help("Move template earlier")
                            Button {
                                workspace.moveTemplate(id: template.id, offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .help("Move template later")
                        }
                        .tag(template.id)
                    }
                }
                .searchable(text: $query)
                .frame(minWidth: 220)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Template name", text: $name)
                        .accessibilityIdentifier("cove.workspace.template.name")
                    Toggle("Favorite", isOn: $favorite)
                        .help("Favorites appear first in card template menus.")
                        .accessibilityIdentifier("cove.workspace.template.favorite")
                    TextEditor(text: $bodyText)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .accessibilityIdentifier("cove.workspace.template.body")
                    HStack {
                        Button("Use in Composer") {
                            guard let selection,
                                  let template = workspace.state.promptTemplates
                                    .first(where: { $0.id == selection })
                            else { return }
                            workspace.useTemplate(template)
                            dismiss()
                        }
                        .disabled(selection == nil || workspace.selectedIdentity == nil)
                        .help("Copy this template into the selected task's editable composer.")
                        .accessibilityIdentifier("cove.workspace.template.use")
                        Button(selection == nil ? "Add Template" : "Save Changes") {
                            workspace.saveTemplate(
                                id: selection,
                                name: name,
                                body: bodyText,
                                favorite: favorite
                            )
                            clear()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.isEmpty || bodyText.isEmpty)
                        .help("Save only the template fields shown here.")
                        .accessibilityIdentifier("cove.workspace.template.save")
                        if let selection {
                            Button("Delete", role: .destructive) {
                                workspace.deleteTemplate(id: selection)
                                clear()
                            }
                            .help("Delete this saved template.")
                        }
                    }
                }
                .padding()
                .frame(minWidth: 340)
            }
        }
        .onChange(of: selection) { _, id in
            guard let template = workspace.state.promptTemplates.first(where: { $0.id == id }) else {
                return
            }
            name = template.name
            bodyText = template.body
            favorite = template.favorite
        }
    }

    private func clear() {
        selection = nil
        name = ""
        bodyText = ""
        favorite = false
    }
}

private struct CoveColumnManagerView: View {
    @ObservedObject var workspace: CoveWorkspaceStore
    let redactsSensitiveContent: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        Group {
            if redactsSensitiveContent {
                ContentUnavailableView(
                    "Columns Hidden",
                    systemImage: "eye.slash",
                    description: Text("Custom workflow names are hidden by Cove privacy protection.")
                )
            } else {
                columnContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.workspace.columns.sheet")
    }

    private var columnContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Board Columns").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("cove.workspace.columns.done")
            }.padding()
            Divider()
            List {
                ForEach(workspace.state.columns) { column in
                    HStack {
                        TextField(
                            "Column name",
                            text: Binding(
                                get: { workspace.state.columns.first(where: { $0.id == column.id })?.name ?? column.name },
                                set: { workspace.renameColumn(id: column.id, name: $0) }
                            )
                        )
                        Button { workspace.moveColumn(id: column.id, offset: -1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .help("Move this column earlier.")
                        Button { workspace.moveColumn(id: column.id, offset: 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .help("Move this column later.")
                        Button(role: .destructive) { workspace.deleteColumn(id: column.id) } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(column.id == CoveWorkspaceState.inboxColumnID)
                        .help(
                            column.id == CoveWorkspaceState.inboxColumnID
                                ? "Inbox cannot be deleted."
                                : "Delete this column and move its cards to Inbox."
                        )
                    }
                }
            }
            HStack {
                TextField("New column", text: $newName)
                    .accessibilityIdentifier("cove.workspace.columns.new-name")
                Button("Add") {
                    workspace.addColumn(named: newName)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add a Cove-only workflow column.")
                .accessibilityIdentifier("cove.workspace.columns.add")
            }
            .padding()
        }
    }
}

private extension CoveWorkspaceSort {
    var label: String {
        switch self {
        case .manual: "Manual"
        case .attention: "Attention"
        case .recentActivity: "Recent Activity"
        case .name: "Name"
        case .source: "Source"
        }
    }
}

private extension CoveSessionStatus {
    var workspaceIcon: String {
        switch self {
        case .waitingApproval, .blocked: "exclamationmark.shield.fill"
        case .waitingInput: "questionmark.bubble.fill"
        case .working, .active: "bolt.fill"
        case .compacting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .interrupted: "pause.circle.fill"
        case .idle, .listening, .quiet, .hidden: "circle.fill"
        }
    }

    var workspaceColor: Color {
        switch self {
        case .waitingApproval, .waitingInput, .blocked: .orange
        case .failed: .red
        case .completed: .green
        case .working, .active, .compacting: .blue
        default: .secondary
        }
    }
}

private extension CoveWorkspaceLink {
    var serviceLabel: String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("atlassian") { return "Jira/Confluence" }
        if host.contains("slack") { return "Slack" }
        if host.contains("github") { return "GitHub" }
        if host.contains("gitlab") { return "GitLab" }
        if host.contains("gerrit") { return "Gerrit" }
        if host.contains("grafana") { return "Grafana" }
        return label
    }
}
