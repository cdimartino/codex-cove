import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A store-agnostic settings section. Callers own the preferences value and
/// persist each updated copy delivered by `onPreferencesChanged`.
struct CoveSoundSettingsSection: View {
    let globallyEnabled: Bool
    let preferences: CoveSoundPreferences
    let onGloballyEnabledChanged: (Bool) -> Void
    let onPreferencesChanged: (CoveSoundPreferences) -> Void
    let sideEffectsEnabled: Bool

    @State private var importedSounds: [CoveImportedSound] = []
    @State private var alertMessage: String?
    @State private var previewService: CoveSoundService
    @State private var expandedEvents: Set<CoveSoundEvent> = []
    private let importedSoundStore: CoveImportedSoundStore

    init(
        globallyEnabled: Bool,
        preferences: CoveSoundPreferences,
        importedSoundStore: CoveImportedSoundStore = .applicationSupportStore(),
        sideEffectsEnabled: Bool = true,
        onGloballyEnabledChanged: @escaping (Bool) -> Void,
        onPreferencesChanged: @escaping (CoveSoundPreferences) -> Void
    ) {
        self.globallyEnabled = globallyEnabled
        self.preferences = preferences
        self.importedSoundStore = importedSoundStore
        self.sideEffectsEnabled = sideEffectsEnabled
        self.onGloballyEnabledChanged = onGloballyEnabledChanged
        self.onPreferencesChanged = onPreferencesChanged
        _previewService = State(
            initialValue: CoveSoundService(importedSoundStore: importedSoundStore)
        )
    }

    var body: some View {
        Section("Sounds") {
            Toggle("Play event sounds", isOn: globallyEnabledBinding)
                .help("Enable Cove's event-sound system. Per-event choices remain configurable below.")
                .accessibilityIdentifier("settings.sounds.global.enabled")
            Toggle("Mute all sounds", isOn: mutedBinding)
                .disabled(!globallyEnabled)
                .help("Temporarily silence every Cove event without changing individual sound choices.")
                .accessibilityIdentifier("settings.sounds.global.muted")

            CovePrecisionControlRow(
                "Global volume",
                value: globalVolumeBinding,
                in: 0 ... 1,
                step: 0.01,
                unit: "%",
                displayScale: 100,
                fractionDigits: 0,
                accessibilityIdentifier: "settings.sounds.global.volume"
            )
            .disabled(!globallyEnabled || preferences.isMuted)
            .help("Scale every enabled event sound before its per-event volume.")

            ForEach(CoveSoundEvent.allCases) { event in
                eventEditor(for: event)
            }

            HStack {
                Button("Import Sound…") {
                    importSound()
                }
                .disabled(!sideEffectsEnabled)
                .help("Copy a supported audio file into Cove's private local sound library.")
                .accessibilityIdentifier("settings.sounds.import")
                Spacer()
                if !importedSounds.isEmpty {
                    Menu("Remove Imported Sound") {
                        ForEach(Array(importedSounds.enumerated()), id: \.element.id) {
                            index, sound in
                            Button(sound.displayName, role: .destructive) {
                                remove(sound)
                            }
                            .accessibilityIdentifier(
                                "settings.sounds.imported.\(index).remove"
                            )
                        }
                    }
                    .help("Delete a copied sound from Cove's local library.")
                    .accessibilityIdentifier("settings.sounds.remove-imported")
                }
            }

            Text("Imported sounds are copied to Codex Cove’s private local storage. Supported formats: WAV, MP3, AIFF, and M4A; maximum 25 MB.")
                .coveSystemFont(size: 11)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reloadImportedSounds)
        .onDisappear {
            previewService.stop()
        }
        .alert(
            "Sound",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK") { alertMessage = nil }
                .accessibilityIdentifier("settings.sounds.alert.dismiss")
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func eventEditor(for event: CoveSoundEvent) -> some View {
        let configuration = preferences.configuration(for: event)
        DisclosureGroup(
            isExpanded: disclosureBinding(for: event)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Play sound for \(event.displayName.lowercased())",
                    isOn: enabledBinding(for: event)
                )
                .help("Enable or disable this event without changing its selected sound.")
                .accessibilityIdentifier(
                    "settings.sounds.event.\(event.rawValue).enabled"
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Sound", selection: sourceBinding(for: event)) {
                            Text("Cove 8-bit")
                                .tag(CoveSoundSource.builtIn)
                            Section("Apple System Sounds") {
                                ForEach(CoveSystemSound.allCases) { sound in
                                    Text(sound.displayName)
                                        .tag(CoveSoundSource.system(sound))
                                }
                            }
                            if !importedSounds.isEmpty {
                                Section("Imported Sounds") {
                                    ForEach(importedSounds) { sound in
                                        Text(sound.displayName)
                                            .tag(CoveSoundSource.imported(id: sound.id))
                                    }
                                }
                            }
                            if case let .imported(id) = configuration.source,
                               !importedSounds.contains(where: { $0.id == id }) {
                                Text("Missing imported sound")
                                    .tag(configuration.source)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("Choose Cove's built-in sound, an Apple system sound, or an imported file.")
                        .accessibilityLabel("\(event.displayName), sound source")
                        .accessibilityIdentifier(
                            "settings.sounds.event.\(event.rawValue).source"
                        )

                        Button("Preview") {
                            preview(event)
                        }
                        .disabled(!sideEffectsEnabled || preferences.isMuted)
                        .help("Play this event's current sound and effective volume.")
                        .accessibilityLabel("Preview \(event.displayName) sound")
                        .accessibilityIdentifier(
                            "settings.sounds.event.\(event.rawValue).preview"
                        )
                    }

                    CovePrecisionControlRow(
                        "Event volume",
                        value: volumeBinding(for: event),
                        in: 0 ... 1,
                        step: 0.01,
                        unit: "%",
                        displayScale: 100,
                        fractionDigits: 0,
                        accessibilityIdentifier:
                            "settings.sounds.event.\(event.rawValue).volume"
                    )
                    .help("Scale this event after the global volume.")
                }
                .disabled(!globallyEnabled || !configuration.isEnabled)
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayName)
                    .coveSystemFont(size: 13, weight: .medium)
                Text(summary(for: event))
                    .coveSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "settings.sounds.event.\(event.rawValue).disclosure"
            )
        }
    }

    private func disclosureBinding(for event: CoveSoundEvent) -> Binding<Bool> {
        Binding(
            get: { expandedEvents.contains(event) },
            set: { expanded in
                if expanded {
                    expandedEvents.insert(event)
                } else {
                    expandedEvents.remove(event)
                }
            }
        )
    }

    private func summary(for event: CoveSoundEvent) -> String {
        let configuration = preferences.configuration(for: event)
        let enabled = configuration.isEnabled
            ? String(localized: "On")
            : String(localized: "Off")
        let source = sourceDescription(configuration.source)
        let effectiveVolume = Int(
            (preferences.effectiveVolume(
                for: event,
                globallyEnabled: globallyEnabled
            ) * 100).rounded()
        )
        return String(
            localized: "\(enabled) · \(source) · \(effectiveVolume)% effective"
        )
    }

    private func sourceDescription(_ source: CoveSoundSource) -> String {
        switch source {
        case .builtIn, .system:
            source.shortDescription
        case let .imported(id):
            if let sound = importedSounds.first(where: { $0.id == id }) {
                String(localized: "Imported: \(sound.displayName)")
            } else {
                String(localized: "Missing imported sound")
            }
        }
    }

    private var globallyEnabledBinding: Binding<Bool> {
        Binding(
            get: { globallyEnabled },
            set: { value in onGloballyEnabledChanged(value) }
        )
    }

    private var mutedBinding: Binding<Bool> {
        Binding(
            get: { preferences.isMuted },
            set: { value in
                updatePreferences { $0.setMuted(value) }
                if value { previewService.stop() }
            }
        )
    }

    private var globalVolumeBinding: Binding<Double> {
        Binding(
            get: { preferences.globalVolume },
            set: { value in updatePreferences { $0.setGlobalVolume(value) } }
        )
    }

    private func enabledBinding(for event: CoveSoundEvent) -> Binding<Bool> {
        Binding(
            get: { preferences.isEnabled(event) },
            set: { value in updatePreferences { $0.setEnabled(value, for: event) } }
        )
    }

    private func sourceBinding(for event: CoveSoundEvent) -> Binding<CoveSoundSource> {
        Binding(
            get: { preferences.configuration(for: event).source },
            set: { source in updatePreferences { $0.setSource(source, for: event) } }
        )
    }

    private func volumeBinding(for event: CoveSoundEvent) -> Binding<Double> {
        Binding(
            get: { preferences.configuration(for: event).volume },
            set: { value in updatePreferences { $0.setVolume(value, for: event) } }
        )
    }

    private func updatePreferences(_ update: (inout CoveSoundPreferences) -> Void) {
        var copy = preferences
        update(&copy)
        onPreferencesChanged(copy)
    }

    private func preview(_ event: CoveSoundEvent) {
        guard sideEffectsEnabled else { return }
        do {
            try previewService.preview(event: event, preferences: preferences)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importSound() {
        guard sideEffectsEnabled else { return }
        guard let sourceURL = CoveSoundFilePanels.chooseSoundToImport() else {
            return
        }
        do {
            let sound = try importedSoundStore.importSound(from: sourceURL)
            reloadImportedSounds()
            alertMessage = String(localized: "Imported “\(sound.displayName)”.")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func remove(_ sound: CoveImportedSound) {
        guard sideEffectsEnabled else { return }
        do {
            previewService.stop()
            try importedSoundStore.remove(id: sound.id)
            var updated = preferences
            for event in CoveSoundEvent.allCases
            where updated.configuration(for: event).source == .imported(id: sound.id) {
                updated.setSource(.builtIn, for: event)
            }
            onPreferencesChanged(updated)
            reloadImportedSounds()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func reloadImportedSounds() {
        do {
            importedSounds = try importedSoundStore.list()
        } catch {
            importedSounds = []
            alertMessage = error.localizedDescription
        }
    }
}

enum CoveSoundFilePanels {
    @MainActor
    static func chooseSoundToImport() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Sound")
        panel.prompt = String(localized: "Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = ["wav", "mp3", "aiff", "m4a"].compactMap {
            UTType(filenameExtension: $0)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
