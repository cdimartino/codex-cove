import AVFoundation
import Darwin
import Foundation

struct CoveImportedSound: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let storedFilename: String
    let importedAt: Date
}

enum CoveImportedSoundError: LocalizedError, Equatable {
    case unsupportedFormat
    case invalidSource
    case emptyFile
    case fileTooLarge(maximumBytes: Int)
    case unsafeStorage
    case unknownSound
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "Choose a WAV, MP3, AIFF, or M4A audio file.")
        case .invalidSource:
            return String(localized: "The selected sound must be a regular file, not a symbolic link.")
        case .emptyFile:
            return String(localized: "The selected sound is empty.")
        case let .fileTooLarge(maximumBytes):
            let megabytes = maximumBytes / 1_048_576
            return String(localized: "The selected sound is larger than \(megabytes) MB.")
        case .unsafeStorage:
            return String(localized: "Codex Cove could not safely access its imported-sound folder.")
        case .unknownSound:
            return String(localized: "That imported sound is not owned by Codex Cove.")
        case .invalidAudio:
            return String(localized: "The selected file could not be decoded as audio.")
        }
    }
}

/// Owns only files registered in its private manifest. The data directory is
/// mode 0700 and imported files are mode 0600.
struct CoveImportedSoundStore: Sendable {
    static let allowedExtensions: Set<String> = ["wav", "mp3", "aiff", "aif", "m4a"]
    static let defaultMaximumBytes = 25 * 1_048_576

    let rootURL: URL
    let maximumBytes: Int

    init(rootURL: URL, maximumBytes: Int = defaultMaximumBytes) {
        self.rootURL = rootURL.standardizedFileURL
        self.maximumBytes = maximumBytes
    }

    static func applicationSupportStore(
        fileManager: FileManager = .default
    ) -> CoveImportedSoundStore {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return CoveImportedSoundStore(
            rootURL: support
                .appendingPathComponent("Codex Cove", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("Imported", isDirectory: true)
        )
    }

    func list() throws -> [CoveImportedSound] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        try validateOwnedDirectory(fileManager: fileManager)
        return try loadManifest(fileManager: fileManager).sounds.sorted {
            if $0.displayName == $1.displayName {
                return $0.id < $1.id
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    @discardableResult
    func importSound(from sourceURL: URL) throws -> CoveImportedSound {
        let source = sourceURL.standardizedFileURL
        let fileExtension = source.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(fileExtension) else {
            throw CoveImportedSoundError.unsupportedFormat
        }

        let bytes = try readRegularFileWithoutFollowingSymlink(source)
        guard !bytes.isEmpty else { throw CoveImportedSoundError.emptyFile }
        guard bytes.count <= maximumBytes else {
            throw CoveImportedSoundError.fileTooLarge(maximumBytes: maximumBytes)
        }

        let fileManager = FileManager.default
        try prepareOwnedDirectory(fileManager: fileManager)
        var manifest = try loadManifest(fileManager: fileManager)
        let identifier = UUID().uuidString.lowercased()
        let storedFilename = "\(identifier).\(fileExtension)"
        let destination = rootURL.appendingPathComponent(storedFilename, isDirectory: false)
        guard destination.deletingLastPathComponent().standardizedFileURL == rootURL else {
            throw CoveImportedSoundError.unsafeStorage
        }

        do {
            try writeOwnedFileExclusively(bytes, to: destination)
            guard chmod(destination.path, S_IRUSR | S_IWUSR) == 0 else {
                try? fileManager.removeItem(at: destination)
                throw CoveImportedSoundError.unsafeStorage
            }
            guard (try? AVAudioPlayer(contentsOf: destination)) != nil else {
                try? fileManager.removeItem(at: destination)
                throw CoveImportedSoundError.invalidAudio
            }
            let imported = CoveImportedSound(
                id: identifier,
                displayName: source.deletingPathExtension().lastPathComponent,
                storedFilename: storedFilename,
                importedAt: Date()
            )
            manifest.sounds.append(imported)
            do {
                try saveManifest(manifest, fileManager: fileManager)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            return imported
        } catch {
            if (error as? CocoaError)?.code == .fileWriteFileExists {
                throw CoveImportedSoundError.unsafeStorage
            }
            throw error
        }
    }

    /// Creates a private destination without following links or replacing an
    /// existing path. The file is not added to the manifest until this write,
    /// audio validation, and the later manifest save all succeed.
    private func writeOwnedFileExclusively(
        _ data: Data,
        to destination: URL
    ) throws {
        let descriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CoveImportedSoundError.unsafeStorage
        }

        var descriptorIsOpen = true
        var completed = false
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if !completed {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_nlink == 1,
              openedInfo.st_uid == geteuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            throw CoveImportedSoundError.unsafeStorage
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw CoveImportedSoundError.emptyFile
            }
            var writtenByteCount = 0
            while writtenByteCount < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    bytes.count - writtenByteCount
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw CoveImportedSoundError.unsafeStorage
                }
                writtenByteCount += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CoveImportedSoundError.unsafeStorage
        }

        // A failed close must not leave a manifest-visible partial import. Do
        // not retry close: the descriptor state is unspecified after failure.
        descriptorIsOpen = false
        guard close(descriptor) == 0 else {
            throw CoveImportedSoundError.unsafeStorage
        }
        completed = true
    }

    func remove(id: String) throws {
        let fileManager = FileManager.default
        try validateOwnedDirectory(fileManager: fileManager)
        var manifest = try loadManifest(fileManager: fileManager)
        guard let index = manifest.sounds.firstIndex(where: { $0.id == id }) else {
            throw CoveImportedSoundError.unknownSound
        }
        let sound = manifest.sounds[index]
        guard isValidOwnedFilename(sound.storedFilename, id: sound.id) else {
            throw CoveImportedSoundError.unsafeStorage
        }
        let fileURL = rootURL.appendingPathComponent(sound.storedFilename)
        try validateRegularOwnedFile(fileURL)
        try fileManager.removeItem(at: fileURL)
        manifest.sounds.remove(at: index)
        try saveManifest(manifest, fileManager: fileManager)
    }

    func url(for id: String) -> URL? {
        let fileManager = FileManager.default
        guard (try? validateOwnedDirectory(fileManager: fileManager)) != nil,
              let manifest = try? loadManifest(fileManager: fileManager),
              let sound = manifest.sounds.first(where: { $0.id == id }),
              isValidOwnedFilename(sound.storedFilename, id: sound.id)
        else {
            return nil
        }
        let fileURL = rootURL.appendingPathComponent(sound.storedFilename)
        guard (try? validateRegularOwnedFile(fileURL)) != nil else { return nil }
        return fileURL
    }

    private var manifestURL: URL {
        rootURL.appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func prepareOwnedDirectory(fileManager: FileManager) throws {
        let parent = rootURL.deletingLastPathComponent()
        try rejectSymbolicLinksInExistingPath(parent)
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try rejectSymbolicLinksInExistingPath(parent)

        var rootInfo = stat()
        if lstat(rootURL.path, &rootInfo) == 0 {
            guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw CoveImportedSoundError.unsafeStorage
            }
        } else if errno == ENOENT {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            throw CoveImportedSoundError.unsafeStorage
        }

        // Open the directory itself without following links, then change the
        // mode through that descriptor. A path swap cannot redirect fchmod to
        // a symlink target.
        let descriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw CoveImportedSoundError.unsafeStorage
        }
        defer { close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFDIR,
              fchmod(descriptor, S_IRWXU) == 0
        else {
            throw CoveImportedSoundError.unsafeStorage
        }
        try validateOwnedDirectory(fileManager: fileManager)
    }

    private func validateOwnedDirectory(fileManager: FileManager) throws {
        try rejectSymbolicLink(rootURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CoveImportedSoundError.unsafeStorage
        }
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
            throw CoveImportedSoundError.unsafeStorage
        }
    }

    private func rejectSymbolicLinksInExistingPath(_ url: URL) throws {
        var component = url.standardizedFileURL
        while component.path != "/" {
            var info = stat()
            if lstat(component.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw CoveImportedSoundError.unsafeStorage
                }
            } else if errno != ENOENT {
                throw CoveImportedSoundError.unsafeStorage
            }
            component.deleteLastPathComponent()
        }
    }

    private func readRegularFileWithoutFollowingSymlink(_ url: URL) throws -> Data {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url else {
            throw CoveImportedSoundError.invalidSource
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CoveImportedSoundError.invalidSource }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0
        else {
            throw CoveImportedSoundError.invalidSource
        }
        guard info.st_size > 0 else { throw CoveImportedSoundError.emptyFile }
        guard info.st_size <= maximumBytes else {
            throw CoveImportedSoundError.fileTooLarge(maximumBytes: maximumBytes)
        }
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .readToEnd() ?? Data()
    }

    private func validateRegularOwnedFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1
        else {
            throw CoveImportedSoundError.unsafeStorage
        }
    }

    private func isValidOwnedFilename(_ filename: String, id: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        return url.lastPathComponent == filename
            && url.deletingPathExtension().lastPathComponent == id
            && UUID(uuidString: id) != nil
            && Self.allowedExtensions.contains(url.pathExtension.lowercased())
    }

    private func loadManifest(fileManager: FileManager) throws -> Manifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return Manifest(schemaVersion: 1, sounds: [])
        }
        try validateRegularOwnedFile(manifestURL)
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1,
              manifest.sounds.allSatisfy({ isValidOwnedFilename($0.storedFilename, id: $0.id) })
        else {
            throw CoveImportedSoundError.unsafeStorage
        }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest, fileManager: FileManager) throws {
        let data = try JSONEncoder.coveSoundEncoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        guard chmod(manifestURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CoveImportedSoundError.unsafeStorage
        }
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        var sounds: [CoveImportedSound]
    }
}

private extension JSONEncoder {
    static var coveSoundEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
