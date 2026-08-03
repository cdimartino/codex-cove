import AppKit
import CoveCore
import UniformTypeIdentifiers

@MainActor
enum CoveThemeFilePanels {
    static func chooseThemeToImport() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Codex Cove Theme"
        panel.prompt = "Import"
        panel.message = "Choose a Codex Cove theme JSON file (maximum 1 MiB)."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseThemeExportDestination(
        for theme: CoveThemePalette
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Codex Cove Theme"
        panel.prompt = "Export"
        panel.message = "Export a versioned theme JSON file."
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(theme.identifier).json"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
