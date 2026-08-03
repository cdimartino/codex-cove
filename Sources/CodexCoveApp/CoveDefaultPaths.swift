import Foundation

enum CoveDefaultPaths {
    static var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Codex Cove/run", isDirectory: true)
            .appendingPathComponent("events.sock")
            .path
    }
}
