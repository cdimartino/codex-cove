import Darwin
import Foundation

public struct CoveThemeFileStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func applicationSupportStore(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = nil
    ) -> CoveThemeFileStore {
        CoveThemeFileStore(
            directoryURL: CoveStateFilesystem
                .applicationSupportDirectoryURL(
                    fileManager: fileManager,
                    bundleIdentifier: bundleIdentifier
                )
                .appendingPathComponent("Themes", isDirectory: true)
        )
    }

    public func loadCustomThemes() throws -> [CoveThemePalette] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }
        try Self.requireDirectory(directoryURL)
        try Self.setPermissions(0o700, at: directoryURL)

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var themes: [CoveThemePalette] = []
        var identifiers = Set<String>()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard (try? Self.requireRegularFile(url)) != nil,
                  let data = try? Self.readBounded(url),
                  let document = try? CoveThemeDocument.decodeAndValidate(data),
                  !CoveThemeCatalog.isBuiltInIdentifier(document.id),
                  identifiers.insert(document.id).inserted
            else {
                continue
            }
            themes.append(CoveThemePalette(document: document))
        }
        return themes.sorted {
            if $0.name == $1.name {
                return $0.identifier < $1.identifier
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func importTheme(from sourceURL: URL) throws -> CoveThemePalette {
        try Self.requireRegularFile(sourceURL)
        return try importTheme(data: Self.readBounded(sourceURL))
    }

    @discardableResult
    public func importTheme(data: Data) throws -> CoveThemePalette {
        let document = try CoveThemeDocument.decodeAndValidate(data)
        guard !CoveThemeCatalog.isBuiltInIdentifier(document.id) else {
            throw CoveThemeValidationError.builtInIdentifier(document.id)
        }
        try prepareDirectory()
        let destination = try destinationURL(for: document.id)
        try Self.rejectUnsafeEntryIfPresent(destination)
        let canonicalData = try document.encoded()
        guard canonicalData.count <= CoveThemeDocument.maximumImportBytes else {
            throw CoveThemeValidationError.fileTooLarge(
                actualBytes: canonicalData.count,
                maximumBytes: CoveThemeDocument.maximumImportBytes
            )
        }
        try canonicalData.write(to: destination, options: [.atomic])
        try Self.requireRegularFile(destination)
        try Self.setPermissions(0o600, at: destination)
        return CoveThemePalette(document: document)
    }

    public func exportedData(for theme: CoveThemePalette) throws -> Data {
        try theme.document.encoded()
    }

    public func exportTheme(_ theme: CoveThemePalette, to destination: URL) throws {
        try Self.rejectUnsafeEntryIfPresent(destination)
        let data = try exportedData(for: theme)
        try data.write(to: destination, options: [.atomic])
        try Self.requireRegularFile(destination)
        try Self.setPermissions(0o600, at: destination)
    }

    public func removeCustomTheme(identifier: String) throws {
        try CoveThemeDocument.validateIdentifier(identifier)
        guard !CoveThemeCatalog.isBuiltInIdentifier(identifier) else {
            throw CoveThemeValidationError.builtInIdentifier(identifier)
        }
        let destination = try destinationURL(for: identifier)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        try Self.requireRegularFile(destination)
        try FileManager.default.removeItem(at: destination)
    }

    private func prepareDirectory() throws {
        let parent = directoryURL.deletingLastPathComponent()
        try Self.createOrRequireDirectory(parent)
        try Self.createOrRequireDirectory(directoryURL)
    }

    private func destinationURL(for identifier: String) throws -> URL {
        try CoveThemeDocument.validateIdentifier(identifier)
        let destination = directoryURL.appendingPathComponent(
            "\(identifier).json",
            isDirectory: false
        )
        guard destination.deletingLastPathComponent().standardizedFileURL
            == directoryURL.standardizedFileURL
        else {
            throw CoveThemeValidationError.unsafeIdentifier
        }
        return destination
    }

    private static func createOrRequireDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try requireDirectory(url)
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try requireDirectory(url)
        }
        try setPermissions(0o700, at: url)
    }

    private static func rejectUnsafeEntryIfPresent(_ url: URL) throws {
        guard let mode = try fileMode(at: url) else { return }
        guard mode & S_IFMT == S_IFREG else {
            throw CoveThemeValidationError.unsafeFilesystemEntry("file")
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        guard let mode = try fileMode(at: url), mode & S_IFMT == S_IFDIR else {
            throw CoveThemeValidationError.unsafeFilesystemEntry("directory")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        guard let mode = try fileMode(at: url), mode & S_IFMT == S_IFREG else {
            throw CoveThemeValidationError.unsafeFilesystemEntry("file")
        }
    }

    private static func fileMode(at url: URL) throws -> mode_t? {
        var information = stat()
        let result = url.path.withCString { path in
            lstat(path, &information)
        }
        if result == 0 {
            return information.st_mode
        }
        if errno == ENOENT {
            return nil
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func setPermissions(_ permissions: Int, at url: URL) throws {
        guard chmod(url.path, mode_t(permissions)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximum = CoveThemeDocument.maximumImportBytes
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else {
            throw CoveThemeValidationError.fileTooLarge(
                actualBytes: data.count,
                maximumBytes: maximum
            )
        }
        return data
    }
}
