import Darwin
import Foundation
import CoveCore

/// Keeps the app UI and `codex-cove privacy` management command on the same
/// user-local privacy value without giving either side permission to rewrite
/// the other's unrelated configuration fields.
struct CoveSharedPrivacyBridge {
    let configurationURL: URL

    init(
        configurationURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Codex Cove/helper-config.json"
            )
    ) {
        self.configurationURL = configurationURL
    }

    func load() throws -> CovePrivacyMode? {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return nil
        }
        try requireRegularFile(configurationURL)
        let data = try Data(contentsOf: configurationURL)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let rawMode = object["privacy"] as? String else { return nil }
        return mode(from: rawMode)
    }

    func save(_ mode: CovePrivacyMode) throws {
        // A development build may run before the helper is installed. Do not
        // manufacture a partial helper config that the Rust decoder would
        // correctly reject; normal app settings remain authoritative there.
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return
        }
        try requireRegularFile(configurationURL)
        let existing = try Data(contentsOf: configurationURL)
        guard var object = try JSONSerialization.jsonObject(with: existing)
            as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object["privacy"] = wireValue(for: mode)

        let parent = configurationURL.deletingLastPathComponent()
        try requireOrCreatePrivateDirectory(parent)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configurationURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
    }

    func mode(from wireValue: String) -> CovePrivacyMode? {
        switch wireValue.lowercased() {
        case "auto":
            return .auto
        case "on":
            return .on
        case "off":
            return .off
        default:
            return nil
        }
    }

    private func wireValue(for mode: CovePrivacyMode) -> String {
        switch mode {
        case .auto:
            return "auto"
        case .on:
            return "on"
        case .off:
            return "off"
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0, information.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func requireOrCreatePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
