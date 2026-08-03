import AVFoundation
import Foundation
import CoveCore

enum CoveSoundEvent: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case approvalRequested
    case needsInput
    case taskCompleted
    case taskFailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .approvalRequested:
            return String(localized: "Approval requested")
        case .needsInput:
            return String(localized: "Question needs input")
        case .taskCompleted:
            return String(localized: "Task completed")
        case .taskFailed:
            return String(localized: "Task failed")
        }
    }

    fileprivate var resourceName: String {
        switch self {
        case .approvalRequested:
            return "approval-requested"
        case .needsInput:
            return "needs-input"
        case .taskCompleted:
            return "task-completed"
        case .taskFailed:
            return "task-failed"
        }
    }

    static func classify(_ envelope: CoveWireEnvelope) -> CoveSoundEvent? {
        if let request = envelope.directRequest() {
            switch request {
            case .approval:
                return .approvalRequested
            case .question:
                return .needsInput
            case .planSnapshot:
                break
            }
        }

        let kind = envelope.kind.rawValue.lowercased()
        if kind.contains("approval") {
            return .approvalRequested
        }
        if kind.contains("question") || kind.contains("input") {
            return .needsInput
        }
        if kind.contains("failed") || kind.contains("error") {
            return .taskFailed
        }
        if kind.contains("completed") || kind.contains("complete") {
            return .taskCompleted
        }

        let payload = envelope.payload
        let method = payload.firstString(forKey: "method")?.lowercased()
        if method?.contains("requestapproval") == true {
            return .approvalRequested
        }
        if method?.contains("requestuserinput") == true {
            return .needsInput
        }
        if method == "turn/completed" {
            return payload.containsFailureMarker ? .taskFailed : .taskCompleted
        }

        if let status = envelope.sessionStatusUpdate()?.status {
            switch status {
            case .waitingApproval:
                return .approvalRequested
            case .waitingInput, .blocked:
                return .needsInput
            case .completed:
                return .taskCompleted
            case .failed, .interrupted:
                return .taskFailed
            case .idle, .listening, .active, .quiet, .hidden, .working, .compacting:
                break
            }
        }
        return nil
    }
}

enum CoveSystemSound: String, CaseIterable, Codable, Identifiable, Sendable {
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var fileURL: URL {
        URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
            .appendingPathComponent(rawValue)
            .appendingPathExtension("aiff")
    }
}

enum CoveSoundSource: Codable, Equatable, Hashable, Sendable {
    case builtIn
    case system(CoveSystemSound)
    case imported(id: String)

    var shortDescription: String {
        switch self {
        case .builtIn:
            return String(localized: "Cove 8-bit")
        case let .system(sound):
            return String(localized: "System: \(sound.displayName)")
        case .imported:
            return String(localized: "Imported sound")
        }
    }
}

struct CoveSoundConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var source: CoveSoundSource
    var volume: Double

    init(
        isEnabled: Bool = true,
        source: CoveSoundSource = .builtIn,
        volume: Double = 1
    ) {
        self.isEnabled = isEnabled
        self.source = source
        self.volume = volume.clampedVolume
    }
}

struct CoveSoundPreferences: Equatable, Sendable {
    private(set) var globalVolume: Double
    private(set) var isMuted: Bool
    private var configurations: [CoveSoundEvent: CoveSoundConfiguration]

    init(
        globalVolume: Double = 1,
        isMuted: Bool = false,
        configurations: [CoveSoundEvent: CoveSoundConfiguration] = [:]
    ) {
        self.globalVolume = globalVolume.clampedVolume
        self.isMuted = isMuted
        self.configurations = configurations
    }

    func isEnabled(_ event: CoveSoundEvent) -> Bool {
        configuration(for: event).isEnabled
    }

    func configuration(for event: CoveSoundEvent) -> CoveSoundConfiguration {
        configurations[event] ?? CoveSoundConfiguration()
    }

    func effectiveVolume(
        for event: CoveSoundEvent,
        globallyEnabled: Bool
    ) -> Double {
        let configuration = configuration(for: event)
        guard globallyEnabled, !isMuted, configuration.isEnabled else { return 0 }
        return (globalVolume * configuration.volume).clampedVolume
    }

    mutating func setEnabled(_ enabled: Bool, for event: CoveSoundEvent) {
        var configuration = configuration(for: event)
        configuration.isEnabled = enabled
        configurations[event] = configuration
    }

    mutating func setSource(_ source: CoveSoundSource, for event: CoveSoundEvent) {
        var configuration = configuration(for: event)
        configuration.source = source
        configurations[event] = configuration
    }

    mutating func setVolume(_ volume: Double, for event: CoveSoundEvent) {
        var configuration = configuration(for: event)
        configuration.volume = volume.clampedVolume
        configurations[event] = configuration
    }

    mutating func setGlobalVolume(_ volume: Double) {
        globalVolume = volume.clampedVolume
    }

    mutating func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    fileprivate var storageConfigurations: [CoveSoundEvent: CoveSoundConfiguration] {
        configurations
    }
}

struct CoveSoundPreferencesStorage {
    private let defaults: UserDefaults
    private let keyPrefix = "CodexCove.Sound."
    private let preferencesKey = "CodexCove.Sound.Preferences.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CoveSoundPreferences {
        if let data = defaults.data(forKey: preferencesKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.schemaVersion == 2 {
            let configurations: [CoveSoundEvent: CoveSoundConfiguration] = Dictionary(
                uniqueKeysWithValues: payload.events.compactMap {
                guard let event = CoveSoundEvent(rawValue: $0.key) else { return nil }
                return (event, $0.value.normalized)
                }
            )
            return CoveSoundPreferences(
                globalVolume: payload.globalVolume,
                isMuted: payload.isMuted,
                configurations: configurations
            )
        }

        var preferences = CoveSoundPreferences()
        for event in CoveSoundEvent.allCases {
            let key = keyPrefix + event.rawValue
            if defaults.object(forKey: key) != nil {
                preferences.setEnabled(defaults.bool(forKey: key), for: event)
            }
        }
        return preferences
    }

    func save(_ enabled: Bool, for event: CoveSoundEvent) {
        var preferences = load()
        preferences.setEnabled(enabled, for: event)
        save(preferences)
        // Keep the original key updated so downgrades preserve the toggle.
        defaults.set(enabled, forKey: keyPrefix + event.rawValue)
    }

    func save(_ preferences: CoveSoundPreferences) {
        let events = Dictionary(uniqueKeysWithValues: preferences.storageConfigurations.map {
            ($0.key.rawValue, $0.value.normalized)
        })
        let payload = Payload(
            schemaVersion: 2,
            globalVolume: preferences.globalVolume,
            isMuted: preferences.isMuted,
            events: events
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: preferencesKey)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let globalVolume: Double
        let isMuted: Bool
        let events: [String: CoveSoundConfiguration]
    }
}

@MainActor
final class CoveSoundService {
    private var player: AVAudioPlayer?
    private var releaseTask: Task<Void, Never>?
    private let bundle: Bundle
    private let fileManager: FileManager
    private let importedSoundStore: CoveImportedSoundStore
    private let allowsPlayback: Bool

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        importedSoundStore: CoveImportedSoundStore = .applicationSupportStore(),
        allowsPlayback: Bool = Bundle.main.bundleIdentifier
            != CoveUITestConfiguration.hostBundleIdentifier
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.importedSoundStore = importedSoundStore
        self.allowsPlayback = allowsPlayback
    }

    func play(
        for envelope: CoveWireEnvelope,
        globallyEnabled: Bool,
        preferences: CoveSoundPreferences
    ) {
        guard allowsPlayback,
              globallyEnabled,
              let event = CoveSoundEvent.classify(envelope),
              preferences.isEnabled(event),
              !preferences.isMuted
        else {
            return
        }

        let configuration = preferences.configuration(for: event)
        guard let resourceURL = resourceURL(
            for: event,
            source: configuration.source
        ) else { return }

        do {
            try play(
                resourceURL,
                volume: configuration.volume * preferences.globalVolume
            )
        } catch {
            releaseAudioResources()
            NSLog("CoveSoundService could not play the configured sound")
        }
    }

    func preview(
        event: CoveSoundEvent,
        preferences: CoveSoundPreferences
    ) throws {
        guard allowsPlayback else { return }
        let configuration = preferences.configuration(for: event)
        guard let resourceURL = resourceURL(for: event, source: configuration.source) else {
            throw CoveImportedSoundError.invalidAudio
        }
        try play(
            resourceURL,
            volume: configuration.volume * preferences.globalVolume
        )
    }

    func stop() {
        releaseAudioResources()
    }

    private func resourceURL(
        for event: CoveSoundEvent,
        source: CoveSoundSource
    ) -> URL? {
        switch source {
        case .builtIn:
            return builtInResourceURL(for: event)
        case let .system(sound):
            return fileManager.fileExists(atPath: sound.fileURL.path)
                ? sound.fileURL
                : nil
        case let .imported(id):
            return importedSoundStore.url(for: id)
        }
    }

    private func builtInResourceURL(for event: CoveSoundEvent) -> URL? {
        if let bundled = bundle.url(
            forResource: event.resourceName,
            withExtension: "wav",
            subdirectory: "Sounds"
        ) {
            return bundled
        }

        // `swift run` has no application bundle. This development-only lookup
        // keeps local builds audible without broadening the packaged search.
        let developmentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
            .appendingPathComponent(event.resourceName)
            .appendingPathExtension("wav")
        return fileManager.fileExists(atPath: developmentURL.path) ? developmentURL : nil
    }

    private func play(_ resourceURL: URL, volume: Double) throws {
        releaseAudioResources()
        let player = try AVAudioPlayer(contentsOf: resourceURL)
        player.volume = Float(volume.clampedVolume)
        player.prepareToPlay()
        guard player.play() else {
            throw CoveImportedSoundError.invalidAudio
        }
        self.player = player
        let releaseDelay = max(0.1, player.duration + 0.1)
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(releaseDelay))
            guard !Task.isCancelled else { return }
            self?.releaseAudioResources()
        }
    }

    private func releaseAudioResources() {
        releaseTask?.cancel()
        releaseTask = nil
        player?.stop()
        player = nil
    }
}

private extension Double {
    var clampedVolume: Double {
        min(max(isFinite ? self : 1, 0), 1)
    }
}

private extension CoveSoundConfiguration {
    var normalized: CoveSoundConfiguration {
        CoveSoundConfiguration(isEnabled: isEnabled, source: source, volume: volume)
    }
}

private extension CoveJSONValue {
    func firstString(forKey targetKey: String) -> String? {
        switch self {
        case let .object(object):
            if let value = object[targetKey]?.stringValue {
                return value
            }
            for value in object.values {
                if let match = value.firstString(forKey: targetKey) {
                    return match
                }
            }
        case let .array(values):
            for value in values {
                if let match = value.firstString(forKey: targetKey) {
                    return match
                }
            }
        case .string, .number, .bool, .null:
            break
        }
        return nil
    }

    var containsFailureMarker: Bool {
        switch self {
        case let .object(object):
            for (key, value) in object {
                let normalizedKey = key.lowercased()
                if ["error", "failure", "failed"].contains(normalizedKey), value != .null {
                    return true
                }
                if ["status", "state", "outcome"].contains(normalizedKey),
                   let marker = value.stringValue?.lowercased(),
                   ["failed", "failure", "error", "interrupted", "cancelled", "canceled"].contains(marker)
                {
                    return true
                }
                if value.containsFailureMarker {
                    return true
                }
            }
        case let .array(values):
            return values.contains(where: \.containsFailureMarker)
        case .string, .number, .bool, .null:
            break
        }
        return false
    }
}
