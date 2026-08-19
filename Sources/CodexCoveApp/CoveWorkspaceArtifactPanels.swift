import AppKit

@MainActor
enum CoveWorkspaceArtifactPanels {
    static func chooseFilesAndDirectories() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add Workspace Artifacts"
        panel.prompt = "Add"
        panel.message = "Choose local files or folders to attach to this Codex task."
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
