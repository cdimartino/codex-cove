import AppKit
import Foundation
import SwiftUI
import CoveCore

private enum CoveSettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case residents
    case general
    case notifications
    case sounds
    case privacyAndQuiet
    case sessions

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .appearance:
            "Appearance"
        case .residents:
            "Residents"
        case .general:
            "General"
        case .notifications:
            "Notifications"
        case .sounds:
            "Sounds"
        case .privacyAndQuiet:
            "Privacy & Quiet"
        case .sessions:
            "Sessions & Data"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .appearance:
            "Theme, transparency, blur, and live preview."
        case .residents:
            "Automatically assigned visual companions, motion, and status callouts."
        case .general:
            "Startup, usage, and interaction behavior."
        case .notifications:
            "Choose alert types and exactly which details they reveal."
        case .sounds:
            "Choose sounds and volume for each task event."
        case .privacyAndQuiet:
            "Redaction, quiet hours, and project silence rules."
        case .sessions:
            "Island behavior, archived tasks, and local activity."
        }
    }

    var systemImage: String {
        switch self {
        case .appearance:
            "paintpalette"
        case .residents:
            "person.3.fill"
        case .general:
            "switch.2"
        case .notifications:
            "bell.badge"
        case .sounds:
            "speaker.wave.2"
        case .privacyAndQuiet:
            "hand.raised"
        case .sessions:
            "rectangle.stack"
        }
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: CoveStore
    let onRestoreArchived: @MainActor (String?) -> Void
    private let importedSoundStore: CoveImportedSoundStore
    private let externalSideEffectsEnabled: Bool
    @State private var themeAlertMessage: String?
    @State private var selectedPane: CoveSettingsPane? = .appearance
    @State private var selectedNotificationKind: CoveNotificationEventKind = .approval
    @State private var residentPreviewStatus: CoveSessionStatus = .working
    @State private var customThemeDraft: CoveThemePalette

    init(
        store: CoveStore,
        onRestoreArchived: @escaping @MainActor (String?) -> Void,
        initialPaneIdentifier: String? = nil,
        importedSoundStore: CoveImportedSoundStore = .applicationSupportStore(),
        externalSideEffectsEnabled: Bool = true
    ) {
        self.store = store
        self.onRestoreArchived = onRestoreArchived
        self.importedSoundStore = importedSoundStore
        self.externalSideEffectsEnabled = externalSideEffectsEnabled
        _selectedPane = State(
            initialValue: initialPaneIdentifier
                .flatMap(CoveSettingsPane.init(rawValue:))
                ?? .appearance
        )
        _customThemeDraft = State(initialValue: Self.themeDraft(from: store))
    }

    var body: some View {
        NavigationSplitView {
            List(CoveSettingsPane.allCases, selection: $selectedPane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.systemImage)
                }
                .tag(pane)
                .accessibilityIdentifier("settings.sidebar.\(pane.rawValue)")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: 170 + 90 * (store.state.settings.textScale - 1),
                ideal: 190 + 100 * (store.state.settings.textScale - 1),
                max: 220 + 120 * (store.state.settings.textScale - 1)
            )
        } detail: {
            settingsPane(for: selectedPane ?? .appearance)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: 720 + 260 * (store.state.settings.textScale - 1),
            minHeight: 520 + 160 * (store.state.settings.textScale - 1)
        )
        .coveSystemFont(size: 13)
        .coveTextScale(store.state.settings.textScale)
        .accessibilityIdentifier("settings.window")
        .onChange(of: store.state.theme) { _, _ in
            customThemeDraft = Self.themeDraft(from: store)
        }
        .overlay(alignment: .topLeading) {
            if !externalSideEffectsEnabled {
                Text(
                    String(
                        format: "%.2f",
                        store.state.settings.textScale
                    )
                )
                .font(.system(size: 1))
                .lineLimit(1)
                .frame(width: 1, height: 1)
                .clipped()
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityIdentifier("settings.fixture.text-scale")
            }
        }
        .alert(
            "Theme",
            isPresented: Binding(
                get: { themeAlertMessage != nil },
                set: { if !$0 { themeAlertMessage = nil } }
            )
        ) {
            Button("OK") {
                themeAlertMessage = nil
            }
            .accessibilityIdentifier("settings.theme-alert.dismiss")
        } message: {
            Text(themeAlertMessage ?? "")
        }
    }

    @ViewBuilder
    private func settingsPane(for pane: CoveSettingsPane) -> some View {
        settingsPaneContainer(pane: pane) {
            switch pane {
            case .appearance:
                appearanceSettings
            case .residents:
                residentSettings
            case .general:
                generalSettings
            case .notifications:
                notificationSettings
            case .sounds:
                soundSettings
            case .privacyAndQuiet:
                privacyAndQuietSettings
            case .sessions:
                sessionSettings
            }
        }
    }

    @ViewBuilder
    private var residentSettings: some View {
        Section("Preview") {
            Picker("Character set", selection: residentSetBinding) {
                ForEach(CoveResidentSet.allCases, id: \.self) { set in
                    Text(set.displayName).tag(set)
                }
            }
            .accessibilityIdentifier("settings.residents.character-set")

            Picker("Task state", selection: $residentPreviewStatus) {
                ForEach(Self.residentPreviewStatuses, id: \.self) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .accessibilityIdentifier("settings.residents.preview-state")
            Text("Cove automatically assigns each task a resident from the selected set. The gallery previews that set; individual residents are not selected per task.")
                .coveSystemFont(size: 12)
                .accessibilityIdentifier("settings.residents.assignment-description")
            Text(
                residentPreviewStatus == .working || residentPreviewStatus == .compacting
                    ? "Active residents animate with character-specific activities."
                    : "Attention and terminal states freeze on an icon-integrated callout."
            )
            .coveSystemFont(size: 11)
            .foregroundStyle(.secondary)
        }

        Section("Resident library") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: 12)],
                spacing: 12
            ) {
                ForEach(
                    Array(store.state.settings.residentSet.archetypes.enumerated()),
                    id: \.element
                ) { index, archetype in
                    let character = CovePixelCharacter(
                        archetype: archetype,
                        variation: index % 4
                    )
                    VStack(spacing: 8) {
                        CovePixelCharacterView(
                            character: character,
                            status: residentPreviewStatus,
                            palette: CovePixelCharacterPalette(
                                theme: store.state.theme,
                                status: residentPreviewStatus,
                                character: character
                            ),
                            size: 56,
                            reduceMotion: reduceMotion
                        )
                        Text(archetype.displayName)
                            .coveSystemFont(size: 11, weight: .medium)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: store.state.theme.surfaceHex).opacity(0.72))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                Color(hex: store.state.theme.borderHex).opacity(0.5),
                                lineWidth: 1
                            )
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(archetype.displayName) resident preview")
                    .accessibilityIdentifier(
                        "settings.residents.preview.\(archetype.rawValue)"
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private static let residentPreviewStatuses: [CoveSessionStatus] = [
        .working,
        .compacting,
        .waitingApproval,
        .waitingInput,
        .completed,
        .failed,
        .interrupted,
    ]

    private func settingsPaneContainer<Content: View>(
        pane: CoveSettingsPane,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .coveSystemFont(size: 20, weight: .semibold)
                    .accessibilityIdentifier("settings.pane.\(pane.rawValue).title")
                Text(pane.subtitle)
                    .coveSystemFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                Form {
                    content()
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 600, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            // SwiftUI otherwise reuses the detail ScrollView when the sidebar
            // selection changes and carries the previous pane's deep offset
            // into the next pane. A pane-specific identity starts each newly
            // selected page at its heading and first control.
            .id(pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var appearanceSettings: some View {
        Section("Text") {
            CovePrecisionControlRow(
                "Text size",
                value: textScaleBinding,
                in: CoveSettings.textScaleRange,
                step: 0.05,
                unit: "%",
                displayScale: 100,
                accessibilityIdentifier: "settings.appearance.text-scale"
            )
            Text("Scales Cove and Settings text from 100% to 200%. Layouts reflow as text grows.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }

        Section("Theme") {
            Picker("Style family", selection: themeBinding) {
                ForEach(CoveThemeFamily.allCases, id: \.self) { family in
                    Text(family.rawValue).tag(family)
                }
            }
            .accessibilityIdentifier("settings.appearance.theme-family")

            Picker("Palette", selection: paletteBinding) {
                ForEach(CovePaletteKind.allCases, id: \.self) { palette in
                    Text(palette.rawValue).tag(palette)
                }
            }
            .accessibilityIdentifier("settings.appearance.palette")

            Picker("Custom theme", selection: customThemeBinding) {
                Text("Use built-in selection")
                    .tag(nil as String?)
                ForEach(store.customThemes) { theme in
                    Text(theme.name)
                        .tag(Optional(theme.identifier))
                }
            }
            .accessibilityIdentifier("settings.appearance.custom-theme")

            HStack {
                Button("Import Theme…") {
                    importTheme()
                }
                .disabled(!externalSideEffectsEnabled)
                .accessibilityIdentifier("settings.appearance.import-theme")
                Button("Export Selected…") {
                    exportSelectedTheme()
                }
                .disabled(!externalSideEffectsEnabled)
                .accessibilityIdentifier("settings.appearance.export-theme")
                Spacer()
                if let selectedCustomTheme {
                    Button("Remove Custom Theme", role: .destructive) {
                        removeCustomTheme(selectedCustomTheme)
                    }
                    .accessibilityIdentifier("settings.appearance.remove-theme")
                }
            }

        }

        Section("Custom theme colors") {
            TextField("Theme name", text: customThemeNameBinding)
                .accessibilityIdentifier("settings.appearance.custom-theme-name")

            Picker("Surface fill", selection: surfaceFillBinding) {
                ForEach(CoveThemeSurfaceFill.allCases, id: \.self) { fill in
                    Text(fill.rawValue.capitalized).tag(fill)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance.surface-fill")

            themeColorPicker(
                customThemeDraft.surfaceFill == .solid
                    ? "Solid color"
                    : "Gradient start",
                \.backgroundHex,
                id: "background"
            )
            themeColorPicker(
                customThemeDraft.surfaceFill == .gradient
                    ? "Gradient end / Accent"
                    : "Accent",
                \.accentHex,
                id: "accent"
            )
            themeColorPicker("Surface", \.surfaceHex, id: "surface")
            themeColorPicker("Primary text", \.foregroundHex, id: "primary-text")
            themeColorPicker("Muted text", \.mutedTextHex, id: "muted-text")
            themeColorPicker("Working", \.workingHex, id: "working")
            themeColorPicker(
                "Waiting for approval",
                \.waitingApprovalHex,
                id: "waiting-approval"
            )
            themeColorPicker(
                "Waiting for input",
                \.waitingInputHex,
                id: "waiting-input"
            )
            themeColorPicker("Compacting", \.compactingHex, id: "compacting")
            themeColorPicker("Completed", \.completedHex, id: "completed")
            themeColorPicker("Failed", \.failedHex, id: "failed")
            themeColorPicker("Interrupted", \.interruptedHex, id: "interrupted")
            themeColorPicker("Idle", \.idleHex, id: "idle")
            themeColorPicker("Border", \.borderHex, id: "border")
            themeColorPicker("Shadow", \.shadowHex, id: "shadow")

            if customThemeContrastViolationCount > 0 {
                Label(
                    "Some text or status colors do not meet accessible contrast requirements.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .accessibilityIdentifier("settings.appearance.custom-theme-contrast-warning")
            }

            HStack {
                Button("Save Custom Theme") {
                    saveCustomTheme()
                }
                .disabled(
                    customThemeDraft.name
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
                .accessibilityIdentifier("settings.appearance.save-custom-theme")
                Button("Reset from Selected") {
                    customThemeDraft = Self.themeDraft(from: store)
                    store.clearThemePreview()
                }
                .accessibilityIdentifier("settings.appearance.reset-custom-theme")
            }

            CoveThemePreview(
                theme: configuredThemeDraft,
                collapsedOpacity: store.state.settings.collapsedOpacity,
                expandedOpacity: store.state.settings.expandedOpacity,
                blur: store.state.settings.blurStyle,
                privacy: store.state.settings.privacyMode,
                squareTopCorners: store.state.settings.squareTopCorners
            )
        }
        .onAppear {
            NSColorPanel.shared.mode = .wheel
        }

        Section("Surface") {
            Picker("Opacity preset", selection: opacityBinding) {
                ForEach(CoveOpacityStyle.allCases, id: \.self) { style in
                    Text(style.rawValue.capitalized).tag(style)
                }
            }
            .accessibilityIdentifier("settings.appearance.opacity-preset")

            CovePrecisionControlRow(
                "Collapsed width",
                value: collapsedWidthBinding,
                in: CoveSettings.collapsedWidthRange,
                step: 2,
                unit: "pt",
                accessibilityIdentifier: "settings.appearance.collapsed-width"
            )
            Text(
                "Match the collapsed bubble to this Mac’s physical notch width. "
                    + "Visible depth scales with the final width (about "
                    + "\(Int(CoveOverlayGeometry.collapsedDepth(forWidth: store.state.settings.collapsedWidth).rounded())) pt here)."
            )
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)

            Toggle("Straight top edge", isOn: squareTopCornersBinding)
                .accessibilityIdentifier("settings.appearance.straight-top-edge")
            Text("Removes top corner rounding so Cove meets the screen edge seamlessly. Bottom corners keep the selected theme radius.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)

            CovePrecisionControlRow(
                "Collapsed opacity",
                value: collapsedOpacityBinding,
                in: 0.35 ... 1,
                step: 0.01,
                unit: "%",
                displayScale: 100,
                accessibilityIdentifier: "settings.appearance.collapsed-opacity"
            )

            CovePrecisionControlRow(
                "Expanded opacity",
                value: expandedOpacityBinding,
                in: 0.35 ... 1,
                step: 0.01,
                unit: "%",
                displayScale: 100,
                accessibilityIdentifier: "settings.appearance.expanded-opacity"
            )

            Picker("Blur", selection: blurBinding) {
                ForEach(CoveBlurStyle.allCases, id: \.self) { style in
                    Text(style.rawValue.capitalized).tag(style)
                }
            }
            .accessibilityIdentifier("settings.appearance.blur")

            Toggle("Animate expansion and hiding", isOn: panelAnimationBinding)
                .accessibilityIdentifier("settings.appearance.animate-panel")
            CovePrecisionControlRow(
                "Slide duration",
                value: panelAnimationDurationBinding,
                in: 0.08 ... 0.8,
                step: 0.02,
                unit: "ms",
                displayScale: 1_000,
                accessibilityIdentifier: "settings.appearance.slide-duration"
            )
            .disabled(!store.state.settings.panelAnimationEnabled)
            Text("The top edge and width stay fixed while Cove slides open downward and closes upward. Reduce Motion disables the effect.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var generalSettings: some View {
        Section("App") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .accessibilityIdentifier("settings.general.launch-at-login")
            Toggle("Enable global shortcuts", isOn: shortcutsBinding)
                .accessibilityIdentifier("settings.general.global-shortcuts")
            Toggle("Glance mode", isOn: glanceModeBinding)
                .accessibilityIdentifier("settings.general.glance-mode")
        }

        Section("Usage") {
            Toggle("Show account usage", isOn: showUsageBinding)
                .accessibilityIdentifier("settings.general.show-usage")
            Toggle("Show usage remaining", isOn: usageRemainingBinding)
                .disabled(!store.state.settings.showUsage)
                .accessibilityIdentifier("settings.general.usage-remaining")
            Toggle(
                "Show profile token usage",
                isOn: showProfileTokenUsageBinding
            )
            .accessibilityIdentifier("settings.general.profile-token-usage")
            Toggle("Show per-task token metrics", isOn: showTokenMetricsBinding)
                .accessibilityIdentifier("settings.general.task-token-metrics")
            Text("Profile totals use only the public account/usage/read response. Per-task metrics use only public thread/tokenUsage/updated values. Cove labels missing or stale data and never scrapes Codex UI or private files.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }

        Section("Interaction") {
            CovePrecisionControlRow(
                "Hover delay",
                value: hoverDelayBinding,
                in: 0 ... 3,
                step: 0.05,
                unit: "s",
                fractionDigits: 2,
                accessibilityIdentifier: "settings.general.hover-delay"
            )

            CovePrecisionControlRow(
                "Collapse after hover leaves",
                value: autoCollapseBinding,
                in: 1 ... 30,
                step: 1,
                unit: "s",
                accessibilityIdentifier: "settings.general.collapse-delay"
            )
            Text("The countdown starts only after the pointer and keyboard focus leave Cove. Events and requests never expand the island automatically.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)

            CovePrecisionControlRow(
                "Idle auto-hide",
                value: idleAutoHideBinding,
                in: 0 ... 3_600,
                step: 5,
                unit: "s",
                accessibilityIdentifier: "settings.general.idle-auto-hide"
            )

            Button("Reset Interaction Defaults") {
                store.dispatch(.setHoverDelay(0.25))
                store.dispatch(.setAutoCollapseDelay(6))
                store.dispatch(.setIdleAutoHideDelay(0))
            }
            .accessibilityHint("Resets only hover, collapse, and idle auto-hide timings.")
            .accessibilityIdentifier("settings.general.reset-interaction-defaults")

            Picker("One-shot follow-up", selection: reminderDelayBinding) {
                Text("5 minutes").tag(5.0 * 60)
                Text("10 minutes").tag(10.0 * 60)
                Text("30 minutes").tag(30.0 * 60)
                Text("1 hour").tag(60.0 * 60)
            }
            .accessibilityIdentifier("settings.general.follow-up-delay")
        }
    }

    @ViewBuilder
    private var notificationSettings: some View {
        Section("System Banners") {
            Toggle("Show Codex Cove notifications", isOn: notificationsBinding)
                .accessibilityIdentifier("settings.notifications.global-enabled")
            Text("Notifications are grouped by task and turn. Anything from before the current Cove launch is discarded; the task remains available in Cove and Codex.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }

        Section("Event and Content") {
            if store.state.settings.textScale >= 1.5 {
                notificationCards
            } else {
                notificationGrid
            }
            Text("Manual or automatic privacy redaction overrides these choices. Commands, paths, prompts, answers, and diffs are never added unless an event detail explicitly contains them and Event detail is enabled.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }

        Section("Live Preview") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(selectedNotificationKind.matrixDisplayName)
                        .coveSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !selectedNotificationRule.enabled {
                        Label("Disabled", systemImage: "bell.slash")
                            .coveSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(notificationPreview.title)
                    .coveSystemFont(size: 13, weight: .semibold)
                    .accessibilityIdentifier("settings.notifications.preview.title")
                Text(
                    notificationPreview.body.isEmpty
                        ? String(localized: "No banner body content selected.")
                        : notificationPreview.body
                )
                .foregroundStyle(notificationPreview.body.isEmpty ? .secondary : .primary)
                .accessibilityIdentifier("settings.notifications.preview.body")

                if let notificationPreviewRedactionDescription {
                    Label(
                        notificationPreviewRedactionDescription,
                        systemImage: "eye.slash"
                    )
                    .coveSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "settings.notifications.preview.privacy-override"
                    )
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.notifications.preview")
        }
    }

    private var notificationGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Event")
                Text("Enabled")
                Text("Task title")
                Text("Detail")
                Text("Project")
                Text("Source")
                Text("Host")
            }
            .coveSystemFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)

            Divider()
                .gridCellColumns(7)

            ForEach(CoveNotificationEventKind.allCases, id: \.self) { kind in
                GridRow {
                    notificationSelectionButton(kind)
                    notificationCell(kind, "Enabled", \.enabled)
                    notificationCell(kind, "Task title", \.includesTaskTitle)
                    notificationCell(kind, "Detail", \.includesDetail)
                    notificationCell(kind, "Project", \.includesProject)
                    notificationCell(kind, "Source", \.includesSource)
                    notificationCell(kind, "Host", \.includesHost)
                }
            }
        }
    }

    private var notificationCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(CoveNotificationEventKind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 10) {
                    notificationSelectionButton(kind)
                    Divider()
                    notificationCardRow(kind, "Enabled", \.enabled)
                    notificationCardRow(
                        kind,
                        "Task title",
                        \.includesTaskTitle
                    )
                    notificationCardRow(kind, "Detail", \.includesDetail)
                    notificationCardRow(kind, "Project", \.includesProject)
                    notificationCardRow(kind, "Source", \.includesSource)
                    notificationCardRow(kind, "Host", \.includesHost)
                }
                .padding(12)
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

    private func notificationSelectionButton(
        _ kind: CoveNotificationEventKind
    ) -> some View {
        Button {
            selectedNotificationKind = kind
        } label: {
            Text(kind.matrixDisplayName)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            selectedNotificationKind == kind
                ? Color.accentColor.opacity(0.14)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .accessibilityLabel(
            "Select \(kind.matrixDisplayName) notification preview"
        )
        .accessibilityIdentifier(
            "settings.notifications.\(kind.rawValue).select"
        )
    }

    private func notificationCardRow(
        _ kind: CoveNotificationEventKind,
        _ contentName: String,
        _ keyPath: WritableKeyPath<CoveNotificationRule, Bool>
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(contentName)
                .frame(maxWidth: .infinity, alignment: .leading)
            notificationCell(kind, contentName, keyPath)
        }
    }

    private func notificationCell(
        _ kind: CoveNotificationEventKind,
        _ contentName: String,
        _ keyPath: WritableKeyPath<CoveNotificationRule, Bool>
    ) -> some View {
        Toggle(
            "\(kind.matrixDisplayName), \(contentName)",
            isOn: notificationRuleBinding(for: kind, keyPath)
        )
        .labelsHidden()
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(kind.matrixDisplayName), \(contentName)")
        .accessibilityIdentifier(
            "settings.notifications.\(kind.rawValue).\(contentName.accessibilityComponent)"
        )
    }

    private var selectedNotificationRule: CoveNotificationRule {
        store.state.settings.notificationPreferences.rule(
            for: selectedNotificationKind
        )
    }

    private var notificationPreview: CoveNotificationPresentation {
        CoveNotificationPresentationBuilder.presentation(
            kind: selectedNotificationKind,
            rule: selectedNotificationRule,
            context: CoveNotificationDisplayContext(
                taskTitle: "Refine Codex Cove settings",
                detail: "Codex is ready for your review.",
                project: "Codex Cove",
                source: "Codex Desktop",
                host: "Studio Mac"
            ),
            redactsSensitiveContent: notificationPreviewIsRedacted,
            genericBodyWhenEmpty: "Open Codex Cove to review."
        )
    }

    private var notificationPreviewIsRedacted: Bool {
        store.state.settings.privacyMode == .on
            || store.state.privacyScene != .normal
    }

    private var notificationPreviewRedactionDescription: String? {
        if store.state.settings.privacyMode == .on {
            return String(
                localized: "Privacy is On, so content choices are hidden in the delivered banner."
            )
        }
        switch store.state.privacyScene {
        case .normal:
            return nil
        case .redacted:
            return String(
                localized: "Automatic privacy protection is active, so content choices are hidden in the delivered banner."
            )
        case .locked:
            return String(
                localized: "The Mac is locked, so content choices are hidden in the delivered banner."
            )
        }
    }

    private var soundSettings: some View {
        CoveSoundSettingsSection(
            globallyEnabled: store.state.settings.playSounds,
            preferences: store.soundPreferences,
            importedSoundStore: importedSoundStore,
            sideEffectsEnabled: externalSideEffectsEnabled,
            onGloballyEnabledChanged: {
                store.dispatch(.setSounds($0))
            },
            onPreferencesChanged: {
                store.updateSoundPreferences($0)
            }
        )
    }

    @ViewBuilder
    private var privacyAndQuietSettings: some View {
        Section("Privacy") {
            Picker("Privacy", selection: privacyBinding) {
                ForEach(CovePrivacyMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.privacy.mode")
            Toggle(
                "Conservative capture-app privacy",
                isOn: conservativeCapturePrivacyBinding
            )
            .accessibilityIdentifier("settings.privacy.conservative-capture")
            Text("When Privacy is Auto, redact while a known conferencing or recording app is running. This does not prove that recording is active.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }

        Section("Quiet Hours") {
            Toggle("Enable quiet hours", isOn: quietHoursEnabledBinding)
                .accessibilityIdentifier("settings.privacy.quiet-hours-enabled")
            DatePicker(
                "Starts",
                selection: quietStartBinding,
                displayedComponents: .hourAndMinute
            )
            .disabled(!store.state.settings.quietHours.enabled)
            .accessibilityIdentifier("settings.privacy.quiet-hours-start")
            DatePicker(
                "Ends",
                selection: quietEndBinding,
                displayedComponents: .hourAndMinute
            )
            .disabled(!store.state.settings.quietHours.enabled)
            .accessibilityIdentifier("settings.privacy.quiet-hours-end")
            Text("Quiet hours can cross midnight. Matching sounds and notifications are suppressed; approval and input cards stay visible.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }

        Section("Focus") {
            Toggle(
                "Follow focused app",
                isOn: followFocusedAppBinding
            )
            .accessibilityIdentifier("settings.privacy.follow-focused-app")
            Text("When enabled, Cove stays quiet while another app is frontmost.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)

            CoveProjectTokenEditor(
                tokens: silencedProjectRulesBinding,
                suggestions: silencedProjectSuggestions,
                accessibilityIdentifier: "settings.privacy.silenced-projects"
            )
            Text("Press Return or comma to add a rule. Suggestions come only from current in-memory local task identities and are never saved unless you choose one.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sessionSettings: some View {
        Section("Island") {
            Toggle("Minimal island / menu-bar mode", isOn: minimalIslandBinding)
                .accessibilityIdentifier("settings.sessions.minimal-island")
            Text("Shows a small themed status cue without task text. Waiting approval and input counts remain visible; restore the full island from the menu bar.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)

            Button(store.state.session.isExpanded ? "Collapse overlay" : "Expand overlay") {
                if store.state.session.isExpanded {
                    store.dispatch(.setExpanded(false))
                } else {
                    store.beginOverlayInteraction()
                }
            }
            .disabled(store.state.settings.minimalIslandMode)
            .accessibilityIdentifier("settings.sessions.toggle-overlay")
        }

        Section("Archived Tasks") {
            if store.state.dismissedSessionIDs.isEmpty {
                Text("No archived tasks")
                    .foregroundStyle(.secondary)
            } else {
                Menu("Review Archived Tasks") {
                    ForEach(
                        Array(store.state.dismissedSessionIDs.enumerated()),
                        id: \.element
                    ) { index, sessionID in
                        Button("Restore archived task \(index + 1)") {
                            onRestoreArchived(sessionID)
                        }
                        .accessibilityLabel("Restore archived task \(index + 1)")
                        .accessibilityIdentifier(
                            CoveAccessibilityIDs.session(
                                "settings-archived-restore",
                                sessionID: sessionID
                            )
                        )
                    }
                    Divider()
                    Button("Restore All Archived Tasks") {
                        onRestoreArchived(nil)
                    }
                    .accessibilityLabel("Restore all archived tasks")
                    .accessibilityIdentifier("settings.sessions.archived.restore-all")
                }
                .accessibilityLabel("Review archived tasks")
                .accessibilityIdentifier("settings.sessions.archived.menu")
                Text("Dismissed tasks stay recoverable until restored.")
                    .coveSystemFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Diagnostics") {
            Button("Clear recent events") {
                store.dispatch(.clearRecentEvents)
            }
            .disabled(store.state.recentEvents.isEmpty)
            .accessibilityIdentifier("settings.sessions.clear-recent-events")
        }
    }

    private static func themeDraft(from store: CoveStore) -> CoveThemePalette {
        var theme = store.state.theme
        theme.collapsedOpacity = store.state.settings.collapsedOpacity
        theme.expandedOpacity = store.state.settings.expandedOpacity
        theme.blurStyle = store.state.settings.blurStyle
        if theme.isBuiltIn {
            theme.name += " Custom"
        }
        return theme
    }

    private var configuredThemeDraft: CoveThemePalette {
        var theme = customThemeDraft
        theme.collapsedOpacity = store.state.settings.collapsedOpacity
        theme.expandedOpacity = store.state.settings.expandedOpacity
        theme.blurStyle = store.state.settings.blurStyle
        return theme
    }

    private var customThemeContrastViolationCount: Int {
        let theme = configuredThemeDraft
        let contexts = CoveThemeContrastMatrix.defaultContexts(for: theme)
        var violations = CoveThemeContrastMatrix.violations(
            theme: theme,
            contexts: contexts
        )
        if theme.surfaceFill == .gradient {
            var endpoint = theme
            endpoint.backgroundHex = theme.accentHex
            violations += CoveThemeContrastMatrix.violations(
                theme: endpoint,
                contexts: contexts,
                pairs: CoveSemanticContrastPair.overlay.filter {
                    $0.background == .background
                }
            )
        }
        return violations.count
    }

    private func themeColorPicker(
        _ title: String,
        _ keyPath: WritableKeyPath<CoveThemePalette, String>,
        id: String
    ) -> some View {
        ColorPicker(
            title,
            selection: Binding(
                get: { Color(hex: customThemeDraft[keyPath: keyPath]) },
                set: { color in
                    var draft = customThemeDraft
                    draft[keyPath: keyPath] = color.hex
                    customThemeDraft = draft
                    store.previewTheme(configuredTheme(draft))
                }
            ),
            supportsOpacity: false
        )
        .accessibilityIdentifier("settings.appearance.color.\(id)")
    }

    private var themeBinding: Binding<CoveThemeFamily> {
        Binding(
            get: { store.state.settings.themeFamily },
            set: {
                store.clearThemePreview()
                store.dispatch(.setThemeFamily($0))
            }
        )
    }

    private var surfaceFillBinding: Binding<CoveThemeSurfaceFill> {
        Binding(
            get: { customThemeDraft.surfaceFill },
            set: { fill in
                var draft = customThemeDraft
                draft.surfaceFill = fill
                customThemeDraft = draft
                store.previewTheme(configuredTheme(draft))
            }
        )
    }

    private var customThemeNameBinding: Binding<String> {
        Binding(
            get: { customThemeDraft.name },
            set: { name in
                var draft = customThemeDraft
                draft.name = name
                customThemeDraft = draft
                store.previewTheme(configuredTheme(draft))
            }
        )
    }

    private var residentSetBinding: Binding<CoveResidentSet> {
        Binding(
            get: { store.state.settings.residentSet },
            set: { store.dispatch(.setResidentSet($0)) }
        )
    }

    private var opacityBinding: Binding<CoveOpacityStyle> {
        Binding(
            get: { store.state.settings.opacityStyle },
            set: { store.dispatch(.setOpacity($0)) }
        )
    }

    private var paletteBinding: Binding<CovePaletteKind> {
        Binding(
            get: { store.state.settings.palette },
            set: {
                store.clearThemePreview()
                store.dispatch(.setPalette($0))
            }
        )
    }

    private var customThemeBinding: Binding<String?> {
        Binding(
            get: { store.state.settings.customThemeID },
            set: { store.selectCustomTheme(identifier: $0) }
        )
    }

    private func configuredTheme(_ draft: CoveThemePalette) -> CoveThemePalette {
        var theme = draft
        theme.collapsedOpacity = store.state.settings.collapsedOpacity
        theme.expandedOpacity = store.state.settings.expandedOpacity
        theme.blurStyle = store.state.settings.blurStyle
        return theme
    }

    private var selectedCustomTheme: CoveThemePalette? {
        guard let identifier = store.state.settings.customThemeID else {
            return nil
        }
        return store.customThemes.first { $0.identifier == identifier }
    }

    private func saveCustomTheme() {
        do {
            let theme = try store.saveCustomTheme(
                configuredThemeDraft,
                named: customThemeDraft.name
            )
            customThemeDraft = theme
            themeAlertMessage = "Saved and selected “\(theme.name)”."
        } catch {
            themeAlertMessage = error.localizedDescription
        }
    }

    private func importTheme() {
        guard externalSideEffectsEnabled else { return }
        guard let url = CoveThemeFilePanels.chooseThemeToImport() else {
            return
        }
        do {
            let theme = try store.importCustomTheme(from: url)
            themeAlertMessage = "Imported and selected “\(theme.name)”."
        } catch {
            themeAlertMessage = error.localizedDescription
        }
    }

    private func exportSelectedTheme() {
        guard externalSideEffectsEnabled else { return }
        let theme = store.state.theme
        guard let url = CoveThemeFilePanels.chooseThemeExportDestination(
            for: theme
        ) else {
            return
        }
        do {
            try store.exportTheme(theme, to: url)
            themeAlertMessage = "Exported “\(theme.name)”."
        } catch {
            themeAlertMessage = error.localizedDescription
        }
    }

    private func removeCustomTheme(_ theme: CoveThemePalette) {
        do {
            try store.removeCustomTheme(theme)
            themeAlertMessage = "Removed “\(theme.name)”."
        } catch {
            themeAlertMessage = error.localizedDescription
        }
    }

    private var collapsedOpacityBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.collapsedOpacity },
            set: { store.dispatch(.setCollapsedOpacity($0)) }
        )
    }

    private var textScaleBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.textScale },
            set: { store.dispatch(.setTextScale($0)) }
        )
    }

    private var collapsedWidthBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.collapsedWidth },
            set: { store.dispatch(.setCollapsedWidth($0)) }
        )
    }

    private var squareTopCornersBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.squareTopCorners },
            set: { store.dispatch(.setSquareTopCorners($0)) }
        )
    }

    private var panelAnimationBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.panelAnimationEnabled },
            set: { store.dispatch(.setPanelAnimationEnabled($0)) }
        )
    }

    private var panelAnimationDurationBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.panelAnimationDuration },
            set: { store.dispatch(.setPanelAnimationDuration($0)) }
        )
    }

    private func notificationRuleBinding(
        for kind: CoveNotificationEventKind,
        _ keyPath: WritableKeyPath<CoveNotificationRule, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: {
                store.state.settings.notificationPreferences
                    .rule(for: kind)[keyPath: keyPath]
            },
            set: { value in
                selectedNotificationKind = kind
                var rule = store.state.settings.notificationPreferences
                    .rule(for: kind)
                rule[keyPath: keyPath] = value
                store.dispatch(
                    .setNotificationRule(kind, rule)
                )
            }
        )
    }

    private var expandedOpacityBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.expandedOpacity },
            set: { store.dispatch(.setExpandedOpacity($0)) }
        )
    }

    private var blurBinding: Binding<CoveBlurStyle> {
        Binding(
            get: { store.state.settings.blurStyle },
            set: { store.dispatch(.setBlur($0)) }
        )
    }

    private var privacyBinding: Binding<CovePrivacyMode> {
        Binding(
            get: { store.state.settings.privacyMode },
            set: { store.dispatch(.setPrivacy($0)) }
        )
    }

    private var silencedProjectRulesBinding: Binding<[String]> {
        Binding(
            get: { store.state.settings.silencedProjectRules },
            set: { proposedRules in
                store.dispatch(
                    .setSilencedProjectRules(
                        CoveSilencedProjectRules.normalize(proposedRules)
                    )
                )
            }
        )
    }

    private var silencedProjectSuggestions: [String] {
        // Suggestions are derived from live task metadata. Privacy redaction
        // must cover Settings and its accessibility tree as well as the island.
        guard !notificationPreviewIsRedacted else { return [] }

        var candidates = store.state.session.snapshots
            .filter { $0.source != .remoteCli }
            .flatMap { snapshot -> [String] in
                [snapshot.title, snapshot.sessionId ?? snapshot.snapshotId]
            }

        if let envelope = store.state.session.lastEnvelope,
           envelope.source != .remoteCli {
            candidates.append(envelope.sessionId)
            candidates.append(envelope.displayEvent().title)
            if let project = projectIdentity(from: envelope) {
                candidates.append(project)
            }
        }
        return CoveSilencedProjectRules.normalize(candidates)
    }

    private func projectIdentity(from envelope: CoveWireEnvelope) -> String? {
        let object = envelope.payload.objectValue ?? [:]
        let nestedData = object["data"]?.objectValue ?? [:]
        guard let rawProject = object["project"]?.stringValue
            ?? object["projectName"]?.stringValue
            ?? nestedData["project"]?.stringValue
            ?? nestedData["cwd"]?.stringValue
            ?? nestedData["working_directory"]?.stringValue
        else { return nil }
        let trimmed = rawProject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.contains("/")
            ? URL(fileURLWithPath: trimmed).lastPathComponent
            : trimmed
    }

    private var conservativeCapturePrivacyBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.conservativeCapturePrivacy },
            set: { store.dispatch(.setConservativeCapturePrivacy($0)) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.launchAtLogin },
            set: { store.dispatch(.setLaunchAtLogin($0)) }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.showNotifications },
            set: { store.dispatch(.setNotifications($0)) }
        )
    }

    private var shortcutsBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.globalShortcutsEnabled },
            set: { store.dispatch(.setGlobalShortcuts($0)) }
        )
    }

    private var autoExpandBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.autoExpandOnEvent },
            set: { store.dispatch(.setAutoExpand($0)) }
        )
    }

    private var usageRemainingBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.usageShowsRemaining },
            set: { store.dispatch(.setUsageShowsRemaining($0)) }
        )
    }

    private var showUsageBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.showUsage },
            set: { store.dispatch(.setShowUsage($0)) }
        )
    }

    private var showProfileTokenUsageBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.showProfileTokenUsage },
            set: { store.dispatch(.setShowProfileTokenUsage($0)) }
        )
    }

    private var showTokenMetricsBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.showTokenMetrics },
            set: { store.dispatch(.setShowTokenMetrics($0)) }
        )
    }

    private var minimalIslandBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.minimalIslandMode },
            set: { store.dispatch(.setMinimalIslandMode($0)) }
        )
    }

    private var glanceModeBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.glanceMode },
            set: { store.dispatch(.setGlanceMode($0)) }
        )
    }

    private var hoverDelayBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.hoverDelaySeconds },
            set: { store.dispatch(.setHoverDelay($0)) }
        )
    }

    private var autoCollapseBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.autoCollapseSeconds },
            set: { store.dispatch(.setAutoCollapseDelay($0)) }
        )
    }

    private var idleAutoHideBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.idleAutoHideSeconds },
            set: { store.dispatch(.setIdleAutoHideDelay($0)) }
        )
    }

    private var reminderDelayBinding: Binding<Double> {
        Binding(
            get: { store.state.settings.followUpReminderSeconds },
            set: { store.dispatch(.setFollowUpReminderDelay($0)) }
        )
    }

    private var quietHoursEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.quietHours.enabled },
            set: { enabled in
                var value = store.state.settings.quietHours
                value.enabled = enabled
                store.dispatch(.setQuietHours(value))
            }
        )
    }

    private var quietStartBinding: Binding<Date> {
        quietTimeBinding(isStart: true)
    }

    private var quietEndBinding: Binding<Date> {
        quietTimeBinding(isStart: false)
    }

    private func quietTimeBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minute = isStart
                    ? store.state.settings.quietHours.startMinute
                    : store.state.settings.quietHours.endMinute
                return Calendar.current.date(
                    bySettingHour: minute / 60,
                    minute: minute % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                let minute = (components.hour ?? 0) * 60
                    + (components.minute ?? 0)
                var value = store.state.settings.quietHours
                if isStart {
                    value.startMinute = minute
                } else {
                    value.endMinute = minute
                }
                store.dispatch(.setQuietHours(value))
            }
        )
    }

    private var followFocusedAppBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.followFocusedApp },
            set: { store.dispatch(.setFollowFocusedApp($0)) }
        )
    }

}

private extension CoveNotificationEventKind {
    var matrixDisplayName: String {
        switch self {
        case .approval: String(localized: "Approval")
        case .input: String(localized: "Question/Input")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .interrupted: String(localized: "Interrupted")
        case .followUp: String(localized: "Follow-up")
        }
    }
}

private extension String {
    var accessibilityComponent: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
