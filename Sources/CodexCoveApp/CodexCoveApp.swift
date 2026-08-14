import AppKit
import SwiftUI
import CoveCore

@main
struct CodexCoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "Codex Cove",
            systemImage: "water.waves",
            isInserted: .constant(!appDelegate.isMaintenanceLaunch)
        ) {
            CoveMenuBarView(
                store: appDelegate.store,
                showCove: appDelegate.showCove,
                showWorkspace: appDelegate.showWorkspace,
                collapseToMenuBar: appDelegate.collapseToMenuBar,
                restoreIsland: appDelegate.restoreIsland,
                showSettings: appDelegate.showSettings,
                showDoctor: appDelegate.showDoctor,
                showAbout: appDelegate.showAbout,
                restoreArchived: appDelegate.restoreArchivedSession
            )
        }
        .commands {
            CommandMenu("Workspace") {
                Button("Open Workspace") {
                    appDelegate.showWorkspace()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .accessibilityIdentifier("cove.command.workspace")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("cove.command.settings")
            }
            CommandGroup(replacing: .help) {
                Button("Codex Cove Help") {
                    NSWorkspace.shared.open(CoveHelp.userGuideURL)
                }
                .accessibilityIdentifier("cove.command.help")
                Button("Workspace Help") {
                    NSWorkspace.shared.open(CoveHelp.workspaceURL)
                }
                .accessibilityIdentifier("cove.command.workspace-help")
                Button("Settings Help") {
                    NSWorkspace.shared.open(CoveHelp.settingsURL)
                }
                .accessibilityIdentifier("cove.command.settings-help")
            }
        }
    }
}

private struct CoveMenuBarView: View {
    @ObservedObject var store: CoveStore
    let showCove: @MainActor () -> Void
    let showWorkspace: @MainActor () -> Void
    let collapseToMenuBar: @MainActor () -> Void
    let restoreIsland: @MainActor () -> Void
    let showSettings: @MainActor () -> Void
    let showDoctor: @MainActor () -> Void
    let showAbout: @MainActor () -> Void
    let restoreArchived: @MainActor (String?) -> Void

    var body: some View {
        Button("Show Cove", action: showCove)
            .accessibilityLabel("Show Cove")
            .accessibilityIdentifier("cove.menubar.show")

        Button("Open Workspace…", action: showWorkspace)
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .accessibilityLabel("Open Workspace")
            .accessibilityIdentifier("cove.menubar.workspace")

        if store.state.settings.minimalIslandMode {
            Button("Restore Island", action: restoreIsland)
                .accessibilityLabel("Restore Island")
                .accessibilityIdentifier("cove.menubar.restore-island")
        } else {
            Button("Collapse to Menu Bar", action: collapseToMenuBar)
                .accessibilityLabel("Collapse to Menu Bar")
                .accessibilityIdentifier("cove.menubar.collapse")
        }

        if !store.state.dismissedSessionIDs.isEmpty {
            Menu("Archived Sessions") {
                ForEach(
                    Array(store.state.dismissedSessionIDs.enumerated()),
                    id: \.element
                ) { index, sessionID in
                    Button("Restore archived task \(index + 1)") {
                        restoreArchived(sessionID)
                    }
                    .accessibilityLabel("Restore archived task \(index + 1)")
                    .accessibilityIdentifier(
                        CoveAccessibilityIDs.session(
                            "menubar-archived-restore",
                            sessionID: sessionID
                        )
                    )
                }
                Divider()
                Button("Restore All Archived Tasks") {
                    restoreArchived(nil)
                }
                .accessibilityLabel("Restore all archived tasks")
                .accessibilityIdentifier("cove.menubar.archived.restore-all")
            }
            .accessibilityLabel("Archived tasks")
            .accessibilityIdentifier("cove.menubar.archived.menu")
        }

        Divider()

        Button("Settings…", action: showSettings)
            .keyboardShortcut(",", modifiers: [.command])
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("cove.menubar.settings")
        Button("Doctor…", action: showDoctor)
            .accessibilityLabel("Doctor")
            .accessibilityIdentifier("cove.menubar.doctor")
        Link("Help…", destination: CoveHelp.userGuideURL)
            .accessibilityLabel("Codex Cove Help")
            .accessibilityIdentifier("cove.menubar.help")
        Button("About Codex Cove", action: showAbout)
            .accessibilityLabel("About Codex Cove")
            .accessibilityIdentifier("cove.menubar.about")

        Divider()

        Picker(
            "Privacy",
            selection: Binding(
                get: { store.state.settings.privacyMode },
                set: { store.dispatch(.setPrivacy($0)) }
            )
        ) {
            ForEach(CovePrivacyMode.allCases, id: \.self) { mode in
                Text(mode.rawValue.capitalized)
                    .tag(mode)
                    .accessibilityLabel("\(mode.rawValue.capitalized) privacy")
                    .accessibilityIdentifier(
                        "cove.menubar.privacy.\(mode.rawValue)"
                    )
            }
        }
        .accessibilityLabel("Privacy mode")
        .accessibilityIdentifier("cove.menubar.privacy")

        Toggle(
            "Mute Sounds",
            isOn: Binding(
                get: { !store.state.settings.playSounds },
                set: { store.dispatch(.setSounds(!$0)) }
            )
        )
        .accessibilityLabel("Mute Sounds")
        .accessibilityIdentifier("cove.menubar.mute-sounds")

        Divider()

        Button("Quit Codex Cove") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
        .accessibilityLabel("Quit Codex Cove")
        .accessibilityIdentifier("cove.menubar.quit")
    }
}
