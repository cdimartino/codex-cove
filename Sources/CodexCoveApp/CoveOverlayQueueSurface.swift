import SwiftUI
import CoveCore

// MARK: - Attention-first queue

struct CoveQueueSurfaceView: View {
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var presentationMetrics:
        CoveOverlayPresentationMetrics
    @State private var selectedID: CoveQueueItemID?
    @State private var searchText = ""
    @State private var filter = CoveQueueFilter.all
    @State private var showsDiagnostics = false
    @State private var showsRawEvents = false

    let state: CoveState
    let redactsSensitiveContent: Bool
    let onOpenSettings: @MainActor () -> Void
    let onRestoreArchived: @MainActor (String?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: 12,
                pinnedViews: usesStickySectionHeaders
                    ? [.sectionHeaders]
                    : []
            ) {
                queueHeader

                ForEach(state.settings.queueSectionOrder, id: \.self) {
                    section in
                    queueSection(section)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
            .padding(
                .top,
                max(14, presentationMetrics.topContentInset + 8)
            )
        }
        .scrollIndicators(.automatic)
        .accessibilityIdentifier("cove.queue.scroll")
        .background(Color.clear)
        .foregroundStyle(Color(hex: state.theme.foregroundHex))
        .onAppear(perform: normalizeSelection)
        .onChange(of: projection.allTaskItems.map(\.id)) {
            normalizeSelection()
        }
        .accessibilityLabel("Codex Cove attention queue")
    }

    private var projection: CoveQueueProjection {
        CoveQueueProjection(state: state)
    }

    private var usesStickySectionHeaders: Bool {
        projection.taskCount >= 10
    }

    private var selectedItem: CoveQueueItem? {
        guard let selectedID else { return nil }
        return projection.allTaskItems.first { $0.id == selectedID }
    }

    private var queueHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Queue", systemImage: "tray.full.fill")
                    .coveOverlayFont(state.theme, .title)
                Text("\(projection.taskCount)")
                    .coveOverlayFont(state.theme, .badge)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(hex: state.theme.surfaceHex))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color(hex: state.theme.borderHex))
                    }
                    .accessibilityLabel(
                        "\(projection.taskCount) tasks in the queue"
                    )

                Spacer()

                Button {
                    moveSelection(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: [.command])
                .help("Select previous task (Command-[)")
                .disabled(projection.taskCount == 0)
                .accessibilityLabel("Select previous task")
                .accessibilityIdentifier(CoveAccessibilityIDs.queuePrevious)

                Button {
                    moveSelection(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("]", modifiers: [.command])
                .help("Select next task (Command-])")
                .disabled(projection.taskCount == 0)
                .accessibilityLabel("Select next task")
                .accessibilityIdentifier(CoveAccessibilityIDs.queueNext)

                Button {
                    _ = store.requestPresentationBack()
                } label: {
                    Label("Collapse", systemImage: "chevron.up")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.overlayCollapse
                )
            }

            HStack(spacing: 8) {
                if let selectedItem {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected")
                            .coveOverlayFont(state.theme, .metadata)
                            .foregroundStyle(
                                Color(hex: state.theme.mutedTextHex)
                            )
                        Text(queueTitle(for: selectedItem))
                            .coveOverlayFont(state.theme, .body)
                            .lineLimit(1)
                    }
                } else {
                    Text("Select a task to open it in Codex")
                        .coveOverlayFont(state.theme, .body)
                        .foregroundStyle(
                            Color(hex: state.theme.mutedTextHex)
                        )
                }

                Spacer(minLength: 8)

                Button(action: openSelectedItem) {
                    Label(
                        "Open in Codex",
                        systemImage: "arrow.up.forward.app.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: state.theme.accentHex))
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Open selected task in Codex (Command-Return)")
                .disabled(selectedItem == nil)
                .accessibilityLabel("Open selected task in Codex")
                .accessibilityIdentifier("cove.queue.open-in-codex")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(hex: state.theme.surfaceHex))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(hex: state.theme.borderHex))
            }

            if let warning = store.persistenceWarning {
                Label(
                    redactsSensitiveContent
                        ? "Settings could not be loaded. Persistence is disabled."
                        : warning,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .coveOverlayFont(state.theme, .metadata)
                .foregroundStyle(Color(hex: state.theme.failedHex))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(hex: state.theme.surfaceHex))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(hex: state.theme.failedHex))
                }
            }
        }
    }

    @ViewBuilder
    private func queueSection(_ section: CoveQueueSection) -> some View {
        switch section {
        case .needsAttention:
            taskQueueSection(
                title: "Needs Attention",
                icon: "exclamationmark.bubble.fill",
                section: section
            )
        case .active:
            taskQueueSection(
                title: "Active",
                icon: "bolt.fill",
                section: section
            )
        case .recentlyFinished:
            taskQueueSection(
                title: "Recently Finished",
                icon: "checkmark.circle.fill",
                section: section
            )
        case .more:
            Section {
                if isExpanded(section) {
                    moreContents
                }
            } header: {
                queueSectionHeader(
                    title: "More",
                    icon: "ellipsis.circle.fill",
                    section: section
                )
            }
        }
    }

    @ViewBuilder
    private func taskQueueSection(
        title: String,
        icon: String,
        section: CoveQueueSection
    ) -> some View {
        let items = visibleItems(in: section)
        Section {
            if isExpanded(section) {
                if items.isEmpty {
                    Text(emptyMessage(for: section))
                        .coveOverlayFont(state.theme, .metadata)
                        .foregroundStyle(Color(hex: state.theme.mutedTextHex))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                } else {
                    ForEach(items) { item in
                        CoveQueueTaskRow(
                            item: item,
                            theme: state.theme,
                            redactsSensitiveContent: redactsSensitiveContent,
                            isSelected: item.id == selectedID,
                            isReminderScheduled: store.reminders[item.sessionId]
                                != nil,
                            onSelect: { open(item) },
                            onFocus: { focus(item) }
                        )
                        .environmentObject(store)
                    }
                }
            }
        } header: {
            queueSectionHeader(
                title: title,
                icon: icon,
                section: section
            )
        }
    }

    private func queueSectionHeader(
        title: String,
        icon: String,
        section: CoveQueueSection
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                store.dispatch(
                    .setQueueSectionCollapsed(section, isExpanded(section))
                )
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: isExpanded(section)
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .coveOverlayFont(state.theme, .badge)
                    Label(title, systemImage: icon)
                        .coveOverlayFont(state.theme, .title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section")
            .accessibilityValue(isExpanded(section) ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(
                "\(section.coveAccessibilityIdentifier).toggle"
            )

            Spacer()

            if section == .recentlyFinished,
               store.archivableCompletedCount > 0 {
                Button {
                    store.archiveAllCompleted()
                } label: {
                    Label("Archive Completed", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Archive all completed tasks")
                .accessibilityLabel("Archive all completed tasks")
                .accessibilityIdentifier(
                    "cove.queue.archive-all-completed"
                )
            }

            Menu {
                Button("Move Up", systemImage: "arrow.up") {
                    moveSection(section, by: -1)
                }
                .disabled(sectionIndex(section) == 0)

                Button("Move Down", systemImage: "arrow.down") {
                    moveSection(section, by: 1)
                }
                .disabled(
                    sectionIndex(section)
                        == state.settings.queueSectionOrder.count - 1
                )
            } label: {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Reorder \(title)")
            .accessibilityLabel("Reorder \(title) section")
            .accessibilityIdentifier(
                "\(section.coveAccessibilityIdentifier).reorder"
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, usesStickySectionHeaders ? 8 : 0)
        .background(
            Color(
                hex: state.theme.backgroundHex,
                opacity: state.settings.expandedOpacity
            )
        )
        .overlay(alignment: .bottom) {
            if usesStickySectionHeaders {
                Rectangle()
                    .fill(Color(hex: state.theme.borderHex))
                    .frame(height: 1)
            }
        }
    }

    private var moreContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search tasks", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .coveOverlayFont(state.theme, .body)
                .accessibilityLabel("Search queue tasks")
                .accessibilityIdentifier("cove.queue.search")

            Picker("Filter tasks", selection: $filter) {
                ForEach(CoveQueueFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .coveOverlayFont(state.theme, .metadata)
            .accessibilityIdentifier("cove.queue.filter")

            diagnosticsSection

            if state.settings.showUsage
                || state.settings.showProfileTokenUsage {
                CoveQueueUsageView(
                    usage: state.usage,
                    theme: state.theme,
                    showsRateLimits: state.settings.showUsage,
                    showsProfile: state.settings.showProfileTokenUsage,
                    showsRemaining: state.settings.usageShowsRemaining
                )
            }

            archivedSection

            Button(action: onOpenSettings) {
                Label("Settings…", systemImage: "gearshape.fill")
                    .coveOverlayFont(state.theme, .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .help("Open Codex Cove Settings")
            .accessibilityIdentifier("cove.queue.settings")
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsDiagnostics.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                    Spacer()
                    Text("\(activityGroups.count) groups")
                        .coveOverlayFont(state.theme, .badge)
                    Image(
                        systemName: showsDiagnostics
                            ? "chevron.up"
                            : "chevron.down"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .coveOverlayFont(state.theme, .body)
            .accessibilityValue(
                showsDiagnostics ? "Expanded" : "Collapsed"
            )
            .accessibilityIdentifier("cove.queue.diagnostics")

            if showsDiagnostics {
                if activityGroups.isEmpty {
                    Text("No grouped hook activity yet.")
                        .coveOverlayFont(state.theme, .metadata)
                        .foregroundStyle(
                            Color(hex: state.theme.mutedTextHex)
                        )
                } else {
                    ForEach(activityGroups) { group in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(
                                    Color(hex: state.theme.accentHex)
                                )
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    redactsSensitiveContent
                                        ? "Codex activity"
                                        : group.latestEvent.title
                                )
                                .coveOverlayFont(state.theme, .body)
                                .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    group.eventCount == 1
                                        ? "1 hook event"
                                        : "\(group.eventCount) hook events"
                                )
                                .coveOverlayFont(state.theme, .metadata)
                                .foregroundStyle(
                                    Color(hex: state.theme.mutedTextHex)
                                )
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(
                                cornerRadius: 7,
                                style: .continuous
                            )
                            .fill(Color(hex: state.theme.surfaceHex))
                        )
                    }
                }

                Button {
                    showsRawEvents.toggle()
                } label: {
                    HStack {
                        Label(
                            "Raw events (\(state.recentEvents.count))",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        Spacer()
                        Image(
                            systemName: showsRawEvents
                                ? "chevron.up"
                                : "chevron.down"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .coveOverlayFont(state.theme, .metadata)
                .accessibilityValue(
                    showsRawEvents ? "Expanded" : "Collapsed"
                )
                .accessibilityIdentifier("cove.queue.diagnostics.raw-events")

                if showsRawEvents {
                    ForEach(
                        Array(state.recentEvents.enumerated()),
                        id: \.offset
                    ) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                redactsSensitiveContent
                                    ? "Codex event"
                                    : event.title
                            )
                            .coveOverlayFont(state.theme, .metadata)
                            .fixedSize(horizontal: false, vertical: true)
                            if let body = event.body {
                                Text(
                                    redactsSensitiveContent
                                        ? "Sensitive details redacted"
                                        : body
                                )
                                .coveOverlayFont(state.theme, .metadata)
                                .foregroundStyle(
                                    Color(hex: state.theme.mutedTextHex)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: state.theme.surfaceHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(hex: state.theme.borderHex))
        }
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Archived (\(state.dismissedSessionIDs.count))",
                systemImage: "archivebox.fill"
            )
            .coveOverlayFont(state.theme, .body)

            if state.dismissedSessionIDs.isEmpty {
                Text("No archived tasks.")
                    .coveOverlayFont(state.theme, .metadata)
                    .foregroundStyle(Color(hex: state.theme.mutedTextHex))
            } else {
                ForEach(
                    Array(state.dismissedSessionIDs.enumerated()),
                    id: \.element
                ) { index, sessionID in
                    Button {
                        onRestoreArchived(sessionID)
                    } label: {
                        Label(
                            "Restore archived task \(index + 1)",
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Restore archived task \(index + 1)")
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.session(
                            "archived-restore",
                            sessionID: sessionID
                        )
                    )
                }

                Button {
                    onRestoreArchived(nil)
                } label: {
                    Label(
                        "Restore all archived tasks",
                        systemImage: "arrow.uturn.backward.circle.fill"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Restore all archived tasks")
                .accessibilityIdentifier("cove.queue.archived.restore-all")
            }
        }
        .coveOverlayFont(state.theme, .metadata)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: state.theme.surfaceHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(hex: state.theme.borderHex))
        }
    }

    private var activityGroups: [CoveActivityGroup] {
        CoveActivityAggregator.groups(from: state.recentEvents)
    }

    private func isExpanded(_ section: CoveQueueSection) -> Bool {
        !state.settings.collapsedQueueSections.contains(section)
    }

    private func sectionIndex(_ section: CoveQueueSection) -> Int {
        state.settings.queueSectionOrder.firstIndex(of: section) ?? 0
    }

    private func moveSection(_ section: CoveQueueSection, by offset: Int) {
        var order = state.settings.queueSectionOrder
        guard let sourceIndex = order.firstIndex(of: section) else { return }
        let destinationIndex = sourceIndex + offset
        guard order.indices.contains(destinationIndex) else { return }
        order.swapAt(sourceIndex, destinationIndex)
        store.dispatch(.setQueueSectionOrder(order))
    }

    private func visibleItems(
        in section: CoveQueueSection
    ) -> [CoveQueueItem] {
        guard filter.includes(section) else { return [] }
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return projection.items(in: section) }
        return projection.items(in: section).filter { item in
            queueSearchText(for: item)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private func queueSearchText(for item: CoveQueueItem) -> String {
        guard !redactsSensitiveContent else {
            return "Codex task \(item.status.displayName)"
        }
        return [
            queueTitle(for: item),
            queueDetail(for: item),
            item.status.displayName,
            item.snapshot?.source?.displayName ?? "",
            item.snapshot?.hostId ?? "",
        ].joined(separator: " ")
    }

    private func queueTitle(for item: CoveQueueItem) -> String {
        CoveQueueCopy.title(
            for: item,
            redactsSensitiveContent: redactsSensitiveContent
        )
    }

    private func queueDetail(for item: CoveQueueItem) -> String {
        CoveQueueCopy.detail(
            for: item,
            redactsSensitiveContent: redactsSensitiveContent
        )
    }

    private func emptyMessage(for section: CoveQueueSection) -> String {
        let hasQuery = !searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        if hasQuery || !filter.includes(section) {
            return "No matching tasks."
        }
        return switch section {
        case .needsAttention:
            "Nothing needs attention."
        case .active:
            "No active tasks."
        case .recentlyFinished:
            "No recently finished tasks."
        case .more:
            ""
        }
    }

    private func normalizeSelection() {
        if let normalized = projection.normalizedSelection(selectedID) {
            selectedID = normalized
        } else {
            selectedID = projection.allTaskItems.first?.id
        }
    }

    private func moveSelection(by offset: Int) {
        let items = projection.allTaskItems
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        let current = selectedID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        } ?? (offset >= 0 ? -1 : 0)
        selectedID = items[(current + offset + items.count) % items.count].id
    }

    private func openSelectedItem() {
        guard let selectedItem else { return }
        open(selectedItem)
    }

    private func open(_ item: CoveQueueItem) {
        selectedID = item.id
        if let request = item.directRequest {
            store.openInCodex(for: request)
        } else if let snapshot = item.snapshot {
            store.open(snapshot)
        }
    }

    private func focus(_ item: CoveQueueItem) {
        selectedID = item.id
        if let request = item.directRequest {
            _ = store.focusDirectRequest(request.key)
        } else {
            _ = store.focusSession(item.sessionId)
        }
    }
}

private enum CoveQueueFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case active
    case finished

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .attention: "Attention"
        case .active: "Active"
        case .finished: "Finished"
        }
    }

    func includes(_ section: CoveQueueSection) -> Bool {
        switch (self, section) {
        case (.all, _), (.attention, .needsAttention),
             (.active, .active), (.finished, .recentlyFinished):
            return true
        default:
            return false
        }
    }
}

private extension CoveQueueSection {
    var coveAccessibilityIdentifier: String {
        switch self {
        case .needsAttention: "cove.queue.section.needs-attention"
        case .active: "cove.queue.section.active"
        case .recentlyFinished: "cove.queue.section.recently-finished"
        case .more: "cove.queue.section.more"
        }
    }
}

private struct CoveQueueTaskRow: View {
    @EnvironmentObject private var store: CoveStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var selectionHasFocus: Bool
    @State private var selectionIsHovered = false

    let item: CoveQueueItem
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool
    let isSelected: Bool
    let isReminderScheduled: Bool
    let onSelect: () -> Void
    let onFocus: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 9) {
                    CovePixelCharacterRowAvatar(
                        character: CovePixelCharacter.assigned(
                            to: item.sessionId,
                            set: store.state.settings.residentSet
                        ),
                        status: item.status,
                        theme: theme,
                        reduceMotion: reduceMotion,
                        size: 34
                    )
                    .frame(width: 34, height: 34, alignment: .top)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            if item.isPinned {
                                Image(systemName: "pin.fill")
                                    .foregroundStyle(
                                        Color(hex: theme.accentHex)
                                    )
                                    .accessibilityLabel("Pinned")
                            }
                            Text(
                                CoveQueueCopy.title(
                                    for: item,
                                    redactsSensitiveContent:
                                        redactsSensitiveContent
                                )
                            )
                            .coveOverlayFont(theme, .body)
                            .lineLimit(1)
                            Spacer(minLength: 4)
                            if item.snapshot?.unread == true {
                                Text("Unread")
                                    .coveOverlayFont(theme, .badge)
                                    .accessibilityLabel("Unread task")
                            }
                        }

                        Label(
                            item.status.displayName,
                            systemImage: item.status.coveStatusIcon
                        )
                        .coveOverlayFont(theme, .status)
                        .foregroundStyle(Color(hex: theme.foregroundHex))
                        .accessibilityLabel(
                            "Status: \(item.status.displayName)"
                        )

                        Text(
                            CoveQueueCopy.detail(
                                for: item,
                                redactsSensitiveContent:
                                    redactsSensitiveContent
                            )
                        )
                        .coveOverlayFont(theme, .metadata)
                        .foregroundStyle(Color(hex: theme.mutedTextHex))
                        .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(
                CoveQueueSelectionButtonStyle(
                    theme: theme,
                    isSelected: isSelected,
                    hasKeyboardFocus: selectionHasFocus,
                    isHovering: selectionIsHovered
                )
            )
            .onHover { selectionIsHovered = $0 }
            .focused($selectionHasFocus)
            .accessibilityIdentifier(rowAccessibilityIdentifier)
            .accessibilityLabel(
                "\(item.status.displayName), \(CoveQueueCopy.title(for: item, redactsSensitiveContent: redactsSensitiveContent))"
            )
            .accessibilityHint("Opens this task in Codex")

            Button(action: onFocus) {
                Text(item.directRequest == nil ? "Details" : "Review")
                    .coveOverlayFont(theme, .badge)
                    .frame(minWidth: 48, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .help(
                item.directRequest == nil
                    ? "Show full task details"
                    : "Review this Codex request"
            )
            .accessibilityIdentifier(focusAccessibilityIdentifier)

            Menu {
                quickActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .coveOverlayFont(theme, .body)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Task actions: Pin, Remind, Mark Read, or Archive")
            .accessibilityLabel("Task actions")
            .accessibilityIdentifier(actionsAccessibilityIdentifier)
        }
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .contextMenu {
            quickActions
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        Button(item.isPinned ? "Unpin" : "Pin") {
            guard let snapshot = item.snapshot else { return }
            store.togglePinned(snapshot)
        }
        .disabled(item.snapshot == nil)
        .accessibilityLabel(item.isPinned ? "Unpin" : "Pin")
        .accessibilityIdentifier(
            actionAccessibilityIdentifier("pin")
        )

        Button(
            isReminderScheduled
                ? "Cancel Reminder"
                : "Remind Me"
        ) {
            guard let snapshot = item.snapshot else { return }
            if isReminderScheduled {
                store.cancelFollowUp(snapshot)
            } else {
                store.scheduleFollowUp(snapshot)
            }
        }
        .disabled(item.snapshot == nil)
        .accessibilityLabel(
            isReminderScheduled ? "Cancel Reminder" : "Remind Me"
        )
        .accessibilityIdentifier(
            actionAccessibilityIdentifier("reminder")
        )

        Button("Mark Read") {
            guard let snapshot = item.snapshot else { return }
            store.markRead(snapshot)
        }
        .disabled(item.snapshot?.unread != true)
        .accessibilityLabel("Mark Read")
        .accessibilityIdentifier(
            actionAccessibilityIdentifier("mark-read")
        )

        Divider()

        Button("Archive") {
            guard let snapshot = item.snapshot else { return }
            store.dismiss(snapshot)
        }
        .disabled(item.snapshot == nil)
        .accessibilityLabel("Archive")
        .accessibilityIdentifier(
            actionAccessibilityIdentifier("archive")
        )
    }

    private var rowAccessibilityIdentifier: String {
        if let request = item.directRequest {
            return CoveAccessibilityIDs.request(
                "queue-row",
                requestKey: request.key
            )
        }
        return CoveAccessibilityIDs.session(
            "queue-row",
            sessionID: item.sessionId
        )
    }

    private var focusAccessibilityIdentifier: String {
        if let request = item.directRequest {
            return CoveAccessibilityIDs.request(
                "queue-focus",
                requestKey: request.key
            )
        }
        return CoveAccessibilityIDs.session(
            "queue-focus",
            sessionID: item.sessionId
        )
    }

    private var actionsAccessibilityIdentifier: String {
        if let request = item.directRequest {
            return CoveAccessibilityIDs.request(
                "queue-actions",
                requestKey: request.key
            )
        }
        return CoveAccessibilityIDs.session(
            "queue-actions",
            sessionID: item.sessionId
        )
    }

    private func actionAccessibilityIdentifier(_ action: String) -> String {
        let control = "queue-action-\(action)"
        if let request = item.directRequest {
            return CoveAccessibilityIDs.request(
                control,
                requestKey: request.key
            )
        }
        return CoveAccessibilityIDs.session(
            control,
            sessionID: item.sessionId
        )
    }
}

private struct CoveQueueSelectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let theme: CoveThemePalette
    let isSelected: Bool
    let hasKeyboardFocus: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        backgroundColor(
                            isPressed: configuration.isPressed
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        borderColor,
                        lineWidth: hasKeyboardFocus ? 3 : isSelected ? 2 : 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func backgroundColor(
        isPressed: Bool
    ) -> Color {
        if !isEnabled {
            return Color(hex: theme.surfaceHex).opacity(0.45)
        }
        if isPressed { return Color(hex: theme.backgroundHex) }
        if isHovering { return Color(hex: theme.accentHex).opacity(0.16) }
        return Color(hex: theme.surfaceHex)
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color(hex: theme.borderHex).opacity(0.42)
        }
        if isSelected || hasKeyboardFocus || isHovering {
            return Color(hex: theme.accentHex)
        }
        return Color(hex: theme.borderHex)
    }
}

private enum CoveQueueCopy {
    static func title(
        for item: CoveQueueItem,
        redactsSensitiveContent: Bool
    ) -> String {
        guard !redactsSensitiveContent else { return "Codex task" }
        if let request = item.directRequest {
            switch request {
            case let .approval(approval):
                return approval.title
            case let .question(question):
                return question.questions.count == 1
                    ? question.question
                    : "Codex has \(question.questions.count) questions"
            case let .planSnapshot(plan):
                return plan.title
            }
        }
        return item.snapshot?.title ?? "Codex task"
    }

    static func detail(
        for item: CoveQueueItem,
        redactsSensitiveContent: Bool
    ) -> String {
        guard !redactsSensitiveContent else {
            return "Sensitive details redacted"
        }
        if let detail = item.snapshot?.detail, !detail.isEmpty {
            return detail
        }
        if let request = item.directRequest {
            switch request {
            case let .approval(approval):
                return approval.detail
                    ?? "\(approval.category.rawValue.capitalized) approval"
            case let .question(question):
                return question.questions.count == 1
                    ? "Answer one question"
                    : "Answer every question"
            case let .planSnapshot(plan):
                return "\(plan.steps.count) plan steps"
            }
        }
        let metadata = [
            item.snapshot?.source?.displayName,
            item.snapshot?.hostId,
        ].compactMap { $0 }
        return metadata.isEmpty ? item.status.displayName : metadata.joined(
            separator: " · "
        )
    }
}

// MARK: - Semantic usage under More

private struct CoveQueueUsageView: View {
    let usage: CoveUsageSnapshot?
    let theme: CoveThemePalette
    let showsRateLimits: Bool
    let showsProfile: Bool
    let showsRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Usage", systemImage: "chart.bar.fill")
                .coveOverlayFont(theme, .title)

            if showsRateLimits {
                if let usage {
                    usageWindow("Primary", usage.primary)
                    usageWindow("Secondary", usage.secondary)
                } else {
                    Text("Rate-limit usage unavailable.")
                        .coveOverlayFont(theme, .metadata)
                        .foregroundStyle(Color(hex: theme.mutedTextHex))
                }
            }

            if showsProfile {
                if let summary = usage?.accountTokenUsage?.summary,
                   summary.hasMetrics {
                    if let lifetime = summary.lifetimeTokens {
                        usageValue("Lifetime tokens", value: "\(lifetime)")
                    }
                    if let peak = summary.peakDailyTokens {
                        usageValue("Peak daily tokens", value: "\(peak)")
                    }
                    if let streak = summary.currentStreakDays {
                        usageValue("Current streak", value: "\(streak) days")
                    }
                } else {
                    Text("Profile token usage unavailable.")
                        .coveOverlayFont(theme, .metadata)
                        .foregroundStyle(Color(hex: theme.mutedTextHex))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: theme.surfaceHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(hex: theme.borderHex))
        }
    }

    @ViewBuilder
    private func usageWindow(
        _ title: String,
        _ window: CoveRateLimitWindow?
    ) -> some View {
        if let window {
            let value = showsRemaining
                ? window.remainingPercent
                : window.usedPercent
            HStack {
                Text(title)
                Spacer()
                Text("\(value)% \(showsRemaining ? "remaining" : "used")")
                    .monospacedDigit()
            }
            .coveOverlayFont(theme, .data)
            ProgressView(value: Double(value), total: 100)
                .tint(Color(hex: theme.accentHex))
                .accessibilityLabel("\(title) usage")
                .accessibilityValue(
                    "\(value) percent \(showsRemaining ? "remaining" : "used")"
                )
        } else {
            Text("\(title) usage unavailable")
                .coveOverlayFont(theme, .metadata)
                .foregroundStyle(Color(hex: theme.mutedTextHex))
        }
    }

    private func usageValue(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
        .coveOverlayFont(theme, .data)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fixture and dirty-exit overlays

struct CoveFixtureAccessibilityMarkers: View {
    let stateDirectory: String
    let decisionAttemptCount: Int
    let jumpCount: Int
    let queueSectionOrder: [CoveQueueSection]
    let textScale: Double

    var body: some View {
        HStack(spacing: 0) {
            marker(
                value: stateDirectory,
                identifier: "cove.fixture.state-directory"
            )
            marker(
                value: "\(decisionAttemptCount)",
                identifier: "cove.fixture.decision-attempt-count"
            )
            marker(
                value: "\(jumpCount)",
                identifier: "cove.fixture.jump-count"
            )
            marker(
                value: queueSectionOrder
                    .map { "\($0.rawValue)" }
                    .joined(separator: ","),
                identifier: "cove.fixture.queue-section-order"
            )
            marker(
                value: String(format: "%.2f", textScale),
                identifier: "cove.fixture.text-scale"
            )
        }
        .frame(width: 5, height: 1)
        .allowsHitTesting(false)
    }

    private func marker(
        value: String,
        identifier: String
    ) -> some View {
        Text(value)
            .font(.system(size: 1))
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .clipped()
            .opacity(0.001)
            .accessibilityIdentifier(identifier)
    }
}

struct CoveDirtyExitConfirmationView: View {
    @EnvironmentObject private var store: CoveStore

    let confirmation: CovePendingDirtyExitConfirmation
    let theme: CoveThemePalette

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Keep editing?",
                    systemImage: "square.and.pencil"
                )
                .coveOverlayFont(theme, .title)
                Text(
                    "This action has an unsent choice or answer. Keep editing, or discard the draft before leaving."
                )
                .coveOverlayFont(theme, .body)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Keep Editing") {
                        store.keepEditingPendingDirtyExit()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: theme.accentHex))
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.dirtyExit(
                            .keepEditing,
                            requestKey: confirmation.requestKey
                        )
                    )

                    Button("Discard") {
                        store.discardPendingDirtyExit()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.dirtyExit(
                            .discard,
                            requestKey: confirmation.requestKey
                        )
                    )
                }
            }
            .foregroundStyle(Color(hex: theme.foregroundHex))
            .padding(18)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: theme.surfaceHex))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(hex: theme.borderHex), lineWidth: 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unsent action confirmation")
        }
        .zIndex(100)
    }
}

// MARK: - Focused action surface

struct CoveFocusedSurfaceView: View {
    @EnvironmentObject private var store: CoveStore
    @EnvironmentObject private var presentationMetrics:
        CoveOverlayPresentationMetrics

    let target: CoveFocusTarget
    let state: CoveState
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            focusedHeader

            Divider()
                .overlay(Color(hex: state.theme.borderHex))

            ScrollView {
                focusedContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollIndicators(.automatic)
            .accessibilityIdentifier("cove.focused.scroll")
        }
        .padding(
            .top,
            max(12, presentationMetrics.topContentInset + 6)
        )
        .background(Color.clear)
        .foregroundStyle(Color(hex: state.theme.foregroundHex))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cove.overlay.focused")
        .accessibilityLabel("Codex Cove focused action")
    }

    private var focusedHeader: some View {
        HStack(spacing: 10) {
            Button {
                _ = store.requestPresentationBack()
            } label: {
                Label("Back to Queue", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Return to the queue (Escape)")
            .accessibilityIdentifier(CoveAccessibilityIDs.overlayCollapse)

            Spacer()

            Label("Focused Action", systemImage: "scope")
                .coveOverlayFont(state.theme, .title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var focusedContent: some View {
        switch target {
        case let .directRequest(requestKey):
            if let request = state.pendingDirectRequests.first(where: {
                $0.key == requestKey
            }) {
                CoveFocusedDirectRequestView(
                    request: request,
                    matchingSnapshot: matchingSnapshot(for: request),
                    theme: state.theme,
                    redactsSensitiveContent: redactsSensitiveContent
                )
                .environmentObject(store)
            } else {
                missingContent
            }
        case let .session(sessionID):
            if let snapshot = state.session.snapshots.first(where: {
                ($0.sessionId ?? $0.snapshotId) == sessionID
            }) {
                CoveFocusedSessionView(
                    snapshot: snapshot,
                    theme: state.theme,
                    redactsSensitiveContent: redactsSensitiveContent
                )
                .environmentObject(store)
            } else {
                missingContent
            }
        }
    }

    private var missingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "This action is no longer available",
                systemImage: "checkmark.circle.fill"
            )
            .coveOverlayFont(state.theme, .title)
            Text("It may have completed or been resolved in Codex.")
                .coveOverlayFont(state.theme, .body)
                .foregroundStyle(Color(hex: state.theme.mutedTextHex))
            Button("Return to Queue") {
                store.showQueue()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: state.theme.accentHex))
            .accessibilityLabel("Return to Queue")
            .accessibilityIdentifier("cove.focused.return-to-queue")
        }
        .coveOpaqueCard(theme: state.theme)
    }

    private func matchingSnapshot(
        for request: CoveDirectRequest
    ) -> CoveSessionSnapshot? {
        state.session.snapshots
            .filter { snapshot in
                let sessionID = snapshot.sessionId ?? snapshot.snapshotId
                guard sessionID == request.sessionId else { return false }
                guard snapshot.originScope == request.originScope else {
                    return false
                }
                if let requestLaunch = request.launchId,
                   let snapshotLaunch = snapshot.launchId,
                   requestLaunch != snapshotLaunch {
                    return false
                }
                return true
            }
            .max { $0.timestamp < $1.timestamp }
    }
}

private struct CoveFocusedDirectRequestView: View {
    @EnvironmentObject private var store: CoveStore

    let request: CoveDirectRequest
    let matchingSnapshot: CoveSessionSnapshot?
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        switch request {
        case let .approval(approval):
            CoveFocusedApprovalView(
                approval: approval,
                source: matchingSnapshot?.source?.displayName ?? "Codex",
                theme: theme,
                redactsSensitiveContent: redactsSensitiveContent
            )
            .environmentObject(store)
        case let .question(question):
            CoveFocusedQuestionView(
                question: question,
                source: matchingSnapshot?.source?.displayName ?? "Codex",
                theme: theme,
                redactsSensitiveContent: redactsSensitiveContent
            )
            .environmentObject(store)
        case let .planSnapshot(plan):
            CoveFocusedPlanView(
                plan: plan,
                source: matchingSnapshot?.source?.displayName ?? "Codex",
                theme: theme,
                redactsSensitiveContent: redactsSensitiveContent
            )
            .environmentObject(store)
        }
    }
}

private struct CoveFocusedApprovalView: View {
    @EnvironmentObject private var store: CoveStore

    let approval: CoveApprovalRequest
    let source: String
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                redactsSensitiveContent
                    ? "Codex needs approval"
                    : approval.title,
                systemImage: redactsSensitiveContent
                    ? "eye.slash.fill"
                    : "checkmark.shield.fill"
            )
            .coveOverlayFont(theme, .title)
            .fixedSize(horizontal: false, vertical: true)

            if redactsSensitiveContent {
                Text(
                    "Approval details are hidden by Privacy Mode. Review and answer this request in Codex."
                )
                .coveOverlayFont(theme, .body)
                .fixedSize(horizontal: false, vertical: true)

                openInCodexButton
            } else {
                approvalContext

                if supportsDirectResponse {
                    scopeChoices
                    negativeChoices
                    selectedScope

                    Button {
                        _ = store.confirmApproval(for: approval)
                    } label: {
                        Label(
                            "Confirm Allow",
                            systemImage: "checkmark.shield.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: theme.accentHex))
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Confirm the selected approval scope (Return)")
                    .disabled(
                        approvalDraft == nil
                            || deliveryIsSending
                            || deliveryIsSucceeded
                    )
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.approval(
                            .confirmAllow,
                            requestKey: requestKey
                        )
                    )

                    CoveDecisionDeliveryView(
                        request: .approval(approval),
                        theme: theme,
                        statusIdentifier: CoveAccessibilityIDs.approval(
                            .deliveryStatus,
                            requestKey: requestKey
                        ),
                        retryIdentifier: CoveAccessibilityIDs.approval(
                            .retry,
                            requestKey: requestKey
                        ),
                        openIdentifier: CoveAccessibilityIDs.approval(
                            .openInCodex,
                            requestKey: requestKey
                        )
                    )
                    .environmentObject(store)

                    if !deliveryIsFailed {
                        openInCodexButton
                    }
                } else {
                    Text(
                        "This request did not expose a supported public decision channel. Answer it in Codex."
                    )
                    .coveOverlayFont(theme, .body)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
                    .fixedSize(horizontal: false, vertical: true)
                    openInCodexButton
                }
            }

            if (!supportsDirectResponse || redactsSensitiveContent),
               let message = store.decisionDelivery.errorMessage(
                   for: requestKey
               ) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .coveOverlayFont(theme, .metadata)
                    .foregroundStyle(Color(hex: theme.failedHex))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .coveOpaqueCard(theme: theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            CoveAccessibilityIDs.approval(
                .container,
                requestKey: requestKey
            )
        )
    }

    private var requestKey: CoveDirectRequestKey {
        CoveDirectRequest.approval(approval).key
    }

    private var approvalDraft: CoveApprovalDraft? {
        store.approvalDraft(for: requestKey)
    }

    private var supportsDirectResponse: Bool {
        approval.decisionSocket?.isEmpty == false
            && approval.choices.contains {
                CoveApprovalChoice.decision(for: $0) != nil
            }
    }

    private var deliveryIsSending: Bool {
        store.decisionDelivery.isSending(requestKey)
    }

    private var deliveryIsSucceeded: Bool {
        store.decisionDelivery.isSucceeded(requestKey)
    }

    private var deliveryIsFailed: Bool {
        store.decisionDelivery.errorMessage(for: requestKey) != nil
    }

    private var approvalContext: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("Category") {
                Label(
                    approval.category.coveDisplayName,
                    systemImage: approval.category.coveIcon
                )
            }
            .accessibilityIdentifier(
                CoveAccessibilityIDs.approval(
                    .category,
                    requestKey: requestKey
                )
            )

            LabeledContent("Source") {
                Text(source)
            }
            .accessibilityIdentifier(
                CoveAccessibilityIDs.approval(
                    .source,
                    requestKey: requestKey
                )
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Consequence")
                    .coveOverlayFont(theme, .metadata)
                    .foregroundStyle(Color(hex: theme.mutedTextHex))
                Text(
                    approval.detail
                        ?? "Codex is asking permission to continue this action."
                )
                .coveOverlayFont(theme, .body)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(
                CoveAccessibilityIDs.approval(
                    .consequence,
                    requestKey: requestKey
                )
            )
        }
        .coveOverlayFont(theme, .body)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: theme.backgroundHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: theme.borderHex))
        }
    }

    private var scopeChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approval scope")
                .coveOverlayFont(theme, .title)

            if let choice = CoveApprovalChoice.choice(
                for: .accept,
                in: approval.choices
            ) {
                approvalChoiceButton(
                    choice,
                    decision: .accept,
                    title: "Allow once",
                    icon: "1.circle.fill",
                    identifier: .allowOnce
                )
            }

            if let choice = CoveApprovalChoice.choice(
                for: .acceptForSession,
                in: approval.choices
            ) {
                approvalChoiceButton(
                    choice,
                    decision: .acceptForSession,
                    title: "Allow for this task",
                    icon: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill",
                    identifier: .allowForTask
                )
            }
        }
    }

    private var negativeChoices: some View {
        HStack(spacing: 8) {
            if let choice = CoveApprovalChoice.choice(
                for: .decline,
                in: approval.choices
            ) {
                Button {
                    _ = store.selectApprovalChoice(choice, for: approval)
                } label: {
                    Label("Decline", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(deliveryIsSending || deliveryIsSucceeded)
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.approval(
                        .decline,
                        requestKey: requestKey
                    )
                )
            }

            if let choice = CoveApprovalChoice.choice(
                for: .cancel,
                in: approval.choices
            ) {
                Button {
                    _ = store.selectApprovalChoice(choice, for: approval)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(deliveryIsSending || deliveryIsSucceeded)
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.approval(
                        .cancel,
                        requestKey: requestKey
                    )
                )
            }
        }
    }

    private var selectedScope: some View {
        Label(
            approvalDraft?.scopeLabel.map { "Selected scope: \($0)" }
                ?? "No approval scope selected",
            systemImage: approvalDraft == nil
                ? "circle"
                : "checkmark.circle.fill"
        )
        .coveOverlayFont(theme, .status)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(
            CoveAccessibilityIDs.approval(
                .scope,
                requestKey: requestKey
            )
        )
    }

    private func approvalChoiceButton(
        _ choice: CoveChoice,
        decision: CoveApprovalDecision,
        title: String,
        icon: String,
        identifier: CoveAccessibilityIDs.ApprovalControl
    ) -> some View {
        let selected = approvalDraft?.decision == decision
        return Button {
            _ = store.selectApprovalChoice(choice, for: approval)
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: selected ? "checkmark.circle.fill" : icon)
                Spacer()
                Text(
                    decision == .accept
                        ? "One action"
                        : "Current task"
                )
                .coveOverlayFont(theme, .metadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            CoveOpaqueChoiceButtonStyle(
                theme: theme,
                isSelected: selected
            )
        )
        .disabled(deliveryIsSending || deliveryIsSucceeded)
        .accessibilityIdentifier(
            CoveAccessibilityIDs.approval(
                identifier,
                requestKey: requestKey
            )
        )
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var openInCodexButton: some View {
        Button {
            store.openInCodex(for: .approval(approval))
        } label: {
            Label("Open in Codex", systemImage: "arrow.up.forward.app.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
            CoveAccessibilityIDs.approval(
                .openInCodex,
                requestKey: requestKey
            )
        )
    }
}

private struct CoveFocusedQuestionView: View {
    @EnvironmentObject private var store: CoveStore

    let question: CoveQuestionRequest
    let source: String
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                redactsSensitiveContent
                    ? "Codex needs input"
                    : question.questions.count == 1
                        ? "Codex has a question"
                        : "Codex has \(question.questions.count) questions",
                systemImage: redactsSensitiveContent
                    ? "eye.slash.fill"
                    : "questionmark.bubble.fill"
            )
            .coveOverlayFont(theme, .title)
            .fixedSize(horizontal: false, vertical: true)

            if redactsSensitiveContent {
                Text(
                    "Question details are hidden by Privacy Mode. Review and answer this request in Codex."
                )
                .coveOverlayFont(theme, .body)
                .fixedSize(horizontal: false, vertical: true)
                openInCodexButton
            } else if supportsDirectResponse {
                Label("Source: \(source)", systemImage: "arrow.down.message.fill")
                    .coveOverlayFont(theme, .metadata)

                ForEach(
                    Array(question.questions.enumerated()),
                    id: \.element.questionId
                ) { index, prompt in
                    promptView(prompt, number: index + 1)
                }

                Button {
                    _ = store.confirmQuestionDraft(for: question)
                } label: {
                    Label("Send Answers", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: theme.accentHex))
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send every answer (Command-Return)")
                .disabled(
                    !hasEveryAnswer
                        || deliveryIsSending
                        || deliveryIsSucceeded
                )
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.questionSend(
                        requestKey: requestKey
                    )
                )

                CoveDecisionDeliveryView(
                    request: .question(question),
                    theme: theme,
                    statusIdentifier: CoveAccessibilityIDs.request(
                        "question.delivery-status",
                        requestKey: requestKey
                    ),
                    retryIdentifier: CoveAccessibilityIDs.request(
                        "question.retry",
                        requestKey: requestKey
                    ),
                    openIdentifier: CoveAccessibilityIDs.request(
                        "question.open-in-codex",
                        requestKey: requestKey
                    )
                )
                .environmentObject(store)

                if !deliveryIsFailed {
                    openInCodexButton
                }
            } else {
                Text(
                    "This request did not expose a supported public decision channel. Answer it in Codex."
                )
                .coveOverlayFont(theme, .body)
                .foregroundStyle(Color(hex: theme.mutedTextHex))
                .fixedSize(horizontal: false, vertical: true)
                openInCodexButton
            }

            if (!supportsDirectResponse || redactsSensitiveContent),
               let message = store.decisionDelivery.errorMessage(
                   for: requestKey
               ) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .coveOverlayFont(theme, .metadata)
                    .foregroundStyle(Color(hex: theme.failedHex))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .coveOpaqueCard(theme: theme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            CoveAccessibilityIDs.questionContainer(
                requestKey: requestKey
            )
        )
    }

    private var requestKey: CoveDirectRequestKey {
        CoveDirectRequest.question(question).key
    }

    private var draftAnswers: [String: [String]] {
        store.questionDraft(for: requestKey)?.answers ?? [:]
    }

    private var supportsDirectResponse: Bool {
        question.decisionSocket?.isEmpty == false
            && !question.questions.isEmpty
            && question.questions.allSatisfy {
                !$0.options.isEmpty || $0.allowsFreeform
            }
    }

    private var deliveryIsSending: Bool {
        store.decisionDelivery.isSending(requestKey)
    }

    private var deliveryIsSucceeded: Bool {
        store.decisionDelivery.isSucceeded(requestKey)
    }

    private var deliveryIsFailed: Bool {
        store.decisionDelivery.errorMessage(for: requestKey) != nil
    }

    private var hasEveryAnswer: Bool {
        question.questions.allSatisfy { prompt in
            guard let answers = draftAnswers[prompt.questionId],
                  !answers.isEmpty,
                  answers.allSatisfy({
                      !$0.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                  }) else {
                return false
            }
            if prompt.allowsFreeform { return true }
            let advertised = Set(
                prompt.options.map(CoveQuestionChoice.answer(for:))
            )
            return answers.allSatisfy(advertised.contains)
        }
    }

    private func promptView(
        _ prompt: CoveQuestionPrompt,
        number: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let header = prompt.header, !header.isEmpty {
                Text(header)
                    .coveOverlayFont(theme, .title)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(number). \(prompt.question)")
                .coveOverlayFont(theme, .body)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(prompt.options, id: \.identifier) { choice in
                let answer = CoveQuestionChoice.answer(for: choice)
                let selected = draftAnswers[prompt.questionId]?.contains(
                    answer
                ) == true
                Button {
                    _ = store.setQuestionDraftAnswers(
                        merging: [answer],
                        questionID: prompt.questionId,
                        for: question
                    )
                } label: {
                    Label(
                        choice.label,
                        systemImage: selected
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(
                    CoveOpaqueChoiceButtonStyle(
                        theme: theme,
                        isSelected: selected
                    )
                )
                .disabled(deliveryIsSending || deliveryIsSucceeded)
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.questionChoice(
                        requestKey: requestKey,
                        questionID: prompt.questionId,
                        choiceID: choice.identifier
                    )
                )
                .accessibilityValue(
                    selected ? "Selected" : "Not selected"
                )
            }

            if prompt.allowsFreeform {
                TextField(
                    "Type a complete response",
                    text: answerBinding(for: prompt.questionId),
                    axis: .vertical
                )
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .coveOverlayFont(theme, .body)
                .disabled(deliveryIsSending || deliveryIsSucceeded)
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.questionAnswer(
                        requestKey: requestKey,
                        questionID: prompt.questionId
                    )
                )
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: theme.backgroundHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: theme.borderHex))
        }
    }

    private func answerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { draftAnswers[questionID]?.first ?? "" },
            set: { value in
                _ = store.setQuestionDraftAnswer(
                    value,
                    questionID: questionID,
                    for: question
                )
            }
        )
    }

    private var openInCodexButton: some View {
        Button {
            store.openInCodex(for: .question(question))
        } label: {
            Label("Open in Codex", systemImage: "arrow.up.forward.app.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
            CoveAccessibilityIDs.request(
                "question.open-in-codex",
                requestKey: requestKey
            )
        )
    }
}

private struct CoveFocusedPlanView: View {
    @EnvironmentObject private var store: CoveStore

    let plan: CovePlanSnapshot
    let source: String
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(
                redactsSensitiveContent ? "Codex plan" : plan.title,
                systemImage: redactsSensitiveContent
                    ? "eye.slash.fill"
                    : "list.bullet.clipboard.fill"
            )
            .coveOverlayFont(theme, .title)
            .fixedSize(horizontal: false, vertical: true)

            if redactsSensitiveContent {
                Text("Plan details are hidden by Privacy Mode.")
                    .coveOverlayFont(theme, .body)
            } else {
                Label("Source: \(source)", systemImage: "arrow.down.message.fill")
                    .coveOverlayFont(theme, .metadata)

                ForEach(Array(plan.steps.enumerated()), id: \.offset) {
                    index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .coveOverlayFont(theme, .badge)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(Color(hex: theme.backgroundHex))
                            )
                            .overlay {
                                Circle()
                                    .stroke(Color(hex: theme.accentHex))
                            }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .coveOverlayFont(theme, .body)
                                .fixedSize(horizontal: false, vertical: true)
                            Label(
                                step.status.capitalized,
                                systemImage: "circle.fill"
                            )
                            .coveOverlayFont(theme, .status)
                            if let detail = step.detail {
                                Text(detail)
                                    .coveOverlayFont(theme, .metadata)
                                    .foregroundStyle(
                                        Color(hex: theme.mutedTextHex)
                                    )
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                            }
                        }
                    }
                }
            }

            Button {
                store.openInCodex(for: .planSnapshot(plan))
            } label: {
                Label("Open in Codex", systemImage: "arrow.up.forward.app.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: theme.accentHex))
            .accessibilityIdentifier(
                CoveAccessibilityIDs.request(
                    "plan.open-in-codex",
                    requestKey: CoveDirectRequest.planSnapshot(plan).key
                )
            )

            if let message = store.decisionDelivery.errorMessage(
                for: CoveDirectRequest.planSnapshot(plan).key
            ) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .coveOverlayFont(theme, .metadata)
                    .foregroundStyle(Color(hex: theme.failedHex))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .coveOpaqueCard(theme: theme)
    }
}

private struct CoveFocusedSessionView: View {
    @EnvironmentObject private var store: CoveStore

    let snapshot: CoveSessionSnapshot
    let theme: CoveThemePalette
    let redactsSensitiveContent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(redactsSensitiveContent ? "Codex task" : snapshot.title)
                .coveOverlayFont(theme, .title)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                snapshot.status.displayName,
                systemImage: snapshot.status.coveStatusIcon
            )
            .coveOverlayFont(theme, .status)

            if redactsSensitiveContent {
                Text("Sensitive task details are hidden by Privacy Mode.")
                    .coveOverlayFont(theme, .body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let detail = snapshot.detail, !detail.isEmpty {
                    Text(detail)
                        .coveOverlayFont(theme, .body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metadata
            }

            HStack(spacing: 8) {
                Button {
                    store.open(snapshot)
                } label: {
                    Label(
                        "Open in Codex",
                        systemImage: "arrow.up.forward.app.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: theme.accentHex))
                .accessibilityLabel("Open in Codex")
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.session(
                        "focused-open-in-codex",
                        sessionID: sessionID
                    )
                )

                Menu {
                    Button(isPinned ? "Unpin" : "Pin") {
                        store.togglePinned(snapshot)
                    }
                    .accessibilityLabel(isPinned ? "Unpin" : "Pin")
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.session(
                            "focused-action-pin",
                            sessionID: sessionID
                        )
                    )
                    Button(
                        isReminderScheduled
                            ? "Cancel Reminder"
                            : "Remind Me"
                    ) {
                        if isReminderScheduled {
                            store.cancelFollowUp(snapshot)
                        } else {
                            store.scheduleFollowUp(snapshot)
                        }
                    }
                    .accessibilityLabel(
                        isReminderScheduled ? "Cancel Reminder" : "Remind Me"
                    )
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.session(
                            "focused-action-reminder",
                            sessionID: sessionID
                        )
                    )
                    Button("Mark Read") {
                        store.markRead(snapshot)
                    }
                    .disabled(!snapshot.unread)
                    .accessibilityLabel("Mark Read")
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.session(
                            "focused-action-mark-read",
                            sessionID: sessionID
                        )
                    )
                    Divider()
                    Button("Archive") {
                        store.dismiss(snapshot)
                    }
                    .accessibilityLabel("Archive")
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.session(
                            "focused-action-archive",
                            sessionID: sessionID
                        )
                    )
                } label: {
                    Label("Task Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Task actions")
                .accessibilityIdentifier(
                    CoveAccessibilityIDs.session(
                        "focused-actions",
                        sessionID: sessionID
                    )
                )
            }
        }
        .coveOpaqueCard(theme: theme)
    }

    private var sessionID: String {
        snapshot.sessionId ?? snapshot.snapshotId
    }

    private var isPinned: Bool {
        store.state.pinnedSessionIDs.contains(sessionID)
    }

    private var isReminderScheduled: Bool {
        store.reminders[sessionID] != nil
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let source = snapshot.source {
                LabeledContent("Source", value: source.displayName)
            }
            if let host = snapshot.hostId, !host.isEmpty {
                LabeledContent("Host", value: host)
            }
            LabeledContent("Updated") {
                Text(snapshot.timestamp, style: .relative)
            }
        }
        .coveOverlayFont(theme, .metadata)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: theme.backgroundHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: theme.borderHex))
        }
    }
}

private struct CoveDecisionDeliveryView: View {
    @EnvironmentObject private var store: CoveStore

    let request: CoveDirectRequest
    let theme: CoveThemePalette
    let statusIdentifier: String
    let retryIdentifier: String
    let openIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusContent
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .accessibilityIdentifier(statusIdentifier)

            if case .failed? = status {
                HStack(spacing: 8) {
                    Button {
                        _ = store.retryDecision(for: request.key)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: theme.accentHex))
                    .disabled(
                        store.decisionDelivery.retryAttempt(
                            for: request.key
                        ) == nil
                    )
                    .accessibilityIdentifier(retryIdentifier)

                    Button {
                        store.openInCodex(for: request)
                    } label: {
                        Label(
                            "Open in Codex",
                            systemImage: "arrow.up.forward.app"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(openIdentifier)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: theme.backgroundHex))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: theme.borderHex))
        }
    }

    private var status: CoveDecisionDeliveryStatus? {
        store.decisionDelivery.status(for: request.key)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch status {
        case nil:
            Label("No response sent", systemImage: "circle")
                .coveOverlayFont(theme, .status)
        case .staged:
            Label(
                "Choice staged; review it before sending",
                systemImage: "checkmark.circle"
            )
            .coveOverlayFont(theme, .status)
        case .sending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending response…")
            }
            .coveOverlayFont(theme, .status)
            .accessibilityElement(children: .combine)
        case .succeeded:
            Label(
                "Response sent",
                systemImage: "checkmark.circle.fill"
            )
            .coveOverlayFont(theme, .status)
        case let .failed(message, _):
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    "Response was not sent",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .coveOverlayFont(theme, .status)
                Text(message)
                    .coveOverlayFont(theme, .metadata)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CoveOpaqueChoiceButtonStyle: ButtonStyle {
    let theme: CoveThemePalette
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .coveOverlayFont(theme, .body)
            .foregroundStyle(Color(hex: theme.foregroundHex))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color(hex: theme.backgroundHex)
                            : Color(hex: theme.surfaceHex)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color(hex: theme.accentHex)
                            : Color(hex: theme.borderHex),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
    }
}

private enum CoveApprovalChoice {
    static func decision(for choice: CoveChoice) -> CoveApprovalDecision? {
        let identifier = choice.raw?.objectValue?["decision"]?.stringValue
            ?? choice.identifier
        if let decision = CoveApprovalDecision(rawValue: identifier) {
            return decision
        }
        return identifier == "deny" ? .decline : nil
    }

    static func choice(
        for decision: CoveApprovalDecision,
        in choices: [CoveChoice]
    ) -> CoveChoice? {
        choices.first { self.decision(for: $0) == decision }
    }
}

private enum CoveQuestionChoice {
    static func answer(for choice: CoveChoice) -> String {
        let raw = choice.raw?.objectValue
        return raw?["value"]?.stringValue
            ?? raw?["label"]?.stringValue
            ?? choice.raw?.stringValue
            ?? choice.label
    }
}

private extension CoveApprovalCategory {
    var coveDisplayName: String {
        switch self {
        case .command: "Command"
        case .file: "File change"
        case .permissions: "Permissions"
        }
    }

    var coveIcon: String {
        switch self {
        case .command: "terminal.fill"
        case .file: "doc.badge.gearshape"
        case .permissions: "lock.shield.fill"
        }
    }
}

// MARK: - Shared semantic presentation helpers

private extension CoveSessionStatus {
    var coveStatusIcon: String {
        switch self {
        case .waitingApproval, .blocked:
            "exclamationmark.shield.fill"
        case .waitingInput:
            "questionmark.bubble.fill"
        case .working, .active:
            "bolt.fill"
        case .compacting:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .interrupted:
            "pause.circle.fill"
        case .idle, .listening, .quiet, .hidden:
            "circle.fill"
        }
    }
}

private extension View {
    func coveOpaqueCard(theme: CoveThemePalette) -> some View {
        self
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: theme.surfaceHex))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(hex: theme.borderHex), lineWidth: 1)
            }
    }
}
