import Darwin
import Foundation
import CoveCore
import SQLite3

@main
struct CoveCoreSmokeTests {
    static func main() async throws {
        try run("theme lookup", testThemeLookup)
        try run("generated theme definitions", testGeneratedThemeDefinitions)
        try run("theme import/export and permissions", testThemeImportExportAndPermissions)
        try run("theme validation and migration", testThemeValidationAndLegacyMigration)
        try run("theme opacity and round trip", testThemeOpacityBoundsAndRoundTrip)
        try run("quiet-hour boundaries and project rules", testQuietPolicies)
        try run("quiet settings persistence", testQuietSettingsRoundTrip)
        try run("privacy scene activation recovery", testPrivacySceneActivationRecovery)
        try run("pin ordering and glance attention", testPinOrderingAndGlanceAttention)
        try run("follow-up reminder boundary", testFollowUpReminderBoundary)
        try run("notification preferences and launch boundary", testNotificationPreferencesAndLaunchBoundary)
        try run(
            "startup notification buffering and resolution",
            testStartupNotificationBufferingAndResolution
        )
        try run(
            "approval-review subagents are invisible",
            testApprovalReviewSubagentsAreInvisible
        )
        try run("pixel resident catalog and stable mapping", testPixelResidentCatalog)
        try run("collapsed resident flow geometry", testCollapsedResidentFlow)
        try run("minimal island geometry and migration", testMinimalIslandGeometryAndMigration)
        try run("desktop thread hydration parsing", testDesktopThreadHydrationParsing)
        try run("desktop thread source validation", testDesktopThreadSourceValidation)
        try run("desktop startup source filtering", testDesktopStartupSourceFiltering)
        try await run(
            "desktop thread hydration skips hanging proxy",
            testDesktopThreadHydrationSkipsHangingProxy
        )
        try await run(
            "desktop thread hydration correlates out-of-order reads",
            testDesktopThreadHydrationCorrelatesOutOfOrderReads
        )
        try run("recoverable session archive", testRecoverableSessionArchive)
        try run("official per-session token metrics", testOfficialPerSessionTokenMetrics)
        try run("rate-limit response parsing", testRateLimitsResponseParsing)
        try run("partial rate-limit inventory", testRateLimitsMissingInventoryIsPartial)
        try run("profile token usage parsing", testAccountTokenUsageParsing)
        try run("profile token usage trends", testAccountTokenUsageTrends)
        run(
            "failed profile refresh preserves last good profile",
            testFailedProfileRefreshPreservesLastGoodProfile
        )
        try await run("account usage process fixture", testAccountUsageProcessFixture)
        try await run("oversized account usage line", testAccountUsageRejectsOversizedLine)
        try run("snapshot priority", testReducerSnapshotPriority)
        run("latest assistant output projection", testLatestAssistantOutputProjection)
        try run(
            "snapshot origin collision remains isolated",
            testSnapshotOriginCollisionFailsClosed
        )
        try run(
            "read, dismiss, and out-of-order reducer semantics",
            testReducerReadDismissAndOutOfOrderSemantics
        )
        try run(
            "stale status envelope isolation",
            testStaleStatusEnvelopeDoesNotRegressGlobalState
        )
        try run("question mapping", testReducerQuestionMapping)
        try run("multi-question mapping and encoding", testMultiQuestionMappingAndEncoding)
        try run("request ID type awareness", testRequestIDTypeAwareness)
        try run(
            "concurrent direct request isolation",
            testConcurrentDirectRequestIsolation
        )
        try run(
            "direct request origin isolation",
            testDirectRequestOriginIsolation
        )
        try run("malformed advertised choices", testMalformedAdvertisedChoicesAreDropped)
        try run("transient-state persistence sanitization", testPersistenceSanitizesTransientState)
        try run("legacy settings migration", testLegacySettingsMigration)
        try run("SQLite metadata persistence", testSQLiteMetadataPersistence)
        try run("composite metadata identity and migration", testCompositeMetadataIdentityAndMigration)
        try run("workspace persistence bounds and permissions", testWorkspacePersistence)
        try run("workspace hierarchy search filter and membership", testWorkspaceProjection)
        try run("loaded-thread page and control validation", testLoadedThreadAndControlContracts)
        try run(
            "pending session attribution preserves launch metadata",
            testPendingSessionAttributionPreservesLaunchMetadata
        )
        try run("decision encoding", testDecisionEncoding)
        try run("remote decision acknowledgement protocol", testRemoteDecisionProtocol)
        try run("persistent remote SSH safety", testPersistentRemoteSSHSafety)
        try run("fixture decoding", testFixtureDecoding)
        try await run("Desktop owned turn decision bridge", testDesktopOwnedTurnDecisionBridge)
        try await run("thread control socket delivery", testThreadControlSocketDelivery)
        try await run("decision socket delivery", testDecisionSocketDelivery)
        try await run("decision socket bounds and privacy", testDecisionSocketBoundsAndPrivacy)
        print("CoveCore smoke tests passed")
    }

    private static func run(
        _ name: String,
        _ body: () throws -> Void
    ) rethrows {
        print("Running \(name)…")
        try body()
    }

    private static func run(
        _ name: String,
        _ body: () async throws -> Void
    ) async rethrows {
        print("Running \(name)…")
        try await body()
    }

    static func testThemeLookup() throws {
        let palette = CoveThemeCatalog.palette(for: .retroTerminal, palette: .terminalGreen)
        precondition(palette.palette == .terminalGreen)
        precondition(palette.family == .retroTerminal)
        precondition(CoveThemeCatalog.palettes.count == 15)
        precondition(Set(CoveThemeCatalog.palettes.map(\.identifier)).count == 15)
        try palette.document.validate()
    }

    static func testGeneratedThemeDefinitions() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let themeDirectory = repositoryRoot
            .appendingPathComponent("Resources/Themes", isDirectory: true)
        let themeURLs = try FileManager.default.contentsOfDirectory(
            at: themeDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        precondition(themeURLs.count == 15)

        let documents = try themeURLs.map {
            try CoveThemeDocument.decodeAndValidate(Data(contentsOf: $0))
        }
        precondition(Set(documents.map(\.id)).count == 15)
        precondition(
            Set(documents.map(\.id))
                == Set(CoveThemeCatalog.palettes.map(\.identifier))
        )
        for document in documents {
            let generated = CoveThemePalette(document: document)
            guard let catalog = CoveThemeCatalog.theme(identifier: document.id) else {
                fatalError("Generated theme is missing from the Swift catalog")
            }
            precondition(generated.document == catalog.document)
        }
    }

    static func testPrivacySceneActivationRecovery() throws {
        precondition(
            CovePrivacyScene.locked.resolvingCapturePrivacy(
                isCapturePrivacyActive: false
            ) == .locked,
            "ordinary state refreshes must not clear lock-screen privacy"
        )
        precondition(
            CovePrivacyScene.locked.resolvingCapturePrivacy(
                isCapturePrivacyActive: false,
                allowLockedExit: true
            ) == .normal,
            "an active session must be able to leave the locked privacy scene"
        )
        precondition(
            CovePrivacyScene.locked.resolvingCapturePrivacy(
                isCapturePrivacyActive: true,
                allowLockedExit: true
            ) == .redacted,
            "session activation must preserve active capture redaction"
        )
        precondition(
            CovePrivacyScene.redacted.resolvingCapturePrivacy(
                isCapturePrivacyActive: false
            ) == .normal,
            "capture privacy must clear when capture redaction is no longer active"
        )
    }

    static func testThemeImportExportAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let themesDirectory = directory.appendingPathComponent("Themes", isDirectory: true)
        let store = CoveThemeFileStore(directoryURL: themesDirectory)

        var document = CoveThemeCatalog
            .palette(for: .nativeGlass, palette: .ocean)
            .document
        document.id = "chris.ocean-night"
        document.name = "Ocean Night"
        document.palette.colors.accent = "#31E6FF"
        let imported = try store.importTheme(data: document.encoded())
        precondition(imported.identifier == "chris.ocean-night")
        precondition(imported.accentHex == "#31E6FF")

        let loaded = try store.loadCustomThemes()
        precondition(loaded == [imported])
        let storedURL = themesDirectory.appendingPathComponent(
            "chris.ocean-night.json"
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: themesDirectory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: storedURL.path
        )
        precondition(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700
        )
        precondition(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )

        let exportedURL = directory.appendingPathComponent("export.json")
        try store.exportTheme(imported, to: exportedURL)
        let exported = try CoveThemeDocument.decodeAndValidate(
            Data(contentsOf: exportedURL)
        )
        precondition(exported == document)
        let exportAttributes = try FileManager.default.attributesOfItem(
            atPath: exportedURL.path
        )
        precondition(
            (exportAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )
    }

    static func testThemeValidationAndLegacyMigration() throws {
        let oversized = Data(
            repeating: 0x20,
            count: CoveThemeDocument.maximumImportBytes + 1
        )
        do {
            _ = try CoveThemeDocument.decodeAndValidate(oversized)
            fatalError("Oversized themes must be rejected")
        } catch let error as CoveThemeValidationError {
            guard case .fileTooLarge = error else {
                fatalError("Unexpected oversized theme error: \(error)")
            }
        } catch {
            throw error
        }

        var traversal = CoveThemeCatalog.palettes[0].document
        traversal.id = "../outside"
        let traversalData = try JSONEncoder().encode(traversal)
        do {
            _ = try CoveThemeDocument.decodeAndValidate(traversalData)
            fatalError("Traversal identifiers must be rejected")
        } catch let error as CoveThemeValidationError {
            precondition(error == .unsafeIdentifier)
        } catch {
            throw error
        }

        var invalidOpacity = CoveThemeCatalog.palettes[0].document
        invalidOpacity.id = "custom.invalid-opacity"
        invalidOpacity.collapsedOpacity = 0.34
        let invalidOpacityData = try JSONEncoder().encode(invalidOpacity)
        do {
            _ = try CoveThemeDocument.decodeAndValidate(invalidOpacityData)
            fatalError("Out-of-range opacity must be rejected")
        } catch let error as CoveThemeValidationError {
            precondition(error == .invalidField("collapsedOpacity"))
        } catch {
            throw error
        }

        var object = try JSONSerialization.jsonObject(
            with: CoveThemeCatalog.palettes[0].document.encoded()
        ) as! [String: Any]
        object["unexpected"] = true
        do {
            _ = try CoveThemeDocument.decodeAndValidate(
                JSONSerialization.data(withJSONObject: object)
            )
            fatalError("Unknown root fields must be rejected")
        } catch let error as CoveThemeValidationError {
            precondition(error == .invalidField("root"))
        } catch {
            throw error
        }

        let legacy = Data(
            """
            {
              "schemaVersion": 1,
              "family": "retroTerminal",
              "palette": {
                "name": "Terminal Green",
                "colors": {
                  "background": "#020704",
                  "surface": "#07150C",
                  "text": "#B9FFD0",
                  "muted": "#62A878",
                  "accent": "#54FF8A",
                  "working": "#82FFB0",
                  "waiting": "#E8FF6A",
                  "completed": "#35F27A",
                  "failed": "#FF667D"
                }
              },
              "typography": {
                "family": "SF Mono",
                "sizeScale": 0.96,
                "weight": "medium",
                "lineHeight": 1.1
              },
              "cornerRadius": 10,
              "border": { "width": 1, "style": "solid" },
              "shadow": { "x": 0, "y": 6, "blur": 16, "opacity": 0.4 },
              "noise": 0.08,
              "blur": "thin",
              "collapsedOpacity": 0.86,
              "expandedOpacity": 0.94,
              "animation": {
                "enabled": true,
                "durationMs": 120,
                "easing": "linear"
              }
            }
            """.utf8
        )
        let migrated = try CoveThemeDocument.decodeAndValidate(legacy)
        precondition(migrated.surfaceFill == .gradient)
        precondition(migrated.id == "retroTerminal.terminalGreen")
        precondition(migrated.name == "Retro Terminal · Terminal Green")
        precondition(migrated.palette.colors.waitingInput == "#E8FF6A")
        precondition(migrated.palette.colors.interrupted == "#FF667D")
        let canonical = String(decoding: try migrated.encoded(), as: UTF8.self)
        precondition(canonical.contains("\"waitingApproval\""))
        precondition(canonical.contains("\"primaryText\""))

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let directory = testRoot.appendingPathComponent("Themes", isDirectory: true)
        let store = CoveThemeFileStore(directoryURL: directory)
        var collision = CoveThemeCatalog.palettes[0].document
        collision.id = CoveThemeCatalog.palettes[1].identifier
        do {
            _ = try store.importTheme(data: collision.encoded())
            fatalError("Built-in identifiers must not be overwritten")
        } catch let error as CoveThemeValidationError {
            precondition(error == .builtInIdentifier(collision.id))
        } catch {
            throw error
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let outside = testRoot
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        let unsafeDestination = directory.appendingPathComponent(
            "custom.symlink.json"
        )
        let symlinkResult = outside.path.withCString { source in
            unsafeDestination.path.withCString { destination in
                Darwin.symlink(source, destination)
            }
        }
        let symlinkErrno = errno
        if symlinkResult != 0, symlinkErrno == EPERM {
            print(
                "Skipping symbolic-link destination branch: "
                    + "the signed test process is denied symlink creation"
            )
            return
        }
        guard symlinkResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: symlinkErrno) ?? .EIO)
        }
        var symlinkTheme = CoveThemeCatalog.palettes[0].document
        symlinkTheme.id = "custom.symlink"
        symlinkTheme.name = "Symlink Test"
        do {
            _ = try store.importTheme(data: symlinkTheme.encoded())
            fatalError("A symbolic-link destination must be rejected")
        } catch let error as CoveThemeValidationError {
            precondition(error == .unsafeFilesystemEntry("file"))
        } catch {
            throw error
        }
        let outsideText = String(decoding: try Data(contentsOf: outside), as: UTF8.self)
        precondition(outsideText == "outside")
    }

    static func testThemeOpacityBoundsAndRoundTrip() throws {
        let settings = CoveSettings(
            collapsedOpacity: -1,
            expandedOpacity: 4,
            customThemeID: "chris.roundtrip"
        )
        precondition(settings.collapsedOpacity == 0.35)
        precondition(settings.expandedOpacity == 1)
        let encodedSettings = try JSONEncoder().encode(settings)
        let roundTripped = try JSONDecoder().decode(
            CoveSettings.self,
            from: encodedSettings
        )
        precondition(roundTripped == settings)

        var theme = CoveThemeCatalog
            .palette(for: .minimalOled, palette: .sunset)
            .document
        theme.id = "chris.roundtrip"
        theme.name = "Round Trip"
        theme.surfaceFill = .solid
        let encodedTheme = try theme.encoded()
        let decoded = try CoveThemeDocument.decodeAndValidate(encodedTheme)
        precondition(decoded == theme)
        precondition(decoded.surfaceFill == .solid)
    }

    static func testQuietPolicies() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(hour: Int, minute: Int) -> Date {
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 31,
                    hour: hour,
                    minute: minute
                )
            )!
        }

        let overnight = CoveQuietHours(
            enabled: true,
            startMinute: 22 * 60,
            endMinute: 7 * 60
        )
        precondition(!overnight.contains(date(hour: 21, minute: 59), calendar: calendar))
        precondition(overnight.contains(date(hour: 22, minute: 0), calendar: calendar))
        precondition(overnight.contains(date(hour: 6, minute: 59), calendar: calendar))
        precondition(!overnight.contains(date(hour: 7, minute: 0), calendar: calendar))

        let daytime = CoveQuietHours(
            enabled: true,
            startMinute: 9 * 60,
            endMinute: 17 * 60
        )
        precondition(daytime.contains(date(hour: 9, minute: 0), calendar: calendar))
        precondition(!daytime.contains(date(hour: 17, minute: 0), calendar: calendar))

        let settings = CoveSettings(
            quietHours: overnight,
            silencedProjectRules: [" Dashboard ", "cove"],
            followFocusedApp: true
        )
        precondition(
            CoveQuietPolicy.reason(
                settings: settings,
                at: date(hour: 23, minute: 0),
                focusedBundleIdentifier: nil,
                calendar: calendar
            ) == .quietHours
        )
        precondition(
            CoveQuietPolicy.reason(
                settings: settings,
                at: date(hour: 12, minute: 0),
                focusedBundleIdentifier: "com.apple.dt.Xcode",
                calendar: calendar
            ) == .focusedApp
        )
        precondition(
            CoveQuietPolicy.matchesSilencedProject(
                settings: settings,
                candidates: ["Working in dashboard-server"]
            )
        )
        precondition(
            !CoveQuietPolicy.matchesSilencedProject(
                settings: settings,
                candidates: ["unrelated task"]
            )
        )
    }

    static func testQuietSettingsRoundTrip() throws {
        let settings = CoveSettings(
            textScale: 1.65,
            residentSet: .virusAndBacteria,
            quietHours: .init(
                enabled: true,
                startMinute: 23 * 60 + 15,
                endMinute: 6 * 60 + 45
            ),
            silencedProjectRules: ["dashboard", "Codex Cove"],
            followFocusedApp: true,
            glanceMode: true,
            hoverDelaySeconds: 0.8,
            autoCollapseSeconds: 12,
            collapsedWidth: 214,
            squareTopCorners: false,
            idleAutoHideSeconds: 90,
            followUpReminderSeconds: 30 * 60,
            minimalIslandMode: true,
            showUsage: false,
            showProfileTokenUsage: true,
            showTokenMetrics: true
        )
        let decoded = try JSONDecoder().decode(
            CoveSettings.self,
            from: JSONEncoder().encode(settings)
        )
        precondition(decoded == settings)
        precondition(decoded.residentSet == .virusAndBacteria)
        precondition(decoded.textScale == 1.65)
        precondition(decoded.quietHours.startMinute == 23 * 60 + 15)
        precondition(decoded.silencedProjectRules == ["dashboard", "Codex Cove"])
        precondition(decoded.collapsedWidth == 214)
        precondition(!decoded.squareTopCorners)
        precondition(decoded.minimalIslandMode)
        precondition(!decoded.showUsage)
        precondition(decoded.showProfileTokenUsage)
        precondition(decoded.showTokenMetrics)
    }

    static func testPinOrderingAndGlanceAttention() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = CoveState(
            settings: .init(
                autoExpandOnEvent: true,
                glanceMode: true
            )
        )
        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                .init(
                    snapshotId: "high",
                    status: .failed,
                    priority: 90,
                    title: "High",
                    timestamp: now,
                    sessionId: "high",
                    source: .localCli
                )
            )
        )
        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                .init(
                    snapshotId: "pinned",
                    status: .idle,
                    priority: 5,
                    title: "Pinned",
                    timestamp: now.addingTimeInterval(-1),
                    sessionId: "pinned",
                    source: .localCli
                )
            )
        )
        precondition(!state.session.isExpanded)
        CoveReducer.reduce(&state, .togglePinned(
            state.session.snapshots.first { $0.sessionId == "pinned" }!
                .sessionIdentity!
        ))
        precondition(state.session.snapshots.first?.sessionId == "pinned")
        precondition(state.session.activeSnapshot?.sessionId == "high")
        precondition(state.session.activeStatus == .failed)

        let request = CoveDirectRequest.question(
            .init(
                schemaVersion: 1,
                requestId: 7,
                launchId: "launch-attention",
                sessionId: "session-attention",
                question: "Continue?",
                options: [],
                allowsFreeform: true,
                decisionSocket: nil
            )
        )
        CoveReducer.reduce(&state, .setPendingDirectRequest(request))
        // Glance mode never suppresses approval/input visibility.
        CoveReducer.reduce(&state, .setGlanceMode(true))
        precondition(state.pendingDirectRequest == request)
        CoveReducer.reduce(&state, .setExpanded(true))
        precondition(state.session.isExpanded)
    }

    static func testFollowUpReminderBoundary() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(
            !CoveFollowUpReminderPolicy.isDue(
                reminderAt: now.addingTimeInterval(0.001),
                now: now
            )
        )
        precondition(
            CoveFollowUpReminderPolicy.isDue(reminderAt: now, now: now)
        )
        precondition(
            CoveFollowUpReminderPolicy.isDue(
                reminderAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        precondition(
            !CoveFollowUpReminderPolicy.isDue(reminderAt: nil, now: now)
        )
    }

    static func testNotificationPreferencesAndLaunchBoundary() throws {
        var state = CoveState()
        var approval = state.settings.notificationPreferences.rule(for: .approval)
        approval.enabled = false
        approval.includesDetail = true
        approval.includesProject = false
        CoveReducer.reduce(&state, .setNotificationRule(.approval, approval))
        precondition(
            state.settings.notificationPreferences.rule(for: .approval)
                == approval
        )

        CoveReducer.reduce(&state, .setPanelAnimationEnabled(false))
        CoveReducer.reduce(&state, .setPanelAnimationDuration(0.01))
        precondition(!state.settings.panelAnimationEnabled)
        precondition(state.settings.panelAnimationDuration == 0.08)
        CoveReducer.reduce(&state, .setPanelAnimationDuration(4))
        precondition(state.settings.panelAnimationDuration == 0.8)

        let encoded = try JSONEncoder().encode(state.settings)
        let decoded = try JSONDecoder().decode(CoveSettings.self, from: encoded)
        precondition(decoded.notificationPreferences.approval == approval)
        precondition(!decoded.panelAnimationEnabled)

        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        func envelope(at timestamp: Date) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: UUID().uuidString,
                kind: .approvalRequested,
                timestamp: timestamp,
                source: .localCli,
                sessionId: "launch-boundary",
                payload: .object([:])
            )
        }
        precondition(
            !CoveLaunchAlertPolicy.eventOccurredAfterLaunch(
                envelope(at: launch.addingTimeInterval(-0.001)),
                launchedAt: launch,
                observedAt: launch
            )
        )

        let first = CoveWireEnvelope(
            eventId: "parallel-approval-1",
            kind: .approvalRequested,
            timestamp: launch,
            source: .localCli,
            sessionId: "parent-task",
            turnId: "child-turn",
            payload: .object([:])
        )
        let second = CoveWireEnvelope(
            eventId: "parallel-approval-2",
            kind: .approvalRequested,
            timestamp: launch,
            source: .localCli,
            sessionId: "parent-task",
            turnId: "child-turn",
            payload: .object([:])
        )
        let nextTurn = CoveWireEnvelope(
            eventId: "parallel-approval-3",
            kind: .approvalRequested,
            timestamp: launch,
            source: .localCli,
            sessionId: "parent-task",
            turnId: "next-turn",
            payload: .object([:])
        )
        let grouped = CoveNotificationIdentity.semanticKey(
            kind: .approval,
            envelope: first
        )
        precondition(
            grouped == CoveNotificationIdentity.semanticKey(
                kind: .approval,
                envelope: second
            )
        )
        precondition(
            grouped != CoveNotificationIdentity.semanticKey(
                kind: .approval,
                envelope: nextTurn
            )
        )
        let desktopCollision = CoveWireEnvelope(
            eventId: "parallel-approval-desktop",
            kind: .approvalRequested,
            timestamp: launch,
            source: .codexDesktop,
            sessionId: first.sessionId,
            turnId: first.turnId,
            payload: .object([:])
        )
        let remoteA = CoveWireEnvelope(
            eventId: "parallel-approval-remote-a",
            kind: .approvalRequested,
            timestamp: launch,
            source: .remoteCli,
            sessionId: first.sessionId,
            turnId: first.turnId,
            hostId: "remote-a",
            payload: .object([:])
        )
        var remoteB = remoteA
        remoteB.eventId = "parallel-approval-remote-b"
        remoteB.hostId = "remote-b"
        precondition(
            grouped != CoveNotificationIdentity.semanticKey(
                kind: .approval,
                envelope: desktopCollision
            )
        )
        precondition(
            CoveNotificationIdentity.semanticKey(kind: .approval, envelope: remoteA)
                != CoveNotificationIdentity.semanticKey(kind: .approval, envelope: remoteB)
        )
        precondition(
            CoveLaunchAlertPolicy.eventOccurredAfterLaunch(
                envelope(at: launch),
                launchedAt: launch,
                observedAt: launch
            )
        )
        precondition(
            !CoveLaunchAlertPolicy.eventOccurredAfterLaunch(
                envelope(at: launch.addingTimeInterval(6)),
                launchedAt: launch,
                observedAt: launch
            )
        )
    }

    static func testStartupNotificationBufferingAndResolution() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        func envelope(
            _ eventID: String,
            sessionID: String,
            turnID: String? = nil,
            launchID: String? = nil,
            source: CoveWireSource = .localCli,
            hostID: String? = nil
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventID,
                kind: .approvalRequested,
                timestamp: timestamp,
                source: source,
                sessionId: sessionID,
                turnId: turnID,
                launchId: launchID,
                hostId: hostID,
                payload: .object([:])
            )
        }

        var bounded = CoveStartupNotificationBuffer(capacity: 3)
        for index in 1...4 {
            bounded.append(
                envelope: envelope("event-\(index)", sessionID: "session-\(index)"),
                kind: .approval
            )
        }
        precondition(bounded.count == 3)
        let ordered = bounded.drain { _ in true }
        precondition(ordered.map(\.envelope.eventId) == [
            "event-2", "event-3", "event-4",
        ])
        precondition(bounded.isEmpty)

        var resolved = CoveStartupNotificationBuffer(capacity: 8)
        resolved.append(
            envelope: envelope(
                "turn-a",
                sessionID: "shared-session",
                turnID: "turn-a",
                launchID: "launch-a"
            ),
            kind: .approval
        )
        resolved.append(
            envelope: envelope(
                "turn-b",
                sessionID: "shared-session",
                turnID: "turn-b",
                launchID: "launch-a"
            ),
            kind: .input
        )
        resolved.append(
            envelope: envelope(
                "other-launch",
                sessionID: "shared-session",
                turnID: "turn-c",
                launchID: "launch-b"
            ),
            kind: .completed
        )
        resolved.resolve(
            sessionID: "shared-session",
            launchID: "launch-a",
            turnID: "turn-a",
            source: .localCli,
            hostID: nil
        )
        var remaining = resolved.drain { $0.envelope.eventId != "turn-b" }
        precondition(remaining.map(\.envelope.eventId) == ["other-launch"])
        precondition(resolved.isEmpty)

        resolved.append(
            envelope: envelope(
                "launch-a",
                sessionID: "shared-session",
                launchID: "launch-a"
            ),
            kind: .approval
        )
        resolved.append(
            envelope: envelope(
                "launch-b",
                sessionID: "shared-session",
                launchID: "launch-b"
            ),
            kind: .approval
        )
        resolved.resolve(
            sessionID: "shared-session",
            launchID: "launch-a",
            turnID: nil,
            source: .localCli,
            hostID: nil
        )
        remaining = resolved.drain { _ in true }
        precondition(remaining.map(\.envelope.eventId) == ["launch-b"])

        resolved.append(
            envelope: envelope("session-clear", sessionID: "shared-session"),
            kind: .approval
        )
        resolved.resolve(
            sessionID: "shared-session",
            launchID: nil,
            turnID: nil,
            source: .localCli,
            hostID: nil
        )
        precondition(resolved.isEmpty)

        resolved.append(
            envelope: envelope(
                "remote-a",
                sessionID: "remote-shared",
                launchID: "remote-launch",
                source: .remoteCli,
                hostID: "host-a"
            ),
            kind: .approval
        )
        resolved.append(
            envelope: envelope(
                "remote-b",
                sessionID: "remote-shared",
                launchID: "remote-launch",
                source: .remoteCli,
                hostID: "host-b"
            ),
            kind: .approval
        )
        resolved.resolve(
            sessionID: "remote-shared",
            launchID: "remote-launch",
            turnID: nil,
            source: .remoteCli,
            hostID: "host-a"
        )
        remaining = resolved.drain { _ in true }
        precondition(remaining.map(\.envelope.eventId) == ["remote-b"])
    }

    static func testApprovalReviewSubagentsAreInvisible() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let reviewerFields: [String: CoveJSONValue] = [
            "session_id": .string("parent-task"),
            "turn_id": .string("approval-review-turn"),
            "model": .string("codex-auto-review"),
        ]
        func reviewerHook(
            eventID: String,
            hookName: String,
            extraPayload: [String: CoveJSONValue] = [:]
        ) -> CoveWireEnvelope {
            var data = reviewerFields
            data["hookEventName"] = .string(hookName)
            var payload: [String: CoveJSONValue] = [
                "hookEventName": .string(hookName),
                "data": .object(data),
            ]
            for (key, value) in extraPayload {
                payload[key] = value
            }
            return CoveWireEnvelope(
                eventId: eventID,
                kind: .hook,
                timestamp: timestamp,
                source: .localCli,
                sessionId: "parent-task",
                turnId: "approval-review-turn",
                payload: .object(payload)
            )
        }
        let guardianAppServerEvent = CoveWireEnvelope(
            eventId: "guardian-app-server-start",
            kind: .appServer,
            timestamp: timestamp,
            source: .codexDesktop,
            sessionId: "guardian-thread",
            turnId: "guardian-turn",
            payload: .object([
                "message": .object([
                    "method": .string("thread/started"),
                    "params": .object([
                        "thread": .object([
                            "id": .string("guardian-thread"),
                            "source": .object([
                                "subAgent": .object([
                                    "other": .string("guardian"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )
        let autoRoutedApproval = CoveWireEnvelope(
            eventId: "auto-routed-parent-approval",
            kind: .approvalRequested,
            timestamp: timestamp,
            source: .localCli,
            sessionId: "auto-routed-parent",
            turnId: "auto-routed-turn",
            payload: .object([
                "message": .object([
                    "id": .string("auto-routed-request"),
                    "method": .string(
                        "item/commandExecution/requestApproval"
                    ),
                    "params": .object([
                        "threadId": .string("auto-routed-parent"),
                        "turnId": .string("auto-routed-turn"),
                        "availableDecisions": .array([
                            .string("accept"),
                            .string("decline"),
                        ]),
                    ]),
                ]),
            ])
        )
        func autoReviewLifecycle(
            eventID: String,
            method: String
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventID,
                kind: .appServer,
                timestamp: timestamp,
                source: .localCli,
                sessionId: "parent-task",
                turnId: "parent-turn",
                payload: .object([
                    "message": .object([
                        "method": .string(method),
                        "params": .object([
                            "threadId": .string("parent-task"),
                            "turnId": .string("parent-turn"),
                            "reviewId": .string("review-1"),
                        ]),
                    ]),
                ])
            )
        }

        let reviewerEvents = [
            reviewerHook(
                eventID: "reviewer-session-start",
                hookName: "SessionStart"
            ),
            reviewerHook(
                eventID: "reviewer-permission",
                hookName: "PermissionRequest",
                extraPayload: [
                    "requestId": .string("reviewer-request"),
                    "decisionSocket": .string("/tmp/reviewer.sock"),
                    "choices": .array([
                        .object([
                            "id": .string("accept"),
                            "label": .string("Allow"),
                        ]),
                        .object([
                            "id": .string("decline"),
                            "label": .string("Deny"),
                        ]),
                    ]),
                ]
            ),
            reviewerHook(
                eventID: "reviewer-stop",
                hookName: "Stop"
            ),
            autoReviewLifecycle(
                eventID: "auto-review-started",
                method: "item/autoApprovalReview/started"
            ),
            autoReviewLifecycle(
                eventID: "auto-review-completed",
                method: "item/autoApprovalReview/completed"
            ),
            guardianAppServerEvent,
        ]

        var state = CoveState()
        var visibilityPolicy = CoveEventVisibilityPolicy()
        let pristine = state
        for event in reviewerEvents {
            precondition(visibilityPolicy.shouldSuppress(event))
            precondition(CoveNotificationEventKind.classify(event) == nil)
            CoveReducer.reduce(&state, .receivedEnvelope(event))
        }
        precondition(state == pristine)
        precondition(state.session.snapshots.isEmpty)
        precondition(state.pendingDirectRequests.isEmpty)
        precondition(state.recentEvents.isEmpty)
        precondition(state.lastEvent == nil)
        precondition(state.session.lastEnvelope == nil)

        // An app-server requestApproval is authoritative user routing for the
        // connected client. Never hide it based on a thread/config default.
        precondition(!visibilityPolicy.shouldSuppress(autoRoutedApproval))
        precondition(
            CoveNotificationEventKind.classify(autoRoutedApproval) == .approval
        )

        // Current hook input omits per-request reviewer routing. Cove must
        // defer that ambiguous request to native Codex without any history or
        // notification, even when its model is an ordinary task model.
        let ambiguousHookApproval = CoveWireEnvelope(
            eventId: "ambiguous-hook-approval",
            kind: .hook,
            timestamp: timestamp,
            source: .codexDesktop,
            sessionId: "parent-task",
            turnId: "parent-turn",
            payload: .object([
                "hookEventName": .string("PermissionRequest"),
                "data": .object([
                    "hook_event_name": .string("PermissionRequest"),
                    "session_id": .string("parent-task"),
                    "turn_id": .string("parent-turn"),
                    "model": .string("gpt-5.6"),
                    "permission_mode": .string("default"),
                ]),
            ])
        )
        precondition(visibilityPolicy.shouldSuppress(ambiguousHookApproval))
        precondition(CoveNotificationEventKind.classify(ambiguousHookApproval) == nil)
        CoveReducer.reduce(&state, .receivedEnvelope(ambiguousHookApproval))
        precondition(state == pristine)

        // Follow-up events often omit the source object. Once the canonical
        // guardian start is observed, the policy must keep that thread hidden.
        let guardianFollowUp = CoveWireEnvelope(
            eventId: "guardian-follow-up",
            kind: .sessionStatus,
            timestamp: timestamp.addingTimeInterval(0.5),
            source: .codexDesktop,
            sessionId: "guardian-thread",
            turnId: "guardian-turn",
            payload: .object([
                "status": .string("working"),
                "priority": .number(40),
                "summary": .string("Internal guardian work"),
            ])
        )
        precondition(visibilityPolicy.shouldSuppress(guardianFollowUp))
        precondition(state == pristine)

        let localCollisionFollowUp = CoveWireEnvelope(
            eventId: "guardian-local-collision",
            kind: .sessionStatus,
            timestamp: timestamp.addingTimeInterval(0.6),
            source: .localCli,
            sessionId: "guardian-thread",
            payload: .object([
                "status": .string("working"),
                "priority": .number(40),
            ])
        )
        precondition(
            !visibilityPolicy.shouldSuppress(localCollisionFollowUp),
            "a Desktop guardian ID must not suppress a local task collision"
        )

        func remoteGuardian(
            eventID: String,
            hostID: String
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventID,
                kind: .appServer,
                timestamp: timestamp,
                source: .remoteCli,
                sessionId: "remote-guardian-thread",
                hostId: hostID,
                payload: .object([
                    "message": .object([
                        "method": .string("thread/started"),
                        "params": .object([
                            "thread": .object([
                                "id": .string("remote-guardian-thread"),
                                "source": .object([
                                    "subAgent": .object([
                                        "other": .string("guardian"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        }
        precondition(
            visibilityPolicy.shouldSuppress(
                remoteGuardian(eventID: "remote-guardian-a", hostID: "host-a")
            )
        )
        let remoteHostAFollowUp = CoveWireEnvelope(
            eventId: "remote-guardian-a-follow-up",
            kind: .sessionStatus,
            timestamp: timestamp.addingTimeInterval(0.7),
            source: .remoteCli,
            sessionId: "remote-guardian-thread",
            hostId: "host-a",
            payload: .object(["status": .string("working")])
        )
        let remoteHostBCollision = CoveWireEnvelope(
            eventId: "remote-guardian-b-collision",
            kind: .sessionStatus,
            timestamp: timestamp.addingTimeInterval(0.8),
            source: .remoteCli,
            sessionId: "remote-guardian-thread",
            hostId: "host-b",
            payload: .object(["status": .string("working")])
        )
        precondition(visibilityPolicy.shouldSuppress(remoteHostAFollowUp))
        precondition(
            !visibilityPolicy.shouldSuppress(remoteHostBCollision),
            "a guardian on one remote host must not suppress another host"
        )

        var hydratedVisibilityPolicy = CoveEventVisibilityPolicy()
        hydratedVisibilityPolicy.hideApprovalReviewThread(
            sessionId: "hydrated-guardian",
            source: .codexDesktop,
            hostId: nil
        )
        let hydratedGuardianFollowUp = CoveWireEnvelope(
            eventId: "hydrated-guardian-follow-up",
            kind: .sessionStatus,
            timestamp: timestamp,
            source: .codexDesktop,
            sessionId: "hydrated-guardian",
            payload: .object(["status": .string("working")])
        )
        precondition(
            hydratedVisibilityPolicy.shouldSuppress(hydratedGuardianFollowUp),
            "hydration-discovered guardians must keep later status events hidden"
        )
        let hydratedLocalCollision = CoveWireEnvelope(
            eventId: "hydrated-guardian-local-collision",
            kind: .sessionStatus,
            timestamp: timestamp,
            source: .localCli,
            sessionId: "hydrated-guardian",
            payload: .object(["status": .string("working")])
        )
        precondition(!hydratedVisibilityPolicy.shouldSuppress(hydratedLocalCollision))

        // Ordinary parent lifecycle remains visible.
        let parentSessionStart = CoveWireEnvelope(
            eventId: "parent-session-start",
            kind: .hook,
            timestamp: timestamp.addingTimeInterval(1),
            source: .localCli,
            sessionId: "parent-task",
            turnId: "parent-turn",
            payload: .object([
                "hookEventName": .string("SessionStart"),
                "data": .object([
                    "hookEventName": .string("SessionStart"),
                    "session_id": .string("parent-task"),
                    "turn_id": .string("parent-turn"),
                    "model": .string("gpt-5.6"),
                ]),
            ])
        )
        precondition(
            !visibilityPolicy.shouldSuppress(parentSessionStart)
        )
        CoveReducer.reduce(&state, .receivedEnvelope(parentSessionStart))
        precondition(state.session.snapshots.count == 1)
        precondition(state.session.activeSnapshot?.status == .listening)
        precondition(state.recentEvents.count == 1)

        // Broker-observed app-server approvals are authoritative and remain
        // actionable. Hook-only PermissionRequest events stay native above.
        let parentApproval = CoveWireEnvelope(
            eventId: "parent-permission",
            kind: .approvalRequested,
            timestamp: timestamp.addingTimeInterval(2),
            source: .localCli,
            sessionId: "parent-task",
            turnId: "parent-turn",
            payload: .object([
                "decisionSocket": .string("/tmp/parent.sock"),
                "message": .object([
                    "id": .string("parent-request"),
                    "method": .string(
                        "item/commandExecution/requestApproval"
                    ),
                    "params": .object([
                        "threadId": .string("parent-task"),
                        "turnId": .string("parent-turn"),
                        "availableDecisions": .array([
                            .string("accept"),
                            .string("decline"),
                        ]),
                    ]),
                ]),
            ])
        )
        precondition(
            !visibilityPolicy.shouldSuppress(parentApproval)
        )
        precondition(
            CoveNotificationEventKind.classify(parentApproval) == .approval
        )
        CoveReducer.reduce(&state, .receivedEnvelope(parentApproval))
        precondition(state.pendingDirectRequests.count == 1)
        precondition(state.session.snapshots.count == 1)
        precondition(state.session.activeSnapshot?.status == .waitingApproval)
        precondition(state.recentEvents.count == 2)

        // Real SubagentStart hooks carry the parent session id and child agent
        // id separately. They remain visible as parent activity; canonical
        // app-server child threads are covered by hydration parsing below.
        let ordinarySubagent = CoveWireEnvelope(
            eventId: "ordinary-subagent-start",
            kind: .hook,
            timestamp: timestamp.addingTimeInterval(3),
            source: .localCli,
            sessionId: "parent-task",
            turnId: "ordinary-child-turn",
            payload: .object([
                "hookEventName": .string("SubagentStart"),
                "data": .object([
                    "hookEventName": .string("SubagentStart"),
                    "session_id": .string("parent-task"),
                    "turn_id": .string("ordinary-child-turn"),
                    "model": .string("gpt-5.6"),
                    "agent_id": .string("ordinary-child"),
                    "agent_type": .string("explorer"),
                ]),
            ])
        )
        precondition(
            !visibilityPolicy.shouldSuppress(ordinarySubagent)
        )
        CoveReducer.reduce(&state, .receivedEnvelope(ordinarySubagent))
        precondition(
            state.session.snapshots.first {
                $0.snapshotId == "parent-task"
            }?.status == .working
        )
        precondition(
            !state.session.snapshots.contains {
                $0.snapshotId == "ordinary-child"
            }
        )
        precondition(state.recentEvents.count == 3)

        // Discovering a previously materialized guardian purges only that
        // internal session. Unrelated event history and sessions survive.
        let unrelatedEvent = CoveEvent(
            kind: .display,
            title: "Ordinary task activity",
            source: CoveWireSource.localCli.rawValue,
            sessionId: "ordinary-history-task",
            timestamp: timestamp
        )
        let guardianHistoryEvent = CoveEvent(
            kind: .display,
            title: "Internal approval review",
            source: CoveWireSource.codexDesktop.rawValue,
            sessionId: "guardian-thread",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let collidingLocalHistoryEvent = CoveEvent(
            kind: .display,
            title: "Legitimate colliding local task",
            source: CoveWireSource.localCli.rawValue,
            sessionId: "guardian-thread",
            timestamp: timestamp.addingTimeInterval(2)
        )
        let ordinarySnapshot = CoveSessionSnapshot(
            snapshotId: "ordinary-history-task",
            status: .working,
            priority: 40,
            title: "Ordinary history task",
            timestamp: timestamp,
            sessionId: "ordinary-history-task",
            source: .localCli
        )
        let guardianSnapshot = CoveSessionSnapshot(
            snapshotId: "guardian-thread",
            status: .waitingApproval,
            priority: 100,
            title: "Legacy guardian task",
            timestamp: timestamp,
            sessionId: "guardian-thread",
            source: .codexDesktop,
            unread: true
        )
        let collidingLocalSnapshot = CoveSessionSnapshot(
            snapshotId: "guardian-thread",
            status: .working,
            priority: 40,
            title: "Legitimate local collision",
            timestamp: timestamp.addingTimeInterval(2),
            sessionId: "guardian-thread",
            source: .localCli
        )
        let desktopTokenKey = CoveScopedIdentityKey.session(
            sessionId: "guardian-thread",
            source: .codexDesktop,
            hostId: nil
        )
        let localTokenKey = CoveScopedIdentityKey.session(
            sessionId: "guardian-thread",
            source: .localCli,
            hostId: nil
        )
        var purgeState = CoveState(
            session: .init(
                activeStatus: .waitingApproval,
                statusPriority: 100,
                activeSnapshot: guardianSnapshot,
                snapshots: [guardianSnapshot, collidingLocalSnapshot, ordinarySnapshot],
                lastEnvelope: guardianAppServerEvent
            ),
            lastEvent: collidingLocalHistoryEvent,
            recentEvents: [
                collidingLocalHistoryEvent,
                guardianHistoryEvent,
                unrelatedEvent,
            ],
            pinnedSessionIDs: ["guardian-thread", "ordinary-history-task"],
            dismissedSessionIDs: ["guardian-thread"],
            sessionTokenMetrics: [
                desktopTokenKey: .init(
                    inputTokens: 1,
                    cachedInputTokens: nil,
                    outputTokens: 1,
                    reasoningOutputTokens: nil,
                    totalTokens: 2,
                    contextWindow: 100,
                    capturedAt: timestamp
                ),
                localTokenKey: .init(
                    inputTokens: 2,
                    cachedInputTokens: nil,
                    outputTokens: 2,
                    reasoningOutputTokens: nil,
                    totalTokens: 4,
                    contextWindow: 100,
                    capturedAt: timestamp
                ),
            ]
        )
        CoveReducer.reduce(
            &purgeState,
            .forgetInternalSession(
                sessionId: "guardian-thread",
                source: .codexDesktop,
                hostId: nil
            )
        )
        precondition(
            purgeState.session.snapshots.contains(collidingLocalSnapshot)
        )
        precondition(purgeState.session.snapshots.contains(ordinarySnapshot))
        precondition(!purgeState.session.snapshots.contains(guardianSnapshot))
        precondition(purgeState.session.activeSnapshot == collidingLocalSnapshot)
        precondition(purgeState.session.lastEnvelope == nil)
        precondition(
            purgeState.recentEvents
                == [collidingLocalHistoryEvent, unrelatedEvent]
        )
        precondition(purgeState.lastEvent == collidingLocalHistoryEvent)
        precondition(
            purgeState.pinnedSessionIDs
                == ["guardian-thread", "ordinary-history-task"]
        )
        precondition(purgeState.dismissedSessionIDs.contains("guardian-thread"))
        precondition(purgeState.sessionTokenMetrics[desktopTokenKey] == nil)
        precondition(purgeState.sessionTokenMetrics[localTokenKey]?.totalTokens == 4)

        let remoteHostASnapshot = CoveSessionSnapshot(
            snapshotId: "remote-guardian-thread",
            status: .waitingApproval,
            priority: 100,
            title: "Remote guardian",
            timestamp: timestamp,
            sessionId: "remote-guardian-thread",
            source: .remoteCli,
            hostId: "host-a"
        )
        let remoteHostBSnapshot = CoveSessionSnapshot(
            snapshotId: "remote-guardian-thread",
            status: .working,
            priority: 40,
            title: "Legitimate remote collision",
            timestamp: timestamp.addingTimeInterval(1),
            sessionId: "remote-guardian-thread",
            source: .remoteCli,
            hostId: "host-b"
        )
        let remoteHostAEvent = CoveEvent(
            kind: .display,
            title: "Remote guardian activity",
            source: CoveWireSource.remoteCli.rawValue,
            hostId: "host-a",
            sessionId: "remote-guardian-thread",
            timestamp: timestamp
        )
        let remoteHostBEvent = CoveEvent(
            kind: .display,
            title: "Legitimate remote activity",
            source: CoveWireSource.remoteCli.rawValue,
            hostId: "host-b",
            sessionId: "remote-guardian-thread",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let remoteHostATokenKey = CoveScopedIdentityKey.session(
            sessionId: "remote-guardian-thread",
            source: .remoteCli,
            hostId: "host-a"
        )
        let remoteHostBTokenKey = CoveScopedIdentityKey.session(
            sessionId: "remote-guardian-thread",
            source: .remoteCli,
            hostId: "host-b"
        )
        let tokenMetrics = CoveSessionTokenMetrics(
            inputTokens: 3,
            cachedInputTokens: nil,
            outputTokens: 2,
            reasoningOutputTokens: nil,
            totalTokens: 5,
            contextWindow: 100,
            capturedAt: timestamp
        )
        var remotePurgeState = CoveState(
            session: .init(
                activeStatus: .waitingApproval,
                statusPriority: 100,
                activeSnapshot: remoteHostASnapshot,
                snapshots: [remoteHostASnapshot, remoteHostBSnapshot]
            ),
            lastEvent: remoteHostBEvent,
            recentEvents: [remoteHostBEvent, remoteHostAEvent],
            sessionTokenMetrics: [
                remoteHostATokenKey: tokenMetrics,
                remoteHostBTokenKey: tokenMetrics,
            ]
        )
        CoveReducer.reduce(
            &remotePurgeState,
            .forgetInternalSession(
                sessionId: "remote-guardian-thread",
                source: .remoteCli,
                hostId: "host-a"
            )
        )
        precondition(remotePurgeState.session.snapshots == [remoteHostBSnapshot])
        precondition(remotePurgeState.recentEvents == [remoteHostBEvent])
        precondition(remotePurgeState.lastEvent == remoteHostBEvent)
        precondition(remotePurgeState.sessionTokenMetrics[remoteHostATokenKey] == nil)
        precondition(
            remotePurgeState.sessionTokenMetrics[remoteHostBTokenKey] == tokenMetrics
        )
    }

    static func testPixelResidentCatalog() throws {
        let archetypes = CovePixelCharacterArchetype.allCases
        precondition(archetypes.count == 16)
        precondition(Set(archetypes.map(\.rawValue)).count == archetypes.count)
        precondition(CoveResidentSet.allCases.count == 3)
        let residentSetArchetypes = CoveResidentSet.allCases.flatMap(\.archetypes)
        precondition(Set(residentSetArchetypes) == Set(archetypes))
        precondition(residentSetArchetypes.count == archetypes.count)
        for set in CoveResidentSet.allCases {
            precondition(!set.archetypes.isEmpty)
            let assignment = CovePixelCharacter.assigned(
                to: "stable-thread-id",
                set: set
            )
            precondition(
                assignment == CovePixelCharacter.assigned(
                    to: "stable-thread-id",
                    set: set
                )
            )
            precondition(set.archetypes.contains(assignment.archetype))
        }

        let silhouetteSignatures = Set(archetypes.map { archetype in
            CovePixelCharacter(archetype: archetype)
                .frame(status: .idle, phase: 0)
        })
        precondition(silhouetteSignatures.count == archetypes.count)
        precondition(Set(archetypes.map(\.colorway)).count == archetypes.count)
        precondition(Set(archetypes.map { $0.colorway.seed }).count == archetypes.count)

        let animatedStatuses: [CoveSessionStatus] = [
            .working, .active, .compacting,
        ]
        let frozenCallouts: [(CoveSessionStatus, CovePixelCalloutGlyph)] = [
            (.waitingApproval, .exclamation),
            (.waitingInput, .question),
            (.blocked, .lock),
            (.completed, .checkmark),
            (.failed, .xmark),
            (.interrupted, .stop),
        ]
        let staticStatuses: [CoveSessionStatus] = [
            .idle, .listening, .quiet, .hidden,
        ]

        for archetype in archetypes {
            let resident = CovePixelCharacter(archetype: archetype)

            let colorway = resident.colorway
            precondition(colorway.bodyHueDegrees >= 0 && colorway.bodyHueDegrees < 360)
            precondition(colorway.accentHueDegrees >= 0 && colorway.accentHueDegrees < 360)
            precondition(colorway.activityHueDegrees >= 0 && colorway.activityHueDegrees < 360)
            precondition(colorway.saturation >= 0 && colorway.saturation <= 1)
            precondition(colorway.brightness >= 0 && colorway.brightness <= 1)
            precondition(
                CovePixelCharacter(archetype: archetype, variation: 3).colorway
                    != colorway
            )

            for status in animatedStatuses {
                precondition(archetype.animates(status: status))
                precondition(resident.animates(status: status))
                precondition(archetype.calloutGlyph(status: status) == nil)
                let frames = Set((0..<archetype.frameCount).map {
                    resident.frame(status: status, phase: $0)
                })
                precondition(frames.count == archetype.frameCount)
                precondition(
                    resident.frame(status: status, phase: -1)
                        == resident.frame(status: status, phase: 3)
                )
            }

            for (status, glyph) in frozenCallouts {
                precondition(!archetype.animates(status: status))
                precondition(!resident.animates(status: status))
                precondition(archetype.calloutGlyph(status: status) == glyph)
                precondition(resident.calloutGlyph(status: status) == glyph)
                let frames = Set((0..<archetype.frameCount).map {
                    resident.frame(status: status, phase: $0)
                })
                precondition(frames.count == 1)
                let frozen = resident.frame(status: status, phase: 0)
                precondition(frozen != resident.frame(status: .idle, phase: 0))
                precondition(frozen.pixels.contains { $0.ink == .activity })
            }

            for status in staticStatuses {
                precondition(!archetype.animates(status: status))
                precondition(archetype.calloutGlyph(status: status) == nil)
                let frames = Set((0..<archetype.frameCount).map {
                    resident.frame(status: status, phase: $0)
                })
                precondition(frames.count == 1)
            }

            for status in CoveSessionStatus.allCases {
                for phase in 0..<archetype.frameCount {
                    for pixel in resident.frame(status: status, phase: phase).pixels {
                        precondition(pixel.x >= 0)
                        precondition(pixel.x < CovePixelFrame.gridWidth)
                        precondition(pixel.y >= 0)
                        precondition(pixel.y < CovePixelFrame.gridHeight)
                    }
                }
            }
        }
        let compactPixel = CovePixelCharacterGeometry.pixelSize(
            availableWidth: 25,
            availableHeight: 25,
            backingScale: 2
        )
        precondition(compactPixel == 1.5)
        let tallSprite = CovePixelCharacterGeometry.spriteSize(
            availableWidth: 50,
            availableHeight: 32,
            backingScale: 2
        )
        precondition(tallSprite.width == 24)
        precondition(tallSprite.height == 28)
        let sameHeightManyCues = CovePixelCharacterGeometry.spriteSize(
            availableWidth: 50,
            availableHeight: 32,
            backingScale: 2
        )
        precondition(sameHeightManyCues == tallSprite)
    }

    static func testCollapsedResidentFlow() throws {
        let notchLayout = CoveResidentFlowLayout.resolve(
            width: 245,
            height: 66.3,
            topBandHeight: 32,
            centerClearance: 185
        )
        precondition(notchLayout.width == 245)
        precondition(notchLayout.height == 66.3)
        precondition(notchLayout.topBandHeight == 32)
        precondition(notchLayout.centerClearance == 185)
        precondition(
            notchLayout.slots.filter { $0.lane == .left }.count == 1
        )
        precondition(
            notchLayout.slots.filter { $0.lane == .lower }.count == 6
        )
        precondition(
            notchLayout.slots.filter { $0.lane == .right }.count == 1
        )
        precondition(notchLayout.capacity == 8)
        precondition(notchLayout.slots.map(\.id) == Array(0..<8))

        for slot in notchLayout.slots {
            precondition(slot.size >= 14)
            precondition(slot.centerX - slot.size / 2 >= 0)
            precondition(slot.centerX + slot.size / 2 <= notchLayout.width)
            precondition(slot.centerY - slot.size / 2 >= 0)
            precondition(slot.centerY + slot.size / 2 <= notchLayout.height)
            switch slot.lane {
            case .left:
                precondition(
                    slot.centerX + slot.size / 2
                        <= (notchLayout.width - notchLayout.centerClearance) / 2
                )
            case .right:
                precondition(
                    slot.centerX - slot.size / 2
                        >= (notchLayout.width + notchLayout.centerClearance) / 2
                )
            case .lower:
                precondition(slot.centerY - slot.size / 2 >= 32)
            }
        }

        let badgeReservedLayout = CoveResidentFlowLayout.resolve(
            width: 245,
            height: 66.3,
            topBandHeight: 32,
            centerClearance: 185,
            lowerTrailingReservation: 36
        )
        precondition(badgeReservedLayout.capacity == 7)
        precondition(
            badgeReservedLayout.slots.filter { $0.lane == .lower }.count == 5
        )
        precondition(
            badgeReservedLayout.slots
                .filter { $0.lane == .lower }
                .allSatisfy { $0.centerX + $0.size / 2 <= 202 }
        )

        let normalizedLayout = CoveResidentFlowLayout.resolve(
            width: -.infinity,
            height: .nan,
            topBandHeight: -12,
            centerClearance: 500,
            lowerTrailingReservation: -30
        )
        precondition(normalizedLayout.width == 0)
        precondition(normalizedLayout.height == 0)
        precondition(normalizedLayout.topBandHeight == 0)
        precondition(normalizedLayout.centerClearance == 0)
        precondition(normalizedLayout.capacity == 0)

        let residentCount = 12
        let slotCount = badgeReservedLayout.capacity
        let allAssignments = (0..<residentCount).flatMap { step in
            CoveResidentFlowSequence.assignments(
                residentCount: residentCount,
                slotCount: slotCount,
                step: step
            )
        }
        precondition(
            Set(allAssignments.map(\.residentIndex))
                == Set(0..<residentCount)
        )
        for step in 0..<residentCount {
            let assignments = CoveResidentFlowSequence.assignments(
                residentCount: residentCount,
                slotCount: slotCount,
                step: step
            )
            precondition(assignments.count == slotCount)
            precondition(Set(assignments.map(\.residentIndex)).count == slotCount)
            precondition(assignments.map(\.slotIndex) == Array(0..<slotCount))
        }

        let firstStep = CoveResidentFlowSequence.assignments(
            residentCount: residentCount,
            slotCount: slotCount,
            step: 0
        )
        let secondStep = CoveResidentFlowSequence.assignments(
            residentCount: residentCount,
            slotCount: slotCount,
            step: 1
        )
        precondition(firstStep[1].residentIndex == secondStep[0].residentIndex)
        precondition(
            CoveResidentFlowSequence.assignments(
                residentCount: residentCount,
                slotCount: slotCount,
                step: -1
            ).first?.residentIndex == residentCount - 1
        )

        let noOverflow = CoveResidentFlowSequence.assignments(
            residentCount: 3,
            slotCount: slotCount,
            step: 99
        )
        precondition(noOverflow.map(\.residentIndex) == [0, 1, 2])
        precondition(noOverflow.map(\.slotIndex) == [0, 1, 2])
        precondition(
            CoveResidentFlowSequence.hiddenCount(
                residentCount: residentCount,
                slotCount: slotCount
            ) == residentCount - slotCount
        )
        precondition(
            CoveResidentFlowSequence.hiddenCount(
                residentCount: -1,
                slotCount: -1
            ) == 0
        )
    }

    static func testMinimalIslandGeometryAndMigration() throws {
        let minimal = CoveOverlayGeometry.size(
            expanded: true,
            privacyMode: .on,
            minimalIslandMode: true
        )
        precondition(minimal.width == 126)
        precondition(minimal.height == 32)
        let tallMenuBarMinimal = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: true,
            topContentInset: 38
        )
        precondition(tallMenuBarMinimal.height == 38)
        let minimalFallback = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: true,
            topContentInset: 0
        )
        precondition(minimalFallback.height == 24)
        let expanded = CoveOverlayGeometry.size(
            expanded: true,
            privacyMode: .auto,
            minimalIslandMode: false
        )
        precondition(expanded.width == 260)
        precondition(expanded.height == 520)
        let collapsed = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: false,
            collapsedWidth: 198
        )
        precondition(collapsed.width == 210)
        precondition(abs(collapsed.height - 61.4) < 0.001)
        let defaultCollapsed = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: false
        )
        precondition(defaultCollapsed.width == 260)
        precondition(abs(defaultCollapsed.height - 68.4) < 0.001)
        let narrowCollapsed = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: false,
            collapsedWidth: 100
        )
        precondition(narrowCollapsed.width == 210)
        let mediumCollapsed = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: false,
            collapsedWidth: 300
        )
        precondition(mediumCollapsed.width == 300)
        precondition(abs(mediumCollapsed.height - 74) < 0.001)
        let wideCollapsed = CoveOverlayGeometry.size(
            expanded: false,
            privacyMode: .auto,
            minimalIslandMode: false,
            collapsedWidth: 500
        )
        precondition(wideCollapsed.width == 420)
        precondition(abs(wideCollapsed.height - 90.8) < 0.001)
        precondition(CoveOverlayGeometry.collapsedDepth(forWidth: 100) == 28)
        precondition(CoveOverlayGeometry.collapsedDepth(forWidth: 500) == 60)
        precondition(CoveOverlayGeometry.topGap(expanded: false) == 0)
        let externalScreen = CoveScreenMetrics(
            screenWidth: 320,
            screenHeight: 900,
            safeAreaTop: 32,
            safeAreaLeft: 18,
            safeAreaRight: 18
        )
        let resolvedExternalWidth = CoveOverlayGeometry.resolvedWidth(
            screen: externalScreen,
            desiredWidth: 500
        )
        let externalCollapsedHeight = CoveOverlayGeometry.collapsedHeight(
            forWidth: resolvedExternalWidth,
            topContentInset: 32
        )
        let collapsedLayout = CoveOverlayGeometry.layout(
            screen: externalScreen,
            desiredWidth: 500,
            desiredHeight: externalCollapsedHeight,
            expanded: false
        )
        precondition(collapsedLayout.insetFromTop == 0)
        precondition(abs(collapsedLayout.originY - 828.24) < 0.001)
        precondition(
            collapsedLayout.originY + collapsedLayout.height
                == externalScreen.screenHeight
        )
        precondition(collapsedLayout.originX >= 18)
        precondition(collapsedLayout.width == 284)

        let notchedScreen = CoveScreenMetrics(
            screenWidth: 1_512,
            screenHeight: 982,
            safeAreaTop: 32,
            auxiliaryTopLeftWidth: 663,
            auxiliaryTopRightWidth: 664
        )
        precondition(notchedScreen.topObstructionWidth == 185)
        let notchResolvedWidth = CoveOverlayGeometry.resolvedWidth(
            screen: notchedScreen,
            desiredWidth: 210
        )
        let notchCollapsedHeight = CoveOverlayGeometry.collapsedHeight(
            forWidth: notchResolvedWidth,
            topContentInset: 32
        )
        let notchSafeCollapsed = CoveOverlayGeometry.layout(
            screen: notchedScreen,
            desiredWidth: 210,
            desiredHeight: notchCollapsedHeight,
            expanded: false
        )
        let notchSafeExpanded = CoveOverlayGeometry.layout(
            screen: notchedScreen,
            desiredWidth: 210,
            desiredHeight: 520,
            expanded: true
        )
        precondition(notchSafeCollapsed.width == 245)
        precondition(abs(notchSafeCollapsed.height - 66.3) < 0.001)
        precondition(notchSafeExpanded.width == notchSafeCollapsed.width)
        precondition(notchSafeCollapsed.originY + notchSafeCollapsed.height == 982)
        precondition(notchSafeExpanded.originY + notchSafeExpanded.height == 982)
        let cueSnapshots = [
            CoveSessionSnapshot(
                snapshotId: "running-cue",
                status: .working,
                priority: 40,
                title: "Sensitive title",
                timestamp: Date()
            ),
            CoveSessionSnapshot(
                snapshotId: "completed-unread-cue",
                status: .completed,
                priority: 80,
                title: "Sensitive title",
                timestamp: Date(),
                unread: true
            ),
            CoveSessionSnapshot(
                snapshotId: "completed-read-hidden",
                status: .completed,
                priority: 8,
                title: "Sensitive title",
                timestamp: Date(),
                unread: false
            ),
            CoveSessionSnapshot(
                snapshotId: "idle-hidden",
                status: .idle,
                priority: 5,
                title: "Sensitive title",
                timestamp: Date()
            ),
        ]
        precondition(
            CoveSessionVisualCuePolicy.visibleSnapshots(in: cueSnapshots)
                .map(\.snapshotId)
                == ["running-cue", "completed-unread-cue"]
        )
        precondition(
            CoveSessionVisualCuePolicy.distinctVisibleStatuses(
                in: cueSnapshots
            ) == [.working, .completed]
        )
        precondition(
            CoveSessionVisualCuePolicy.distinctVisibleStatuses(
                in: Array(cueSnapshots.dropFirst(2))
            ).isEmpty
        )

        var state = CoveState()
        CoveReducer.reduce(&state, .setMinimalIslandMode(true))
        CoveReducer.reduce(&state, .setResidentSet(.techCreatures))
        CoveReducer.reduce(&state, .setExpanded(true))
        precondition(state.settings.minimalIslandMode)
        precondition(state.settings.residentSet == .techCreatures)
        precondition(!state.session.isExpanded)
        CoveReducer.reduce(&state, .setShowUsage(false))
        CoveReducer.reduce(&state, .setShowProfileTokenUsage(true))
        CoveReducer.reduce(&state, .setShowTokenMetrics(true))
        CoveReducer.reduce(&state, .setCollapsedWidth(210))
        CoveReducer.reduce(&state, .setTextScale(1.5))
        CoveReducer.reduce(&state, .setSquareTopCorners(false))
        CoveReducer.reduce(
            &state,
            .setQueueSectionOrder([
                .active,
                .recentlyFinished,
                .active,
            ])
        )
        CoveReducer.reduce(
            &state,
            .setQueueSectionCollapsed(.recentlyFinished, true)
        )
        precondition(!state.settings.showUsage)
        precondition(state.settings.showProfileTokenUsage)
        precondition(state.settings.showTokenMetrics)
        precondition(state.settings.collapsedWidth == 210)
        precondition(state.settings.textScale == 1.5)
        precondition(!state.settings.squareTopCorners)
        precondition(
            state.settings.queueSectionOrder
                == [.active, .recentlyFinished, .needsAttention, .more]
        )
        precondition(
            state.settings.collapsedQueueSections
                == [.recentlyFinished, .more]
        )
        CoveReducer.reduce(
            &state,
            .setQueueSectionCollapsed(.recentlyFinished, false)
        )
        precondition(state.settings.collapsedQueueSections == [.more])
        CoveReducer.reduce(&state, .setCollapsedWidth(90))
        precondition(state.settings.collapsedWidth == 210)
        CoveReducer.reduce(&state, .setCollapsedWidth(900))
        precondition(state.settings.collapsedWidth == 420)
        CoveReducer.reduce(&state, .setCollapsedWidth(.nan))
        precondition(state.settings.collapsedWidth == 260)
        CoveReducer.reduce(&state, .setTextScale(0.5))
        precondition(state.settings.textScale == 1)
        CoveReducer.reduce(&state, .setTextScale(3))
        precondition(state.settings.textScale == 2)
        CoveReducer.reduce(&state, .setTextScale(.infinity))
        precondition(state.settings.textScale == 1)

        let legacy = Data(
            #"{"themeFamily":"Native Glass","palette":"Graphite"}"#.utf8
        )
        let settings = try JSONDecoder().decode(CoveSettings.self, from: legacy)
        precondition(!settings.minimalIslandMode)
        precondition(settings.collapsedWidth == 260)
        precondition(settings.textScale == 1)
        precondition(settings.squareTopCorners)
        precondition(settings.showUsage)
        precondition(!settings.showProfileTokenUsage)
        precondition(!settings.showTokenMetrics)
        precondition(settings.residentSet == .dungeonAndDragons)
    }

    static func testDesktopThreadHydrationParsing() throws {
        precondition(CoveDesktopThreadClient.isSafeThreadIdentifier("thread-ABC_123"))
        precondition(!CoveDesktopThreadClient.isSafeThreadIdentifier("../thread"))
        let response = Data(
            """
            {
              "id": "cove-desktop-thread-read",
              "result": {
                "thread": {
                  "id": "thread-ABC_123",
                  "name": "Primary Codex task",
                  "app": "codexDesktop",
                  "cwd": "/fixture/project",
                  "model": "gpt-5.4",
                  "updatedAt": 40,
                  "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnInput"]
                  },
                  "parentThreadId": "parent-thread"
                }
              }
            }
            """.utf8
        )
        let snapshot = try CoveDesktopThreadSnapshotParser.parseResponse(
            response,
            expectedID: "cove-desktop-thread-read",
            expectedThreadID: "thread-ABC_123",
            capturedAt: Date(timeIntervalSince1970: 42)
        )
        precondition(snapshot.snapshotId == "thread-ABC_123")
        precondition(snapshot.sessionId == "thread-ABC_123")
        precondition(snapshot.source == .codexDesktop)
        precondition(snapshot.status == .waitingInput)
        precondition(snapshot.priority == 95)
        precondition(snapshot.title == "Primary Codex task")
        precondition(snapshot.parentSessionId == "parent-thread")
        precondition(snapshot.detail == "/fixture/project · gpt-5.4")
        precondition(snapshot.timestamp == Date(timeIntervalSince1970: 40))
        precondition(snapshot.unread)

        let turnsResponse = Data(
            """
            {
              "id": "cove-desktop-thread-turns-thread-ABC_123",
              "result": {
                "data": [
                  {
                    "id": "newest-turn",
                    "status": "inProgress",
                    "items": [
                      {"type": "userMessage", "content": [{"type": "text", "text": "Next"}]}
                    ]
                  },
                  {
                    "id": "previous-turn",
                    "status": "completed",
                    "items": [
                      {"type": "userMessage", "content": [{"type": "text", "text": "Request"}]},
                      {"type": "agentMessage", "text": "Latest assistant output", "phase": "finalAnswer"}
                    ]
                  }
                ]
              }
            }
            """.utf8
        )
        let latestOutput = try CoveDesktopThreadSnapshotParser.latestOutput(
            fromThreadTurnsListResponse: turnsResponse,
            expectedID: "cove-desktop-thread-turns-thread-ABC_123"
        )
        precondition(latestOutput == "Latest assistant output")
        let turnSummary = try CoveDesktopThreadSnapshotParser.turnSummary(
            fromThreadTurnsListResponse: turnsResponse,
            expectedID: "cove-desktop-thread-turns-thread-ABC_123"
        )
        precondition(turnSummary.activeTurnID == "newest-turn")
        precondition(turnSummary.latestOutput == "Latest assistant output")

        let guardianResponse = Data(
            """
            {
              "id": "cove-desktop-thread-read-guardian",
              "result": {
                "thread": {
                  "id": "guardian-thread",
                  "name": "Internal approval review",
                  "model": "codex-auto-review",
                  "status": {"type": "active"},
                  "sourceKind": "codexDesktop",
                  "source": {
                    "subAgent": {
                      "other": "guardian"
                    }
                  }
                }
              }
            }
            """.utf8
        )
        do {
            _ = try CoveDesktopThreadSnapshotParser.parseResponse(
                guardianResponse,
                expectedID: "cove-desktop-thread-read-guardian",
                expectedThreadID: "guardian-thread",
                capturedAt: Date(timeIntervalSince1970: 42)
            )
            fatalError("Guardian approval threads must not hydrate into Cove")
        } catch let failure as CoveDesktopThreadHydrationFailure {
            precondition(failure == .hiddenApprovalReviewThread)
        }

        let ordinaryReviewerResponse = Data(
            """
            {
              "id": "cove-desktop-thread-read-reviewer",
              "result": {
                "thread": {
                  "id": "ordinary-reviewer",
                  "name": "Code review subagent",
                  "model": "gpt-5.6",
                  "status": {"type": "active"},
                  "sourceKind": "codexDesktop",
                  "source": {
                    "subAgent": {
                      "thread_spawn": {
                        "agent_role": "reviewer"
                      }
                    }
                  }
                }
              }
            }
            """.utf8
        )
        let ordinaryReviewer = try CoveDesktopThreadSnapshotParser.parseResponse(
            ordinaryReviewerResponse,
            expectedID: "cove-desktop-thread-read-reviewer",
            expectedThreadID: "ordinary-reviewer",
            capturedAt: Date(timeIntervalSince1970: 42)
        )
        precondition(ordinaryReviewer.snapshotId == "ordinary-reviewer")
        precondition(ordinaryReviewer.status == .working)
        precondition(ordinaryReviewer.source == .codexDesktop)

        let customOtherResponse = Data(
            """
            {
              "id": "cove-desktop-thread-read-custom",
              "result": {
                "thread": {
                  "id": "custom-subagent",
                  "name": "Custom internal helper",
                  "status": {"type": "active"},
                  "sourceKind": "codexDesktop",
                  "source": {
                    "subAgent": {
                      "other": "guardian-helper"
                    }
                  }
                }
              }
            }
            """.utf8
        )
        let customOther = try CoveDesktopThreadSnapshotParser.parseResponse(
            customOtherResponse,
            expectedID: "cove-desktop-thread-read-custom",
            expectedThreadID: "custom-subagent",
            capturedAt: Date(timeIntervalSince1970: 42)
        )
        precondition(customOther.snapshotId == "custom-subagent")
        precondition(customOther.status == .working)

        let listResponse = Data(
            """
            {
              "id": "cove-desktop-thread-list",
              "result": {
                "data": [
                  {
                    "id": "desktop-active",
                    "sourceKind": "codexDesktop",
                    "status": {"type": "running"}
                  },
                  {
                    "id": "desktop-completed",
                    "sourceKind": "codexDesktop",
                    "status": {"type": "completed"}
                  },
                  {
                    "id": "local-active",
                    "sourceKind": "localCli",
                    "status": {"type": "running"}
                  },
                  {
                    "id": "../unsafe",
                    "sourceKind": "codexDesktop",
                    "status": {"type": "running"}
                  },
                  {
                    "id": "desktop-waiting",
                    "source": {"kind": "desktop"},
                    "status": {"activeFlags": ["waitingOnApproval"]}
                  },
                  {
                    "id": "vscode-active",
                    "sourceKinds": ["vscode"],
                    "status": {"type": "running"}
                  },
                  {
                    "id": "vscode-not-loaded",
                    "sourceKinds": ["vscode"],
                    "statusKinds": ["notLoaded"]
                  },
                  {
                    "id": "guardian-hidden",
                    "model": "codex-auto-review",
                    "source": {"subAgent": {"other": "guardian"}},
                    "status": {"type": "running"}
                  }
                ]
              }
            }
            """.utf8
        )
        let activeDesktopIDs = try CoveDesktopThreadSnapshotParser
            .discoverableDesktopThreadIDs(
                fromThreadListResponse: listResponse,
                expectedID: "cove-desktop-thread-list",
                limit: 3
            )
        precondition(activeDesktopIDs == [
            "desktop-active",
            "desktop-waiting",
            "vscode-not-loaded",
        ])
        let listSelection = try CoveDesktopThreadSnapshotParser
            .threadListSelection(
                fromThreadListResponse: listResponse,
                expectedID: "cove-desktop-thread-list",
                limit: 3
            )
        precondition(
            listSelection.hiddenApprovalReviewThreadIDs
                == ["guardian-hidden"]
        )

        let notLoadedResponse = Data(
            """
            {
              "id": "cove-desktop-thread-read-vscode-not-loaded",
              "result": {
                "thread": {
                  "id": "vscode-not-loaded",
                  "name": "Current Desktop task",
                  "sourceKinds": ["vscode"],
                  "statusKinds": ["notLoaded"]
                }
              }
            }
            """.utf8
        )
        let notLoaded = try CoveDesktopThreadSnapshotParser.parseResponse(
            notLoadedResponse,
            expectedID: "cove-desktop-thread-read-vscode-not-loaded",
            expectedThreadID: "vscode-not-loaded",
            capturedAt: Date(timeIntervalSince1970: 43)
        )
        precondition(notLoaded.source == .codexDesktop)
        precondition(notLoaded.status == .idle)
        precondition(notLoaded.priority == 5)
        precondition(!notLoaded.unread)
        precondition(
            CoveSessionVisualCuePolicy.visibleSnapshots(in: [notLoaded])
                .isEmpty
        )

        do {
            _ = try CoveDesktopThreadSnapshotParser.parseResponse(
                Data(#"{"id":"cove-desktop-thread-read","error":{"message":"missing"}}"#.utf8),
                expectedID: "cove-desktop-thread-read",
                expectedThreadID: "thread-ABC_123",
                capturedAt: Date()
            )
            fatalError("Expected app-server thread/read error to remain unavailable")
        } catch let failure as CoveDesktopThreadHydrationFailure {
            precondition(failure == .threadUnavailable)
        }
    }

    static func testDesktopThreadSourceValidation() throws {
        func response(
            id: String,
            sourceFragment: String,
            statusFragment: String = #""status":{"type":"active"}"#
        ) -> Data {
            Data(
                """
                {
                  "id": "read-\(id)",
                  "result": {
                    "thread": {
                      "id": "\(id)",
                      "name": "Fixture",
                      \(sourceFragment)
                      \(statusFragment)
                    }
                  }
                }
                """.utf8
            )
        }

        let desktop = try CoveDesktopThreadSnapshotParser.parseResponse(
            response(
                id: "desktop-source",
                sourceFragment: #""sourceKind":"codexDesktop","#
            ),
            expectedID: "read-desktop-source",
            expectedThreadID: "desktop-source",
            capturedAt: Date(timeIntervalSince1970: 50)
        )
        precondition(desktop.source == .codexDesktop)

        let rejected: [(String, String, String)] = [
            (
                "local-source",
                #""sourceKind":"localCli","#,
                #""status":{"type":"active"}"#
            ),
            (
                "remote-source",
                #""sourceKind":"remoteCli","#,
                #""status":{"type":"active"}"#
            ),
            (
                "unknown-source",
                "",
                #""status":{"type":"active"}"#
            ),
            (
                "active-vscode",
                #""sourceKinds":["vscode"],"#,
                #""status":{"type":"active"}"#
            ),
            (
                "conflicting-source",
                #""sourceKinds":["codexDesktop","localCli"],"#,
                #""status":{"type":"active"}"#
            ),
        ]
        for (id, source, status) in rejected {
            do {
                _ = try CoveDesktopThreadSnapshotParser.parseResponse(
                    response(
                        id: id,
                        sourceFragment: source,
                        statusFragment: status
                    ),
                    expectedID: "read-\(id)",
                    expectedThreadID: id,
                    capturedAt: Date(timeIntervalSince1970: 50)
                )
                fatalError("A non-Desktop thread/read source must be rejected: \(id)")
            } catch let failure as CoveDesktopThreadHydrationFailure {
                precondition(failure == .threadUnavailable)
            }
        }
    }

    static func testDesktopStartupSourceFiltering() throws {
        let now = Date(timeIntervalSince1970: 100)
        func metadata(
            _ sessionID: String,
            source: CoveWireSource
        ) -> CoveSessionMetadata {
            CoveSessionMetadata(
                sessionId: sessionID,
                source: source,
                status: .idle,
                updatedAt: now,
                startedAt: now
            )
        }

        let records = [
            metadata("desktop-restored", source: .codexDesktop),
            metadata("local-restored", source: .localCli),
            metadata("remote-restored", source: .remoteCli),
            metadata("../unsafe", source: .codexDesktop),
        ]
        precondition(
            CoveDesktopThreadSnapshotParser.startupDesktopThreadIDs(
                from: records
            ) == ["desktop-restored"]
        )

        let hydration = CoveSessionSnapshot(
            snapshotId: "shared-session",
            status: .working,
            priority: 40,
            title: "Desktop",
            timestamp: now,
            sessionId: "shared-session",
            source: .codexDesktop
        )
        let restoredLocal = CoveSessionSnapshot(
            snapshotId: "shared-session",
            status: .idle,
            priority: 5,
            title: "CLI",
            timestamp: now,
            sessionId: "shared-session",
            source: .localCli
        )
        precondition(
            CoveDesktopThreadSnapshotParser.canApplyDesktopSnapshot(
                hydration,
                excluding: [],
                currentSnapshots: [restoredLocal]
            )
        )
        precondition(
            CoveDesktopThreadSnapshotParser.canApplyDesktopSnapshot(
                hydration,
                excluding: ["shared-session"],
                currentSnapshots: []
            )
        )
        precondition(
            CoveDesktopThreadSnapshotParser.canApplyDesktopSnapshot(
                hydration,
                excluding: [],
                currentSnapshots: []
            )
        )
    }

    static func testDesktopThreadHydrationSkipsHangingProxy() async throws {
        let fixture = try FakeCodexFixture(
            body: #"""
            [ "$1" = "app-server" ] || exit 41
            [ "$CODEX_COVE_BYPASS" = "1" ] || exit 42
            [ "$RUST_LOG" = "off" ] || exit 43
            if [ "$2" = "proxy" ]; then
              sleep 5
              exit 0
            fi
            [ "$2" = "--stdio" ] || exit 44
            while IFS= read -r request; do
              case "$request" in
                *'"id":"cove-desktop-initialize"'*)
                  case "$request" in
                    *'"experimentalApi":true'*) ;;
                    *) exit 47 ;;
                  esac
                  printf '%s\n' '{"id":"cove-desktop-initialize","result":{"platformFamily":"unix"}}'
                  ;;
                *'"method":"initialized"'*)
                  ;;
                *'"id":"cove-desktop-thread-loaded-0"'*)
                  printf '%s\n' '{"id":"cove-desktop-thread-loaded-0","result":{"data":["vscode-not-loaded"]}}'
                  ;;
                *'"id":"cove-desktop-thread-read-vscode-not-loaded"'*)
                  case "$request" in
                    *'"includeTurns":false'*) ;;
                    *) exit 45 ;;
                  esac
                  printf '%s\n' '{"id":"cove-desktop-thread-read-vscode-not-loaded","result":{"thread":{"id":"vscode-not-loaded","name":"Desktop from direct stdio","sourceKinds":["vscode"],"statusKinds":["notLoaded"]}}}'
                  ;;
                *'"id":"cove-desktop-thread-turns-vscode-not-loaded"'*)
                  case "$request" in
                    *'"itemsView":"summary"'*'"limit":8'*'"sortDirection":"desc"'*) ;;
                    *) exit 46 ;;
                  esac
                  printf '%s\n' '{"id":"cove-desktop-thread-turns-vscode-not-loaded","error":{"code":-32601,"message":"unsupported"}}'
                  ;;
              esac
            done
            """#
        )
        defer { fixture.close() }

        let client = CoveDesktopThreadClient(
            configuration: .init(
                realCodexURL: fixture.executableURL,
                requestTimeout: 2,
                maximumLineBytes: 16_384
            )
        )
        let startedAt = Date()
        let result = await client.reconcileLoadedDesktopThreads(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        guard case let .available(batch) = result else {
            fatalError("Expected Desktop snapshots after direct stdio fallback, got \(result)")
        }
        precondition(
            elapsed < 3,
            "Proxy probe must not consume the full Desktop discovery timeout"
        )
        precondition(batch.hiddenApprovalReviewThreadIDs.isEmpty)
        precondition(batch.snapshots.count == 1)
        precondition(batch.snapshots[0].snapshotId == "vscode-not-loaded")
        precondition(batch.snapshots[0].source == .codexDesktop)
        precondition(batch.snapshots[0].status == .idle)
    }

    static func testDesktopThreadHydrationCorrelatesOutOfOrderReads() async throws {
        let fixture = try FakeCodexFixture(
            body: #"""
            [ "$1" = "app-server" ] || exit 51
            [ "$CODEX_COVE_BYPASS" = "1" ] || exit 52
            [ "$RUST_LOG" = "off" ] || exit 53
            if [ "$2" = "proxy" ]; then
              exit 54
            fi
            [ "$2" = "--stdio" ] || exit 55
            saw_a=0
            saw_b=0
            saw_c=0
            while IFS= read -r request; do
              case "$request" in
                *'"id":"cove-desktop-initialize"'*)
                  printf '%s\n' '{"id":"cove-desktop-initialize","result":{"platformFamily":"unix"}}'
                  ;;
                *'"method":"initialized"'*)
                  ;;
                *'"id":"cove-desktop-thread-loaded-0"'*)
                  printf '%s\n' '{"id":"cove-desktop-thread-loaded-0","result":{"data":["desktop-a","desktop-b","desktop-c"]}}'
                  ;;
                *'"id":"cove-desktop-thread-read-desktop-a"'*)
                  saw_a=1
                  ;;
                *'"id":"cove-desktop-thread-read-desktop-b"'*)
                  saw_b=1
                  ;;
                *'"id":"cove-desktop-thread-read-desktop-c"'*)
                  saw_c=1
                  ;;
              esac
              if [ "$saw_a" = "1" ] && [ "$saw_b" = "1" ] && [ "$saw_c" = "1" ]; then
                printf '%s\n' '{"id":"cove-desktop-thread-read-desktop-b","result":{"thread":{"id":"desktop-b","name":"Desktop B","sourceKind":"codexDesktop","status":{"type":"running"}}}}'
                printf '%s\n' '{"id":"cove-desktop-thread-read-desktop-a","result":{"thread":{"id":"desktop-a","name":"Desktop A","sourceKind":"codexDesktop","status":{"type":"running"}}}}'
                printf '%s\n' '{"id":"cove-desktop-thread-read-desktop-c","result":{"thread":{"id":"desktop-c","name":"Desktop C","sourceKind":"codexDesktop","status":{"type":"running"}}}}'
                exit 0
              fi
            done
            """#
        )
        defer { fixture.close() }

        let client = CoveDesktopThreadClient(
            configuration: .init(
                realCodexURL: fixture.executableURL,
                requestTimeout: 2,
                maximumLineBytes: 16_384
            )
        )
        let result = await client.reconcileLoadedDesktopThreads(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        guard case let .available(batch) = result else {
            fatalError("Expected out-of-order Desktop snapshots, got \(result)")
        }
        precondition(batch.hiddenApprovalReviewThreadIDs.isEmpty)
        precondition(batch.snapshots.map(\.snapshotId) == [
            "desktop-a",
            "desktop-b",
            "desktop-c",
        ])
        precondition(batch.snapshots.allSatisfy { $0.source == .codexDesktop })
        precondition(batch.snapshots.allSatisfy { $0.status == .working })
    }

    static func testRecoverableSessionArchive() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let archived = CoveSessionSnapshot(
            snapshotId: "archive-me",
            status: .failed,
            priority: 90,
            title: "Archived",
            timestamp: timestamp,
            sessionId: "archive-me",
            source: .localCli
        )
        let active = CoveSessionSnapshot(
            snapshotId: "keep-me",
            status: .working,
            priority: 40,
            title: "Active",
            timestamp: timestamp,
            sessionId: "keep-me",
            source: .localCli
        )
        var state = CoveState()
        CoveReducer.reduce(&state, .receivedSnapshot(archived))
        CoveReducer.reduce(&state, .receivedSnapshot(active))
        CoveReducer.reduce(&state, .dismissSnapshot(archived.sessionIdentity!))
        precondition(state.dismissedSessionIDs == [archived.sessionIdentity!.id])
        precondition(!state.session.snapshots.contains { $0.snapshotId == "archive-me" })
        precondition(state.session.activeSnapshot?.snapshotId == "keep-me")

        var newerArchived = archived
        newerArchived.timestamp = timestamp.addingTimeInterval(10)
        CoveReducer.reduce(&state, .receivedSnapshot(newerArchived))
        precondition(!state.session.snapshots.contains { $0.snapshotId == "archive-me" })

        CoveReducer.reduce(
            &state,
            .restoreDismissedSession(archived.sessionIdentity!.id)
        )
        CoveReducer.reduce(&state, .receivedSnapshot(newerArchived))
        precondition(state.dismissedSessionIDs.isEmpty)
        precondition(state.session.snapshots.contains { $0.snapshotId == "archive-me" })
    }

    static func testOfficialPerSessionTokenMetrics() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let envelope = CoveWireEnvelope(
            eventId: "token-update",
            kind: .appServer,
            timestamp: capturedAt,
            source: .localCli,
            sessionId: "token-session",
            payload: .object([
                "message": .object([
                    "method": .string("thread/tokenUsage/updated"),
                    "params": .object([
                        "tokenUsage": .object([
                            "total": .object([
                                "inputTokens": .number(120),
                                "outputTokens": .number(30),
                                "totalTokens": .number(150)
                            ]),
                            "modelContextWindow": .number(200_000)
                        ])
                    ])
                ])
            ])
        )
        var state = CoveState(settings: .init(autoExpandOnEvent: false))
        CoveReducer.reduce(&state, .receivedEnvelope(envelope))
        let metrics = state.sessionTokenMetrics[envelope.scopedSessionKey]
        precondition(metrics?.inputTokens == 120)
        precondition(metrics?.outputTokens == 30)
        precondition(metrics?.totalTokens == 150)
        precondition(metrics?.cachedInputTokens == nil)
        precondition(metrics?.contextWindow == 200_000)
        precondition(
            metrics?.isStale(
                at: capturedAt.addingTimeInterval(5 * 60)
            ) == false
        )
        precondition(
            metrics?.isStale(
                at: capturedAt.addingTimeInterval(5 * 60 + 0.001)
            ) == true
        )
    }

    static func testRateLimitsResponseParsing() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = Data(
            #"""
            {
              "id": "usage-test",
              "result": {
                "rateLimits": {
                  "primary": {
                    "usedPercent": 25,
                    "windowDurationMins": 300,
                    "resetsAt": 1800000300
                  },
                  "secondary": {
                    "usedPercent": 42,
                    "windowDurationMins": 10080,
                    "resetsAt": 1800000600
                  },
                  "credits": { "balance": 12.5 }
                },
                "rateLimitResetCredits": {
                  "availableCount": 2,
                  "credits": [{
                    "id": "opaque-reset-id",
                    "resetType": "codexRateLimits",
                    "status": "available",
                    "grantedAt": 1799999000,
                    "expiresAt": 1800000900,
                    "title": "Rate-limit reset",
                    "description": "Reset an eligible Codex rate-limit window."
                  }]
                }
              }
            }
            """#.utf8
        )
        let snapshot = try CoveRateLimitsSnapshotParser.parseResponse(
            response,
            expectedID: "usage-test",
            capturedAt: capturedAt
        )
        precondition(snapshot.primary?.usedPercent == 25)
        precondition(snapshot.primary?.remainingPercent == 75)
        precondition(snapshot.primary?.windowDurationMinutes == 300)
        precondition(snapshot.secondary?.usedPercent == 42)
        precondition(snapshot.resetCreditsAvailable == 2)
        precondition(snapshot.resetCredits?.count == 1)
        precondition(snapshot.resetCredits?.first?.id == "opaque-reset-id")
        precondition(snapshot.resetCredits?.first?.status == "available")
        precondition(
            snapshot.resetCredits?.first?.expiresAt
                == Date(timeIntervalSince1970: 1_800_000_900)
        )
        precondition(snapshot.creditBalance == "12.5")
        precondition(snapshot.capturedAt == capturedAt)
        precondition(!snapshot.isPartial)
        precondition(!snapshot.isStale(at: capturedAt.addingTimeInterval(299)))
        precondition(snapshot.isStale(at: capturedAt.addingTimeInterval(301)))
    }

    static func testRateLimitsMissingInventoryIsPartial() throws {
        let response = Data(
            #"""
            {
              "id": "usage-partial",
              "result": {
                "rateLimits": {
                  "primary": {
                    "usedPercent": 4,
                    "windowDurationMins": 300,
                    "resetsAt": 1800000300
                  },
                  "secondary": null
                },
                "rateLimitResetCredits": { "availableCount": 1 }
              }
            }
            """#.utf8
        )
        let snapshot = try CoveRateLimitsSnapshotParser.parseResponse(
            response,
            expectedID: "usage-partial",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        precondition(snapshot.primary?.usedPercent == 4)
        precondition(snapshot.secondary == nil)
        precondition(snapshot.resetCreditsAvailable == 1)
        precondition(snapshot.resetCredits == nil)
        precondition(snapshot.isPartial)
    }

    static func testAccountTokenUsageParsing() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = Data(
            #"""
            {
              "id": "profile-usage-test",
              "result": {
                "summary": {
                  "lifetimeTokens": 9007199254740993,
                  "peakDailyTokens": 42000,
                  "longestRunningTurnSec": 3723,
                  "currentStreakDays": 4,
                  "longestStreakDays": 12
                },
                "dailyUsageBuckets": [
                  {"startDate": "2026-07-30", "tokens": 1200},
                  {"startDate": "2026-07-31", "tokens": 3400}
                ],
                "futureField": true
              }
            }
            """#.utf8
        )
        let snapshot = try CoveAccountTokenUsageSnapshotParser.parseResponse(
            response,
            expectedID: "profile-usage-test",
            capturedAt: capturedAt
        )
        precondition(snapshot.summary.lifetimeTokens == 9_007_199_254_740_993)
        precondition(snapshot.summary.peakDailyTokens == 42_000)
        precondition(snapshot.summary.longestRunningTurnSeconds == 3_723)
        precondition(snapshot.summary.currentStreakDays == 4)
        precondition(snapshot.summary.longestStreakDays == 12)
        precondition(snapshot.dailyUsageBuckets?.count == 2)
        precondition(snapshot.dailyUsageBuckets?.last?.tokens == 3_400)
        precondition(snapshot.capturedAt == capturedAt)
        precondition(snapshot.hasData)
        precondition(!snapshot.isStale(at: capturedAt.addingTimeInterval(300)))
        precondition(snapshot.isStale(at: capturedAt.addingTimeInterval(301)))

        let nullable = Data(
            #"{"id":"profile-null","result":{"summary":{"lifetimeTokens":7},"dailyUsageBuckets":null}}"#.utf8
        )
        let nullableSnapshot = try CoveAccountTokenUsageSnapshotParser.parseResponse(
            nullable,
            expectedID: "profile-null",
            capturedAt: capturedAt
        )
        precondition(nullableSnapshot.summary.lifetimeTokens == 7)
        precondition(nullableSnapshot.summary.peakDailyTokens == nil)
        precondition(nullableSnapshot.dailyUsageBuckets == nil)
        precondition(
            nullableSnapshot.trendPoints(.daily, through: capturedAt) == nil
        )
    }

    static func testAccountTokenUsageTrends() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let referenceDate = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 12)
        )!
        let profile = CoveAccountTokenUsageSnapshot(
            summary: .init(),
            dailyUsageBuckets: [
                .init(startDate: "2026-07-19", tokens: 7),
                .init(startDate: "2026-07-26", tokens: 10),
                .init(startDate: "2026-07-26", tokens: 5),
                .init(startDate: "2026-07-31", tokens: 20),
                .init(startDate: "2026-08-01", tokens: 999),
                .init(startDate: "not-a-date", tokens: 500),
            ],
            capturedAt: referenceDate
        )
        let daily = profile.trendPoints(
            .daily,
            through: referenceDate,
            calendar: calendar
        )!
        precondition(daily.count == 364)
        precondition(daily[357].tokens == 15)
        precondition(daily[362].tokens == 20)
        precondition(daily[363].tokens == 0)
        precondition(daily[363].isFuture)

        let weekly = profile.trendPoints(
            .weekly,
            through: referenceDate,
            calendar: calendar
        )!
        precondition(weekly.count == 52)
        precondition(weekly[50].tokens == 7)
        precondition(weekly[51].tokens == 35)

        let cumulative = profile.trendPoints(
            .cumulative,
            through: referenceDate,
            calendar: calendar
        )!
        precondition(cumulative.count == 52)
        precondition(cumulative[50].tokens == 7)
        precondition(cumulative[51].tokens == 42)

        var nonGregorianCalendar = Calendar(identifier: .buddhist)
        nonGregorianCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let calendarIndependentDaily = profile.trendPoints(
            .daily,
            through: referenceDate,
            calendar: nonGregorianCalendar
        )!
        precondition(calendarIndependentDaily == daily)

        let olderProfile = CoveUsageSnapshot(
            accountTokenUsage: profile,
            accountTokenUsageAvailability: .available,
            capturedAt: referenceDate,
            isPartial: false
        )
        let failedRefresh = CoveUsageSnapshot(
            primary: .init(
                usedPercent: 12,
                resetsAt: nil,
                windowDurationMinutes: 300
            ),
            accountTokenUsageAvailability: .unavailable,
            capturedAt: referenceDate.addingTimeInterval(60),
            isPartial: true
        )
        let merged = olderProfile.merging(failedRefresh)
        precondition(merged.accountTokenUsage == profile)
        precondition(merged.accountTokenUsageAvailability == .unavailable)
        precondition(merged.primary?.usedPercent == 12)
    }

    static func testFailedProfileRefreshPreservesLastGoodProfile() {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = CoveAccountTokenUsageSnapshot(
            summary: .init(lifetimeTokens: 84_000_000_000),
            dailyUsageBuckets: [
                .init(startDate: "2026-07-31", tokens: 1_500),
            ],
            capturedAt: capturedAt
        )
        var state = CoveState(
            usage: CoveUsageSnapshot(
                primary: .init(
                    usedPercent: 20,
                    resetsAt: nil,
                    windowDurationMinutes: 300
                ),
                secondary: .init(
                    usedPercent: 30,
                    resetsAt: nil,
                    windowDurationMinutes: 10_080
                ),
                accountTokenUsage: profile,
                accountTokenUsageAvailability: .available,
                capturedAt: capturedAt,
                isPartial: false
            )
        )
        let failedProfileRefresh = CoveUsageSnapshot(
            primary: .init(
                usedPercent: 12,
                resetsAt: nil,
                windowDurationMinutes: 300
            ),
            accountTokenUsageAvailability: .unavailable,
            capturedAt: capturedAt.addingTimeInterval(60),
            isPartial: true
        )

        CoveReducer.reduce(&state, .receivedUsage(failedProfileRefresh))

        precondition(state.usage?.primary?.usedPercent == 12)
        precondition(state.usage?.secondary == nil)
        precondition(state.usage?.accountTokenUsage == profile)
        precondition(state.usage?.accountTokenUsageAvailability == .unavailable)
        precondition(state.usage?.capturedAt == failedProfileRefresh.capturedAt)
    }

    static func testAccountUsageProcessFixture() async throws {
        let fixture = try FakeCodexFixture(
            body: #"""
            [ "$1" = "app-server" ] || exit 21
            [ "$2" = "--stdio" ] || exit 22
            [ "$CODEX_COVE_BYPASS" = "1" ] || exit 23
            [ "$RUST_LOG" = "off" ] || exit 24
            IFS= read -r initialize || exit 25
            case "$initialize" in
              *'"method":"initialize"'*) ;;
              *) exit 26 ;;
            esac
            printf '%s\n' '{"id":"cove-usage-initialize","result":{"platformFamily":"unix"}}'
            IFS= read -r initialized || exit 27
            case "$initialized" in
              *'"method":"initialized"'*) ;;
              *) exit 28 ;;
            esac
            IFS= read -r usage || exit 29
            case "$usage" in
              *'"method":"account'*'rateLimits'*'read"'*'"params":null'*) ;;
              *) exit 30 ;;
            esac
            printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":99}}}}'
            printf '%s\n' '{"id":"cove-usage-rate-limits","result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000300},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1800000600}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"fixture-credit","status":"available","expiresAt":1800000900,"title":"Fixture reset"}]}}}'
            IFS= read -r profile_usage || exit 31
            case "$profile_usage" in
              *'"method":"account'*'usage'*'read"'*) ;;
              *) exit 32 ;;
            esac
            printf '%s\n' '{"id":"cove-usage-account-token","result":{"summary":{"lifetimeTokens":123456,"peakDailyTokens":4567,"longestRunningTurnSec":89,"currentStreakDays":3,"longestStreakDays":8},"dailyUsageBuckets":[{"startDate":"2026-07-31","tokens":900}]}}'
            """#
        )
        defer { fixture.close() }

        let client = CoveAccountUsageClient(
            configuration: .init(
                realCodexURL: fixture.executableURL,
                requestTimeout: 2,
                maximumLineBytes: 16_384
            )
        )
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let result = await client.fetch(capturedAt: capturedAt)
        guard case let .available(snapshot) = result else {
            fatalError("Expected usage snapshot from process fixture, got \(result)")
        }
        precondition(snapshot.primary?.usedPercent == 12)
        precondition(snapshot.secondary?.usedPercent == 34)
        precondition(snapshot.resetCreditsAvailable == 1)
        precondition(snapshot.resetCredits?.first?.id == "fixture-credit")
        precondition(snapshot.accountTokenUsageAvailability == .available)
        precondition(snapshot.accountTokenUsage?.summary.lifetimeTokens == 123_456)
        precondition(snapshot.accountTokenUsage?.dailyUsageBuckets?.first?.tokens == 900)
        precondition(snapshot.capturedAt == capturedAt)
    }

    static func testAccountUsageRejectsOversizedLine() async throws {
        let fixture = try FakeCodexFixture(
            body: #"""
            IFS= read -r initialize || exit 31
            i=0
            while [ "$i" -lt 1500 ]; do
              printf x
              i=$((i + 1))
            done
            printf '\n'
            """#
        )
        defer { fixture.close() }

        let client = CoveAccountUsageClient(
            configuration: .init(
                realCodexURL: fixture.executableURL,
                requestTimeout: 2,
                maximumLineBytes: 1024
            )
        )
        let result = await client.fetch()
        precondition(result == .unavailable(.responseTooLarge))
    }

    static func testReducerSnapshotPriority() throws {
        var state = CoveState(
            settings: .init(themeFamily: .nativeGlass, palette: .graphite, autoExpandOnEvent: true),
            theme: CoveThemeCatalog.palette(for: .nativeGlass, palette: .graphite)
        )
        let snapshot = CoveSessionSnapshot(
            snapshotId: "snap-1",
            status: .blocked,
            priority: 10,
            title: "Blocked",
            detail: "Need approval",
            timestamp: Date()
        )
        CoveReducer.reduce(&state, .receivedSnapshot(snapshot))
        precondition(state.session.activeStatus == .blocked)
        precondition(state.session.statusPriority == 10)
        precondition(state.session.activeSnapshot?.snapshotId == "snap-1")
        precondition(!state.session.isExpanded)
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                .init(
                    eventId: "no-auto-expand-request",
                    kind: .approvalRequested,
                    timestamp: Date(),
                    source: .localCli,
                    sessionId: "request-session",
                    launchId: "request-launch",
                    payload: .object([
                        "method": .string(
                            "item/commandExecution/requestApproval"
                        ),
                        "requestId": .string("request-id"),
                        "availableDecisions": .array([
                            .string("accept"),
                            .string("decline")
                        ])
                    ])
                )
            )
        )
        precondition(!state.pendingDirectRequests.isEmpty)
        precondition(!state.session.isExpanded)
    }

    static func testLatestAssistantOutputProjection() {
        func hook(
            _ name: String,
            id: String,
            timestamp: TimeInterval,
            lastOutput: String? = nil
        ) -> CoveWireEnvelope {
            var data: [String: CoveJSONValue] = [
                "hook_event_name": .string(name),
                "session_id": .string("output-session"),
            ]
            if let lastOutput {
                data["last_assistant_message"] = .string(lastOutput)
            }
            return CoveWireEnvelope(
                eventId: id,
                kind: .hook,
                timestamp: Date(timeIntervalSince1970: timestamp),
                source: .localCli,
                sessionId: "output-session",
                payload: .object([
                    "hookEventName": .string(name),
                    "data": .object(data),
                ])
            )
        }

        var state = CoveState()
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                hook(
                    "Stop",
                    id: "output-stop",
                    timestamp: 10,
                    lastOutput: "  Finished the requested work.  "
                )
            )
        )
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                hook("PostToolUse", id: "output-post-tool", timestamp: 11)
            )
        )
        let snapshot = state.session.snapshots.first {
            $0.sessionId == "output-session"
        }
        precondition(snapshot?.latestOutput == "Finished the requested work.")
        precondition(snapshot?.title == "Codex task")
    }

    static func testSnapshotOriginCollisionFailsClosed() throws {
        func snapshot(
            source: CoveWireSource,
            hostID: String? = nil,
            timestamp: TimeInterval,
            status: CoveSessionStatus = .working,
            snapshotID: String = "shared-snapshot"
        ) -> CoveSessionSnapshot {
            CoveSessionSnapshot(
                snapshotId: snapshotID,
                status: status,
                priority: 40,
                title: "Fixture",
                timestamp: Date(timeIntervalSince1970: timestamp),
                sessionId: "shared-session",
                launchId: "shared-launch",
                source: source,
                hostId: hostID
            )
        }

        var state = CoveState()
        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                snapshot(source: .localCli, timestamp: 1)
            )
        )
        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                snapshot(
                    source: .codexDesktop,
                    timestamp: 2,
                    status: .waitingInput,
                    snapshotID: "desktop-distinct-snapshot"
                )
            )
        )
        precondition(state.session.snapshots.count == 2)
        precondition(Set(state.session.snapshots.compactMap(\.source)) == [
            .localCli, .codexDesktop,
        ])

        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                snapshot(
                    source: .localCli,
                    timestamp: 3,
                    status: .completed
                )
            )
        )
        precondition(state.session.snapshots.count == 2)
        precondition(state.session.snapshots.first {
            $0.source == .localCli
        }?.status == .completed)
        precondition(state.session.snapshots.first {
            $0.source == .codexDesktop
        }?.status == .waitingInput)

        var remoteState = CoveState()
        CoveReducer.reduce(
            &remoteState,
            .receivedSnapshot(
                snapshot(
                    source: .remoteCli,
                    hostID: "remote-a",
                    timestamp: 4,
                    snapshotID: "remote-a-distinct-snapshot"
                )
            )
        )
        CoveReducer.reduce(
            &remoteState,
            .receivedSnapshot(
                snapshot(
                    source: .remoteCli,
                    hostID: "remote-b",
                    timestamp: 5,
                    snapshotID: "remote-b-distinct-snapshot"
                )
            )
        )
        let remote = remoteState.session.snapshots
        precondition(remote.count == 2)
        precondition(Set(remote.compactMap(\.hostId)) == ["remote-a", "remote-b"])
        let projection = CoveQueueProjection(state: remoteState)
        precondition(projection.active.count == 2)
        precondition(Set(projection.active.compactMap { $0.snapshot?.hostId }) == [
            "remote-a", "remote-b",
        ])
    }

    static func testReducerReadDismissAndOutOfOrderSemantics() throws {
        var state = CoveState(settings: .init(autoExpandOnEvent: false))
        let start = Date(timeIntervalSince1970: 100)
        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                .init(
                    snapshotId: "running",
                    status: .working,
                    priority: 40,
                    title: "Running",
                    timestamp: start,
                    sessionId: "running",
                    source: .localCli
                )
            )
        )
        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                .init(
                    snapshotId: "completed",
                    status: .completed,
                    priority: 1,
                    title: "Completed",
                    timestamp: start.addingTimeInterval(1),
                    sessionId: "completed",
                    source: .localCli,
                    unread: true
                )
            )
        )
        precondition(state.session.activeSnapshot?.snapshotId == "completed")
        precondition(state.session.statusPriority == 80)

        let completedIdentity = state.session.snapshots.first {
            $0.snapshotId == "completed"
        }!.sessionIdentity!
        let runningIdentity = state.session.snapshots.first {
            $0.snapshotId == "running"
        }!.sessionIdentity!
        CoveReducer.reduce(&state, .markRead(completedIdentity))
        precondition(state.session.activeSnapshot?.snapshotId == "running")
        precondition(
            state.session.snapshots.first(where: {
                $0.snapshotId == "completed"
            })?.priority == 8
        )

        CoveReducer.reduce(
            &state,
            .receivedSnapshot(
                .init(
                    snapshotId: "running",
                    status: .failed,
                    priority: 90,
                    title: "Late stale failure",
                    timestamp: start.addingTimeInterval(-1),
                    sessionId: "running",
                    source: .localCli
                )
            )
        )
        precondition(state.session.activeSnapshot?.status == .working)

        CoveReducer.reduce(&state, .dismissSnapshot(runningIdentity))
        precondition(state.session.activeSnapshot?.snapshotId == "completed")
        precondition(state.session.activeStatus == .completed)
        precondition(state.session.statusPriority == 8)
        CoveReducer.reduce(&state, .dismissSnapshot(completedIdentity))
        precondition(state.session.activeSnapshot == nil)
        precondition(state.session.activeStatus == .idle)
        precondition(state.session.statusPriority == 0)

        CoveReducer.reduce(
            &state,
            .restoreMetadata([
                .init(
                    sessionId: "read-complete",
                    source: .localCli,
                    status: .completed,
                    unread: false,
                    updatedAt: start,
                    startedAt: start
                ),
                .init(
                    sessionId: "restored-running",
                    source: .localCli,
                    status: .working,
                    updatedAt: start,
                    startedAt: start
                ),
            ])
        )
        precondition(
            state.session.activeSnapshot?.snapshotId == "restored-running"
        )
    }

    static func testStaleStatusEnvelopeDoesNotRegressGlobalState() throws {
        var state = CoveState(settings: .init(autoExpandOnEvent: false))
        let fresh = CoveWireEnvelope(
            eventId: "fresh-status",
            kind: .sessionStatus,
            timestamp: Date(timeIntervalSince1970: 20),
            source: .localCli,
            sessionId: "status-session",
            launchId: "status-launch",
            payload: .object([
                "status": .string("working"),
                "priority": .number(40),
                "title": .string("Fresh working status")
            ])
        )
        let stale = CoveWireEnvelope(
            eventId: "stale-status",
            kind: .sessionStatus,
            timestamp: Date(timeIntervalSince1970: 10),
            source: .localCli,
            sessionId: "status-session",
            launchId: "status-launch",
            payload: .object([
                "status": .string("failed"),
                "priority": .number(90),
                "title": .string("Stale failure")
            ])
        )

        CoveReducer.reduce(&state, .receivedEnvelope(fresh))
        CoveReducer.reduce(&state, .receivedEnvelope(stale))

        precondition(state.session.snapshots.count == 1)
        precondition(state.session.activeSnapshot?.status == .working)
        precondition(
            state.session.activeSnapshot?.timestamp
                == Date(timeIntervalSince1970: 20)
        )
        precondition(state.session.activeStatus == .working)
        precondition(state.session.statusPriority == 40)
        precondition(state.lastEvent?.title == "Fresh working status")
        precondition(state.recentEvents.map(\.title) == ["Fresh working status"])
        precondition(state.session.lastEnvelope?.eventId == "fresh-status")
    }

    static func testReducerQuestionMapping() throws {
        let envelope = CoveWireEnvelope(
            eventId: "evt-1",
            kind: .questionRequest,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .localCli,
            sessionId: "session-1",
            payload: .object([
                "method": .string("item/tool/requestUserInput"),
                "requestId": .string("req-9"),
                "question": .string("Continue?"),
                "options": .array([
                    .object(["id": .string("yes"), "label": .string("Yes")]),
                    .object(["id": .string("no"), "label": .string("No")])
                ]),
                "allowsFreeform": .bool(true),
                "decisionSocket": .string("/tmp/cove.sock")
            ])
        )
        guard case let .question(request)? = envelope.directRequest() else {
            fatalError("Expected question request")
        }
        precondition(request.requestId == .string("req-9"))
        precondition(request.questions.count == 1)
        precondition(request.options.count == 2)
        precondition(request.allowsFreeform)
    }

    static func testMultiQuestionMappingAndEncoding() throws {
        let envelope = CoveWireEnvelope(
            eventId: "evt-multi-question",
            kind: .questionRequested,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .localCli,
            sessionId: "session-multi",
            launchId: "launch-multi",
            payload: .object([
                "decisionSocket": .string("/tmp/cove-multi.sock"),
                "message": .object([
                    "id": .string("req-multi"),
                    "method": .string("item/tool/requestUserInput"),
                    "params": .object([
                        "questions": .array([
                            .object([
                                "id": .string("theme"),
                                "header": .string("Theme"),
                                "question": .string("Pick a style"),
                                "options": .array([
                                    .object([
                                        "label": .string("Native Glass"),
                                        "description": .string("Vibrant material")
                                    ]),
                                    .object([
                                        "label": .string("Minimal OLED"),
                                        "description": .string("Opaque black")
                                    ]),
                                    .object(["description": .string("Missing label")])
                                ]),
                                "isOther": .bool(false),
                                "allowsFreeform": .bool(true)
                            ]),
                            .object([
                                "id": .string("note"),
                                "header": .string("Note"),
                                "question": .string("Any context?"),
                                "options": .array([]),
                                "isOther": .bool(true),
                                "allowsFreeform": .bool(false)
                            ])
                        ])
                    ])
                ])
            ])
        )

        guard case let .question(request)? = envelope.directRequest() else {
            fatalError("Expected multi-question request")
        }
        precondition(request.requestId == .string("req-multi"))
        precondition(request.questions.map(\.questionId) == ["theme", "note"])
        precondition(request.questions.map(\.header) == ["Theme", "Note"])
        precondition(request.questions[0].question == "Pick a style")
        precondition(request.questions[0].options.map(\.label) == ["Native Glass", "Minimal OLED"])
        precondition(!request.questions[0].allowsFreeform)
        precondition(request.questions[1].allowsFreeform)

        let frame = CoveDecisionFrame(
            launchId: request.launchId,
            requestId: request.requestId,
            result: .question(
                answers: [
                    "theme": CoveQuestionAnswer(answers: ["Native Glass"]),
                    "note": CoveQuestionAnswer(answers: ["Keep animations subtle"])
                ]
            )
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(frame)
        ) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let answers = result?["answers"] as? [String: Any]
        precondition(Set(answers?.keys.map { $0 } ?? []) == Set(["theme", "note"]))
        precondition(
            (answers?["theme"] as? [String: Any])?["answers"] as? [String]
                == ["Native Glass"]
        )
        precondition(
            (answers?["note"] as? [String: Any])?["answers"] as? [String]
                == ["Keep animations subtle"]
        )
        precondition(Set(result?.keys.map { $0 } ?? []) == Set(["answers"]))
    }

    static func testRequestIDTypeAwareness() throws {
        let numericID = CoveRequestID.integer(42)
        let stringID = CoveRequestID.string("42")
        precondition(numericID != stringID)
        precondition(numericID.displayValue == stringID.displayValue)

        let numericFrame = CoveDecisionFrame(
            launchId: "launch-numeric",
            requestId: numericID,
            result: .approval(decision: .accept)
        )
        let encodedFrame = try JSONEncoder().encode(numericFrame)
        let encodedObject = try JSONSerialization.jsonObject(
            with: encodedFrame
        ) as? [String: Any]
        precondition(encodedObject?["requestId"] as? Int == 42)
        precondition(!(encodedObject?["requestId"] is String))
        let decodedFrame = try JSONDecoder().decode(
            CoveDecisionFrame.self,
            from: encodedFrame
        )
        precondition(decodedFrame.requestId == numericID)

        var state = CoveState(
            pendingDirectRequest: .question(
                .init(
                    schemaVersion: 1,
                    requestId: numericID,
                    launchId: "launch-numeric",
                    sessionId: "session-numeric",
                    question: "Continue?",
                    options: [],
                    allowsFreeform: true,
                    decisionSocket: "/tmp/cove-numeric.sock"
                )
            )
        )
        let stringResolution = CoveWireEnvelope(
            eventId: "resolved-string",
            kind: .serverRequestResolved,
            timestamp: Date(timeIntervalSince1970: 1),
            source: .localCli,
            sessionId: "session-numeric",
            launchId: "launch-numeric",
            payload: .object([
                "message": .object([
                    "method": .string("serverRequest/resolved"),
                    "params": .object(["requestId": .string("42")])
                ])
            ])
        )
        CoveReducer.reduce(&state, .receivedEnvelope(stringResolution))
        precondition(state.pendingDirectRequest != nil)

        let numericResolution = CoveWireEnvelope(
            eventId: "resolved-integer",
            kind: .serverRequestResolved,
            timestamp: Date(timeIntervalSince1970: 2),
            source: .localCli,
            sessionId: "session-numeric",
            launchId: "launch-numeric",
            payload: .object([
                "message": .object([
                    "method": .string("serverRequest/resolved"),
                    "params": .object(["requestId": .number(42)])
                ])
            ])
        )
        CoveReducer.reduce(&state, .receivedEnvelope(numericResolution))
        precondition(state.pendingDirectRequest == nil)
    }

    static func testConcurrentDirectRequestIsolation() throws {
        func requestEnvelope(
            eventId: String,
            requestId: CoveJSONValue,
            launchId: String,
            sessionId: String,
            title: String,
            timestamp: TimeInterval,
            turnId: String? = nil
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventId,
                kind: .approvalRequested,
                timestamp: Date(timeIntervalSince1970: timestamp),
                source: .localCli,
                sessionId: sessionId,
                turnId: turnId,
                launchId: launchId,
                payload: .object([
                    "method": .string(
                        "item/commandExecution/requestApproval"
                    ),
                    "requestId": requestId,
                    "title": .string(title),
                    "availableDecisions": .array([
                        .string("accept"),
                        .string("decline")
                    ]),
                    "decisionSocket": .string("/tmp/cove-\(eventId).sock")
                ])
            )
        }

        func resolutionEnvelope(
            eventId: String,
            requestId: CoveJSONValue,
            launchId: String,
            sessionId: String,
            timestamp: TimeInterval,
            turnId: String? = nil
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventId,
                kind: .serverRequestResolved,
                timestamp: Date(timeIntervalSince1970: timestamp),
                source: .localCli,
                sessionId: sessionId,
                turnId: turnId,
                launchId: launchId,
                payload: .object([
                    "message": .object([
                        "method": .string("serverRequest/resolved"),
                        "params": .object(["requestId": requestId])
                    ])
                ])
            )
        }

        var state = CoveState(settings: .init(autoExpandOnEvent: false))
        let numericLaunchA = requestEnvelope(
            eventId: "numeric-launch-a",
            requestId: .number(7),
            launchId: "launch-a",
            sessionId: "session-a",
            title: "Numeric A",
            timestamp: 1
        )
        let numericLaunchB = requestEnvelope(
            eventId: "numeric-launch-b",
            requestId: .number(7),
            launchId: "launch-b",
            sessionId: "session-b",
            title: "Numeric B",
            timestamp: 2
        )
        let stringLaunchA = requestEnvelope(
            eventId: "string-launch-a",
            requestId: .string("7"),
            launchId: "launch-a",
            sessionId: "session-a",
            title: "String A",
            timestamp: 3
        )
        CoveReducer.reduce(&state, .receivedEnvelope(numericLaunchA))
        CoveReducer.reduce(&state, .receivedEnvelope(numericLaunchB))
        CoveReducer.reduce(&state, .receivedEnvelope(stringLaunchA))

        precondition(state.pendingDirectRequests.count == 3)
        precondition(
            Set(state.pendingDirectRequests.map(\.key)).count == 3
        )
        precondition(
            Set(state.pendingDirectRequests.map(\.requestId))
                == Set([.integer(7), .string("7")])
        )
        CoveReducer.reduce(&state, .clearRecentEvents)
        precondition(state.pendingDirectRequests.count == 3)

        let wrongScope = resolutionEnvelope(
            eventId: "wrong-scope-resolution",
            requestId: .number(7),
            launchId: "launch-b",
            sessionId: "session-a",
            timestamp: 4
        )
        CoveReducer.reduce(&state, .receivedEnvelope(wrongScope))
        precondition(state.pendingDirectRequests.count == 3)

        let numericAResolution = resolutionEnvelope(
            eventId: "numeric-a-resolution",
            requestId: .number(7),
            launchId: "launch-a",
            sessionId: "session-a",
            timestamp: 5
        )
        CoveReducer.reduce(&state, .receivedEnvelope(numericAResolution))
        precondition(state.pendingDirectRequests.count == 2)
        precondition(
            !state.pendingDirectRequests.contains {
                $0.key == CoveDirectRequestKey(
                    requestId: .integer(7),
                    launchId: "launch-a",
                    sessionId: "session-a",
                    source: .localCli
                )
            }
        )
        precondition(
            state.pendingDirectRequests.contains {
                $0.key == CoveDirectRequestKey(
                    requestId: .string("7"),
                    launchId: "launch-a",
                    sessionId: "session-a",
                    source: .localCli
                )
            }
        )

        let remainingNumericKey = CoveDirectRequestKey(
            requestId: .integer(7),
            launchId: "launch-b",
            sessionId: "session-b",
            source: .localCli
        )
        let threadlessResolution = resolutionEnvelope(
            eventId: "threadless-numeric-resolution",
            requestId: .number(7),
            launchId: "launch-b",
            sessionId: "unknown",
            timestamp: 6
        )
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(threadlessResolution)
        )
        precondition(state.pendingDirectRequests.count == 1)
        precondition(
            !state.pendingDirectRequests.contains {
                $0.key == remainingNumericKey
            }
        )
        precondition(
            state.pendingDirectRequests.first?.requestId == .string("7")
        )
        CoveReducer.reduce(
            &state,
            .resolveDirectRequest(state.pendingDirectRequests[0].key)
        )
        precondition(state.pendingDirectRequests.isEmpty)

        let turnA = requestEnvelope(
            eventId: "turn-a-request",
            requestId: .number(99),
            launchId: "shared-launch",
            sessionId: "shared-session",
            title: "Turn A",
            timestamp: 7,
            turnId: "turn-a"
        )
        let turnB = requestEnvelope(
            eventId: "turn-b-request",
            requestId: .number(99),
            launchId: "shared-launch",
            sessionId: "shared-session",
            title: "Turn B",
            timestamp: 8,
            turnId: "turn-b"
        )
        CoveReducer.reduce(&state, .receivedEnvelope(turnA))
        CoveReducer.reduce(&state, .receivedEnvelope(turnB))
        precondition(state.pendingDirectRequests.count == 2)

        let turnAResolution = resolutionEnvelope(
            eventId: "turn-a-resolution",
            requestId: .number(99),
            launchId: "shared-launch",
            sessionId: "shared-session",
            timestamp: 9,
            turnId: "turn-a"
        )
        CoveReducer.reduce(&state, .receivedEnvelope(turnAResolution))
        precondition(state.pendingDirectRequests.count == 1)
        precondition(state.pendingDirectRequests.first?.turnId == "turn-b")
    }

    static func testDirectRequestOriginIsolation() throws {
        let requestId = CoveJSONValue.string("shared-request")
        let sessionId = "shared-session"
        let launchId = "shared-launch"
        let turnId = "shared-turn"

        func requestEnvelope(
            eventId: String,
            source: CoveWireSource,
            hostId: String? = nil
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventId,
                kind: .approvalRequested,
                timestamp: Date(timeIntervalSince1970: 1),
                source: source,
                sessionId: sessionId,
                turnId: turnId,
                launchId: launchId,
                hostId: hostId,
                payload: .object([
                    "method": .string(
                        "item/commandExecution/requestApproval"
                    ),
                    "requestId": requestId,
                    "title": .string(eventId),
                    "availableDecisions": .array([
                        .string("accept"),
                        .string("decline"),
                    ]),
                ])
            )
        }

        func resolutionEnvelope(
            eventId: String,
            source: CoveWireSource,
            hostId: String? = nil
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventId,
                kind: .serverRequestResolved,
                timestamp: Date(timeIntervalSince1970: 2),
                source: source,
                sessionId: sessionId,
                turnId: turnId,
                launchId: launchId,
                hostId: hostId,
                payload: .object([
                    "message": .object([
                        "method": .string("serverRequest/resolved"),
                        "params": .object(["requestId": requestId]),
                    ]),
                ])
            )
        }

        let local = requestEnvelope(
            eventId: "local-request",
            source: .localCli,
            hostId: "ignored-local-host"
        )
        let desktop = requestEnvelope(
            eventId: "desktop-request",
            source: .codexDesktop,
            hostId: "ignored-desktop-host"
        )
        let remoteA = requestEnvelope(
            eventId: "remote-a-request",
            source: .remoteCli,
            hostId: "remote-a"
        )
        let remoteB = requestEnvelope(
            eventId: "remote-b-request",
            source: .remoteCli,
            hostId: "remote-b"
        )

        var state = CoveState(settings: .init(autoExpandOnEvent: false))
        for envelope in [local, desktop, remoteA, remoteB] {
            CoveReducer.reduce(&state, .receivedEnvelope(envelope))
        }
        precondition(state.pendingDirectRequests.count == 4)
        precondition(Set(state.pendingDirectRequests.map(\.key)).count == 4)
        precondition(
            state.pendingDirectRequests.first(where: {
                $0.source == .localCli
            })?.hostId == nil
        )
        precondition(
            Set(
                state.pendingDirectRequests.compactMap { request in
                    request.source == .remoteCli ? request.hostId : nil
                }
            ) == Set(["remote-a", "remote-b"])
        )

        let originSnapshots = state.pendingDirectRequests.map { request in
            CoveSessionSnapshot(
                snapshotId: "snapshot-\(request.source?.rawValue ?? "legacy")-\(request.hostId ?? "local")",
                status: .waitingApproval,
                priority: 100,
                title: "Fixture",
                timestamp: Date(timeIntervalSince1970: 1),
                sessionId: sessionId,
                launchId: launchId,
                source: request.source,
                hostId: request.hostId
            )
        }
        let projection = CoveQueueProjection(
            snapshots: originSnapshots,
            directRequests: state.pendingDirectRequests
        )
        precondition(projection.needsAttention.count == 4)
        precondition(
            projection.needsAttention.allSatisfy { item in
                item.snapshot?.originScope == item.directRequest?.originScope
            }
        )
        precondition(local.processedEventKey != desktop.processedEventKey)
        precondition(remoteA.processedEventKey != remoteB.processedEventKey)

        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                resolutionEnvelope(
                    eventId: "remote-without-host-resolution",
                    source: .remoteCli
                )
            )
        )
        precondition(state.pendingDirectRequests.count == 4)

        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                resolutionEnvelope(
                    eventId: "local-resolution",
                    source: .localCli,
                    hostId: "another-ignored-host"
                )
            )
        )
        precondition(state.pendingDirectRequests.count == 3)
        precondition(
            !state.pendingDirectRequests.contains { $0.source == .localCli }
        )
        precondition(
            state.pendingDirectRequests.contains {
                $0.source == .codexDesktop
            }
        )

        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                resolutionEnvelope(
                    eventId: "remote-a-resolution",
                    source: .remoteCli,
                    hostId: "remote-a"
                )
            )
        )
        precondition(state.pendingDirectRequests.count == 2)
        precondition(
            !state.pendingDirectRequests.contains {
                $0.source == .remoteCli && $0.hostId == "remote-a"
            }
        )
        precondition(
            state.pendingDirectRequests.contains {
                $0.source == .remoteCli && $0.hostId == "remote-b"
            }
        )

        CoveReducer.reduce(
            &state,
            .resolveDirectRequests(
                sessionId: sessionId,
                turnId: turnId,
                launchId: launchId
            )
        )
        precondition(state.pendingDirectRequests.count == 2)

        CoveReducer.reduce(
            &state,
            .resolveDirectRequests(
                sessionId: sessionId,
                turnId: turnId,
                launchId: launchId,
                source: .remoteCli,
                hostId: "remote-b"
            )
        )
        precondition(state.pendingDirectRequests.count == 1)
        precondition(
            state.pendingDirectRequests.first?.source == .codexDesktop
        )

        let legacyData = Data(
            #"{"schemaVersion":1,"category":"command","requestId":"shared-request","launchId":"shared-launch","sessionId":"shared-session","turnId":"shared-turn","title":"Legacy","choices":[],"amendments":[]}"#.utf8
        )
        let legacyApproval = try JSONDecoder().decode(
            CoveApprovalRequest.self,
            from: legacyData
        )
        precondition(legacyApproval.source == nil)
        precondition(legacyApproval.hostId == nil)

        guard let exactDesktop = desktop.directRequest() else {
            fatalError("Expected Desktop direct request")
        }
        let legacyRequest = CoveDirectRequest.approval(legacyApproval)
        var legacyState = CoveState(
            pendingDirectRequests: [
                legacyRequest,
                exactDesktop,
            ]
        )
        CoveReducer.reduce(
            &legacyState,
            .resolveDirectRequest(legacyRequest.key)
        )
        precondition(legacyState.pendingDirectRequests.count == 2)
        CoveReducer.reduce(
            &legacyState,
            .resolveDirectRequest(exactDesktop.key)
        )
        precondition(legacyState.pendingDirectRequests.count == 1)
        CoveReducer.reduce(
            &legacyState,
            .resolveDirectRequest(legacyRequest.key)
        )
        precondition(legacyState.pendingDirectRequests.isEmpty)
    }

    static func testMalformedAdvertisedChoicesAreDropped() throws {
        let envelope = CoveWireEnvelope(
            eventId: "evt-malformed-choice",
            kind: .approvalRequested,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .localCli,
            sessionId: "session-choice",
            payload: .object([
                "method": .string("item/commandExecution/requestApproval"),
                "requestId": .string("approval-choice"),
                "choices": .array([
                    .object(["description": .string("No label or value")])
                ])
            ])
        )
        guard case let .approval(request)? = envelope.directRequest() else {
            fatalError("Expected approval request")
        }
        precondition(request.choices.isEmpty)

        let officialEnvelope = CoveWireEnvelope(
            eventId: "evt-official-decisions",
            kind: .approvalRequested,
            timestamp: Date(timeIntervalSince1970: 0),
            source: .localCli,
            sessionId: "session-choice",
            payload: .object([
                "method": .string("item/commandExecution/requestApproval"),
                "requestId": .string("official-decisions"),
                "availableDecisions": .array([.string("decline")]),
                "choices": .array([
                    .object(["id": .string("accept"), "label": .string("Accept")])
                ])
            ])
        )
        guard case let .approval(officialRequest)? = officialEnvelope.directRequest() else {
            fatalError("Expected approval request with official decisions")
        }
        precondition(officialRequest.choices.map(\.identifier) == ["decline"])

        let choices = CoveChoice.fromJSONValueArray(
            .array([
                .object(["description": .string("Malformed")]),
                .string("Explicit"),
                .object(["id": .string("ok"), "label": .string("Supplied")])
            ])
        )
        precondition(choices.map(\.label) == ["Explicit", "Supplied"])
    }

    static func testPersistenceSanitizesTransientState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let storage = CoveFileStateStorage(url: url)
        let state = CoveState(
            session: .init(isExpanded: true, isDocked: true, isVisible: false, isListening: true, activeStatus: .active, statusPriority: 42),
            settings: .init(
                themeFamily: .minimalOled,
                palette: .highContrast,
                launchAtLogin: true,
                squareTopCorners: false,
                showProfileTokenUsage: true
            ),
            theme: CoveThemeCatalog.palette(for: .minimalOled, palette: .highContrast),
            lastEvent: .init(kind: .display, title: "Transient", body: "PROMPT_RESPONSE_COMMAND_DIFF_SENTINEL"),
            recentEvents: [.init(kind: .display, title: "Transient", body: "PROMPT_RESPONSE_COMMAND_DIFF_SENTINEL")],
            pendingDirectRequests: [
                .question(
                    .init(
                        schemaVersion: 1,
                        requestId: "req-one",
                        launchId: "launch-one",
                        sessionId: "sid-one",
                        question: "DIRECT_REQUEST_SENTINEL_ONE",
                        options: [],
                        allowsFreeform: true,
                        decisionSocket: nil
                    )
                ),
                .question(
                    .init(
                        schemaVersion: 1,
                        requestId: 2,
                        launchId: "launch-two",
                        sessionId: "sid-two",
                        question: "DIRECT_REQUEST_SENTINEL_TWO",
                        options: [],
                        allowsFreeform: true,
                        decisionSocket: nil
                    )
                )
            ],
            usage: .init(
                resetCreditsAvailable: 1,
                resetCredits: [
                    .init(id: "RESET_CREDIT_OPAQUE_ID_SENTINEL")
                ],
                capturedAt: Date(),
                isPartial: true
            ),
            sessionTokenMetrics: [
                "TOKEN_SESSION_SENTINEL": .init(
                    inputTokens: 1,
                    cachedInputTokens: nil,
                    outputTokens: 2,
                    reasoningOutputTokens: nil,
                    totalTokens: 3,
                    contextWindow: 4,
                    capturedAt: Date()
                )
            ]
        )
        try storage.save(state)
        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)
        precondition(text.contains("\"schemaVersion\" : 1"))
        precondition(text.contains("\"showProfileTokenUsage\" : true"))
        precondition(!text.contains("\"showRecentEvents\""))
        precondition(!text.contains("\"recentEventsExpanded\""))
        precondition(text.contains("\"squareTopCorners\" : false"))
        precondition(!text.contains("PROMPT_RESPONSE_COMMAND_DIFF_SENTINEL"))
        precondition(!text.contains("DIRECT_REQUEST_SENTINEL"))
        precondition(!text.contains("RESET_CREDIT_OPAQUE_ID_SENTINEL"))
        precondition(!text.contains("TOKEN_SESSION_SENTINEL"))
        precondition(!text.contains("\"activeStatus\""))
        precondition(!text.contains("\"snapshots\""))
        let loaded = try storage.load()
        precondition(loaded?.settings == state.settings)
        precondition(loaded?.session.isExpanded == false)
        precondition(loaded?.session.activeStatus == .idle)
        precondition(loaded?.recentEvents.isEmpty == true)
        precondition(loaded?.pendingDirectRequests.isEmpty == true)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    static func testSQLiteMetadataPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sessions.sqlite3")
        let storage = CoveSQLiteSessionMetadataStorage(url: databaseURL, maximumQueryRows: 2)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = startedAt.addingTimeInterval(60)
        let reminderAt = updatedAt.addingTimeInterval(60)
        let metadata = CoveSessionMetadata(
            sessionId: "session-1",
            launchId: "launch-1",
            turnId: "turn-1",
            source: .localCli,
            status: .blocked,
            unread: true,
            reminderAt: reminderAt,
            terminalLocation: .init(
                adapter: "tmux",
                locationIdentifier: "%12"
            ),
            hostId: "host-1",
            parentSessionId: "session-parent",
            updatedAt: updatedAt,
            startedAt: startedAt
        )

        try storage.upsert(metadata)
        let loadedMetadata = try storage.metadata(sessionId: "session-1")
        precondition(loadedMetadata == metadata)

        try storage.upsert(
            .init(
                sessionId: "session-2",
                source: .codexDesktop,
                status: .active,
                updatedAt: updatedAt.addingTimeInterval(1),
                startedAt: startedAt
            )
        )
        try storage.upsert(
            .init(
                sessionId: "session-3",
                source: .remoteCli,
                status: .quiet,
                hostId: "build-host",
                updatedAt: updatedAt.addingTimeInterval(2),
                startedAt: startedAt
            )
        )
        let recentMetadata = try storage.recent(limit: 999)
        precondition(recentMetadata.count == 2)

        let diagnostics = try storage.diagnostics(now: reminderAt)
        precondition(diagnostics.schemaVersion == 2)
        precondition(diagnostics.directoryPermissions == 0o700)
        precondition(diagnostics.databasePermissions == 0o600)
        precondition(diagnostics.sessionCount == 3)
        precondition(diagnostics.unreadCount == 1)
        precondition(diagnostics.scheduledReminderCount == 1)
        precondition(diagnostics.dueReminderCount == 1)
        precondition(diagnostics.statusCounts[CoveSessionStatus.blocked.rawValue] == 1)

        let diagnosticText = String(
            decoding: try JSONEncoder().encode(diagnostics),
            as: UTF8.self
        )
        precondition(!diagnosticText.contains("session-1"))
        precondition(!diagnosticText.contains("%12"))
        precondition(!diagnosticText.contains("host-1"))

        let rawDatabase = String(
            decoding: try Data(contentsOf: databaseURL),
            as: UTF8.self
        )
        precondition(!rawDatabase.contains("PROMPT_RESPONSE_COMMAND_DIFF_SENTINEL"))
        for forbiddenColumn in ["prompt", "response", "command", "diff", "cwd", "project", "path"] {
            precondition(!rawDatabase.lowercased().contains(forbiddenColumn))
        }
        let databaseAttributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        precondition((databaseAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let reminderDatabase = CoveSQLiteSessionMetadataStorage(
            url: directory.appendingPathComponent("due-reminders.sqlite3"),
            maximumQueryRows: 200
        )
        let dueTime = updatedAt.addingTimeInterval(10)
        try reminderDatabase.upsert(
            .init(
                sessionId: "old-due-reminder",
                source: .localCli,
                status: .completed,
                reminderAt: dueTime,
                updatedAt: updatedAt,
                startedAt: startedAt
            )
        )
        for index in 0 ..< 125 {
            try reminderDatabase.upsert(
                .init(
                    sessionId: "newer-row-\(index)",
                    source: .localCli,
                    status: .idle,
                    updatedAt: updatedAt.addingTimeInterval(
                        Double(index + 100)
                    ),
                    startedAt: startedAt
                )
            )
        }
        let dueReminders = try reminderDatabase.dueReminders(
            now: dueTime,
            limit: 200
        )
        precondition(dueReminders.map(\.sessionId) == ["old-due-reminder"])

        do {
            try storage.upsert(
                .init(
                    sessionId: "session-path",
                    source: .localCli,
                    status: .idle,
                    terminalLocation: .init(
                        adapter: "terminal",
                        locationIdentifier: "/private/project"
                    ),
                    updatedAt: updatedAt,
                    startedAt: startedAt
                )
            )
            fatalError("Filesystem paths must not be accepted as opaque terminal identifiers")
        } catch let error as CovePersistenceError {
            precondition(error == .invalidMetadata(field: "terminalLocation.locationIdentifier"))
        }
    }

    static func testCompositeMetadataIdentityAndMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CoveSQLiteSessionMetadataStorage(
            url: directory.appendingPathComponent("sessions.sqlite3")
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let records = [
            CoveSessionMetadata(
                sessionId: "collision",
                source: .localCli,
                status: .active,
                updatedAt: now,
                startedAt: now
            ),
            CoveSessionMetadata(
                sessionId: "collision",
                source: .codexDesktop,
                status: .idle,
                updatedAt: now,
                startedAt: now
            ),
            CoveSessionMetadata(
                sessionId: "collision",
                source: .remoteCli,
                status: .blocked,
                hostId: "host-a",
                updatedAt: now,
                startedAt: now
            ),
            CoveSessionMetadata(
                sessionId: "collision",
                source: .remoteCli,
                status: .working,
                hostId: "host-b",
                updatedAt: now,
                startedAt: now
            ),
        ]
        for record in records { try storage.upsert(record) }
        let ambiguousLookup = try storage.metadata(sessionId: "collision")
        precondition(ambiguousLookup == nil)
        for record in records {
            let identity = record.sessionIdentity!
            let loaded = try storage.metadata(identity: identity)
            precondition(loaded == record)
        }
        var collisionState = CoveState(
            pinnedSessionIDs: ["collision"],
            dismissedSessionIDs: ["collision"]
        )
        CoveReducer.reduce(&collisionState, .restoreMetadata(records))
        precondition(collisionState.ambiguousLegacySessionIdentityCount == 1)
        precondition(collisionState.pinnedSessionIDs == ["collision"])
        precondition(collisionState.dismissedSessionIDs == ["collision"])
        let beforeRemoval = try storage.diagnostics()
        precondition(beforeRemoval.sessionCount == 4)
        try storage.remove(identity: records[2].sessionIdentity!)
        let afterRemoval = try storage.diagnostics()
        precondition(afterRemoval.sessionCount == 3)

        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyURL = legacyDirectory.appendingPathComponent("sessions.sqlite3")
        var database: OpaquePointer?
        precondition(sqlite3_open(legacyURL.path, &database) == SQLITE_OK)
        guard let database else { fatalError("legacy SQLite fixture failed") }
        let legacySQL = """
        CREATE TABLE session_metadata (
          record_schema_version INTEGER NOT NULL,
          session_id TEXT PRIMARY KEY NOT NULL,
          launch_id TEXT, turn_id TEXT, source TEXT NOT NULL,
          status TEXT NOT NULL, unread INTEGER NOT NULL,
          reminder_at_ms INTEGER, terminal_adapter TEXT,
          terminal_location_id TEXT, host_id TEXT,
          parent_session_id TEXT, updated_at_ms INTEGER NOT NULL,
          started_at_ms INTEGER NOT NULL
        ) WITHOUT ROWID;
        INSERT INTO session_metadata VALUES
          (1, 'legacy-local', NULL, NULL, 'localCli', 'idle', 0,
           NULL, NULL, NULL, NULL, NULL, 1, 1),
          (1, 'legacy-remote', NULL, NULL, 'remoteCli', 'blocked', 1,
           2, NULL, NULL, NULL, NULL, 2, 1);
        PRAGMA user_version = 1;
        """
        precondition(sqlite3_exec(database, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let migrated = CoveSQLiteSessionMetadataStorage(url: legacyURL)
        try migrated.initialize()
        let migrationDiagnostics = try migrated.diagnostics()
        precondition(migrationDiagnostics.sessionCount == 1)
        precondition(migrationDiagnostics.ambiguousLegacyIdentityCount == 1)
        let ambiguousLegacy = try migrated.metadata(sessionId: "legacy-remote")
        precondition(ambiguousLegacy == nil)
    }

    static func testWorkspacePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let storage = CoveWorkspaceFileStorage(url: url)
        let identity = CoveSessionIdentity(
            source: .remoteCli,
            hostId: "build-host",
            sessionId: "task-1"
        )!
        let template = CovePromptTemplate(
            name: "Review",
            body: "Review the current change.",
            favorite: true,
            manualOrder: 0
        )
        var state = CoveWorkspaceState(
            gridOrder: [identity],
            promptTemplates: [template],
            lastSelectedView: .board
        )
        state.setAlias("Release shepherd", for: identity)
        state.setTags(["release", "backend"], for: identity)
        state.setLinks([
            .init(label: "Issue", url: URL(string: "https://example.com/issues/1")!),
        ], for: identity)
        state.assign(identity, to: "doing")
        try storage.save(state)
        let loaded = try storage.load()
        precondition(loaded == state)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        precondition(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )
        _ = try storage.load()
        let repairedAttributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        precondition(
            (repairedAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )
        var invalid = state
        invalid.promptTemplates[0].body = String(
            repeating: "x",
            count: CoveWorkspaceLimits.templateBodyBytes + 1
        )
        do {
            try storage.save(invalid)
            fatalError("Expected oversized template rejection")
        } catch CovePersistenceError.invalidWorkspace {
            // Expected before the existing valid document is replaced.
        }
        let preserved = try storage.load()
        precondition(preserved == state)
        var invalidLink = state
        invalidLink.setLinks([
            .init(label: "Unsafe", url: URL(string: "file:///private/tmp/x")!),
        ], for: identity)
        do {
            try storage.save(invalidLink)
            fatalError("Expected non-HTTP link rejection")
        } catch CovePersistenceError.invalidWorkspace {
        }

        var invalidIdentity = identity
        invalidIdentity.remoteHostId = nil
        var invalidOrigin = state
        invalidOrigin.gridOrder = [invalidIdentity]
        do {
            try storage.save(invalidOrigin)
            fatalError("Expected invalid decoded composite identity rejection")
        } catch CovePersistenceError.invalidWorkspace {
        }

        var tooManyTemplates = state
        tooManyTemplates.promptTemplates = (0...CoveWorkspaceLimits.templates).map {
            CovePromptTemplate(name: "Template \($0)", body: "Body", manualOrder: $0)
        }
        do {
            try storage.save(tooManyTemplates)
            fatalError("Expected template-count rejection")
        } catch CovePersistenceError.invalidWorkspace {
        }

        let encoded = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        precondition(encoded.contains("Release shepherd"))
        precondition(encoded.contains("Review the current change."))
        precondition(!encoded.contains("latestOutput"))
        precondition(!encoded.contains("composerText"))
        precondition(!encoded.contains("transcript"))

        let newerURL = directory.appendingPathComponent("newer-workspace.json")
        var newer = state
        newer.schemaVersion = CoveWorkspaceState.currentSchemaVersion + 1
        let newerEncoder = JSONEncoder()
        newerEncoder.dateEncodingStrategy = .millisecondsSince1970
        try newerEncoder.encode(newer).write(to: newerURL)
        do {
            _ = try CoveWorkspaceFileStorage(url: newerURL).load()
            fatalError("Expected newer Workspace schema rejection")
        } catch CovePersistenceError.unsupportedWorkspaceSchema {
        }

        let corruptURL = directory.appendingPathComponent("corrupt-workspace.json")
        try Data("{not-json".utf8).write(to: corruptURL)
        do {
            _ = try CoveWorkspaceFileStorage(url: corruptURL).load()
            fatalError("Expected corrupt Workspace rejection")
        } catch is DecodingError {
        }

        let targetURL = directory.appendingPathComponent("workspace-target.json")
        try Data("unchanged".utf8).write(to: targetURL)
        let symlinkURL = directory.appendingPathComponent("linked-workspace.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: targetURL
        )
        let linkedStorage = CoveWorkspaceFileStorage(url: symlinkURL)
        do {
            try linkedStorage.save(state)
            fatalError("Expected Workspace symlink rejection")
        } catch CovePersistenceError.unsafeFilesystemEntry {
        }
        let preservedTarget = try Data(contentsOf: targetURL)
        precondition(String(decoding: preservedTarget, as: UTF8.self) == "unchanged")
    }

    static func testWorkspaceProjection() throws {
        let root = CoveSessionIdentity(source: .localCli, hostId: nil, sessionId: "root")!
        let child = CoveSessionIdentity(source: .localCli, hostId: nil, sessionId: "child")!
        let grandchild = CoveSessionIdentity(source: .localCli, hostId: nil, sessionId: "grandchild")!
        let orphan = CoveSessionIdentity(source: .localCli, hostId: nil, sessionId: "orphan")!
        let cycleA = CoveSessionIdentity(source: .remoteCli, hostId: "one", sessionId: "cycle-a")!
        let cycleB = CoveSessionIdentity(source: .remoteCli, hostId: "one", sessionId: "cycle-b")!
        let sameRawOtherOrigin = CoveSessionIdentity(source: .codexDesktop, hostId: nil, sessionId: "root")!
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        func snapshot(
            _ identity: CoveSessionIdentity,
            parent: String? = nil,
            status: CoveSessionStatus = .idle,
            liveness: CoveSessionLiveness = .loaded
        ) -> CoveSessionSnapshot {
            .init(
                snapshotId: identity.sessionId,
                status: status,
                priority: status == .waitingInput ? 95 : 5,
                title: identity.sessionId,
                timestamp: now,
                sessionId: identity.sessionId,
                source: identity.source,
                hostId: identity.remoteHostId,
                parentSessionId: parent,
                liveness: liveness,
                controlRoute: identity.source == .codexDesktop ? .desktop : nil
            )
        }
        var workspace = CoveWorkspaceState(gridOrder: [
            root, child, grandchild, orphan, cycleA, cycleB, sameRawOtherOrigin,
        ])
        workspace.setAlias("Main release", for: root)
        workspace.setTags(["release"], for: root)
        workspace.setLinks([
            .init(label: "Release issue", url: URL(string: "https://example.com/release")!),
        ], for: root)
        workspace.assign(root, to: "review")
        var unreadGrandchild = snapshot(
            grandchild,
            parent: child.sessionId,
            status: .waitingInput
        )
        unreadGrandchild.unread = true
        let snapshots = [
            snapshot(root),
            snapshot(child, parent: root.sessionId),
            unreadGrandchild,
            snapshot(orphan, parent: "missing"),
            snapshot(cycleA, parent: cycleB.sessionId),
            snapshot(cycleB, parent: cycleA.sessionId),
            snapshot(sameRawOtherOrigin),
        ]
        let projection = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            query: "release",
            sort: .manual
        )
        precondition(projection.items.map(\.identity) == [root])
        precondition(projection.items[0].descendantAttentionCount == 1)
        let complete = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            sort: .manual
        )
        precondition(complete.items.count == 7)
        precondition(Set(complete.unattachedAgents) == [orphan, cycleA, cycleB])
        precondition(complete.item(root)?.children == [child])
        precondition(complete.item(sameRawOtherOrigin)?.children.isEmpty == true)
        let redacted = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            query: "release",
            redactSensitiveContent: true
        )
        precondition(redacted.items.isEmpty)
        let redactedHost = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            query: "one",
            redactSensitiveContent: true
        )
        precondition(redactedHost.items.isEmpty)
        let redactedSensitiveFilters = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            filter: .init(
                sources: [.codexDesktop],
                hosts: ["one"],
                tags: ["release"],
                columns: ["review"]
            ),
            redactSensitiveContent: true
        )
        precondition(redactedSensitiveFilters.items.count == snapshots.count)

        func identities(
            _ filter: CoveWorkspaceFilter,
            pinned: Set<CoveSessionIdentity> = []
        ) -> Set<CoveSessionIdentity> {
            Set(
                CoveWorkspaceProjection(
                    snapshots: snapshots,
                    workspace: workspace,
                    pinnedIdentities: pinned,
                    filter: filter,
                    sort: .manual
                ).items.map(\.identity)
            )
        }
        precondition(identities(.init(statuses: [.waitingInput])) == [grandchild])
        precondition(identities(.init(sources: [.codexDesktop])) == [sameRawOtherOrigin])
        precondition(identities(.init(hosts: ["one"])) == [cycleA, cycleB])
        precondition(identities(.init(tags: ["release"])) == [root])
        precondition(identities(.init(columns: ["review"])) == [root])
        precondition(identities(.init(unreadOnly: true)) == [grandchild])
        precondition(identities(.init(pinnedOnly: true), pinned: [root]) == [root])
        precondition(identities(.init(controllableOnly: true)) == [sameRawOtherOrigin])
        precondition(
            identities(.init(attentionOnly: true))
                == [root, child, grandchild]
        )

        let linkSearch = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            query: "example.com"
        )
        precondition(linkSearch.items.map(\.identity) == [root])
        let sourceSearch = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            query: "codex desktop"
        )
        precondition(sourceSearch.items.map(\.identity) == [sameRawOtherOrigin])

        let attentionSorted = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            sort: .attention
        )
        precondition(attentionSorted.items.first?.identity == grandchild)
        let nameSorted = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            sort: .name
        )
        precondition(nameSorted.items.first?.identity == child)
        let sourceSorted = CoveWorkspaceProjection(
            snapshots: snapshots,
            workspace: workspace,
            sort: .source
        )
        precondition(sourceSorted.items.first?.identity.source == .codexDesktop)

        var insertionWorkspace = CoveWorkspaceState(gridOrder: [root, child])
        insertionWorkspace.ensureMembership([child, orphan, orphan])
        precondition(insertionWorkspace.gridOrder == [root, child, orphan])
        insertionWorkspace.assign(root, to: "doing")
        insertionWorkspace.deleteColumn(id: "doing")
        precondition(insertionWorkspace.columnID(for: root) == CoveWorkspaceState.inboxColumnID)
        let insertionProjection = CoveWorkspaceProjection(
            snapshots: [snapshot(child), snapshot(orphan)],
            workspace: insertionWorkspace,
            sort: .manual
        )
        precondition(insertionProjection.items.map(\.identity) == [child, orphan])
        let closed = snapshot(root, status: .completed, liveness: .closed)
        precondition(!CoveWorkspaceProjection.isWorkspaceMember(closed))
        var failed = snapshot(root, status: .failed, liveness: .closed)
        failed.unread = true
        precondition(CoveWorkspaceProjection.isWorkspaceMember(failed))
        failed.unread = false
        precondition(!CoveWorkspaceProjection.isWorkspaceMember(failed))
        var interrupted = snapshot(root, status: .interrupted, liveness: .closed)
        interrupted.unread = true
        precondition(CoveWorkspaceProjection.isWorkspaceMember(interrupted))
        var activeWithoutTurn = snapshot(
            sameRawOtherOrigin,
            status: .working,
            liveness: .loaded
        )
        precondition(!activeWithoutTurn.canAcceptThreadControl)
        activeWithoutTurn.activeTurnId = "turn-1"
        precondition(activeWithoutTurn.canAcceptThreadControl)
    }

    static func testLoadedThreadAndControlContracts() throws {
        let page = Data(#"{"id":"loaded-1","result":{"data":["a",{"threadId":"b"}],"nextCursor":"next"}}"#.utf8)
        let parsed = try CoveDesktopThreadSnapshotParser.loadedThreadPage(
            from: page,
            expectedID: "loaded-1"
        )
        precondition(parsed.ids == ["a", "b"])
        precondition(parsed.nextCursor == "next")
        let identity = CoveSessionIdentity(
            source: .codexDesktop,
            hostId: nil,
            sessionId: "desktop-task"
        )!
        try CoveThreadControlRequest(
            target: identity,
            operation: .start,
            input: "Continue"
        ).validate()
        do {
            try CoveThreadControlRequest(
                target: identity,
                operation: .steer,
                input: "Steer"
            ).validate()
            fatalError("Expected an exact turn ID for steer")
        } catch CovePersistenceError.invalidMetadata {
        }
        do {
            try CoveThreadControlRequest(
                target: identity,
                operation: .start,
                expectedTurnId: "unexpected",
                input: "Start"
            ).validate()
            fatalError("Expected start to reject an expected turn ID")
        } catch CovePersistenceError.invalidMetadata {
        }
        do {
            try CoveThreadControlRequest(
                target: identity,
                operation: .start,
                clientMessageId: "not valid",
                input: "Start"
            ).validate()
            fatalError("Expected a bounded transport-safe control ID")
        } catch CovePersistenceError.invalidMetadata {
        }

        var state = CoveState()
        let started = CoveWireEnvelope(
            eventId: "turn-started-control",
            kind: .appServer,
            timestamp: Date(timeIntervalSince1970: 1_900_000_000),
            source: .localCli,
            sessionId: "routed-task",
            launchId: "launch-1",
            payload: .object([
                "message": .object([
                    "method": .string("turn/started"),
                    "params": .object([
                        "turn": .object(["id": .string("turn-1")])
                    ])
                ]),
                "liveness": .string("live"),
                "controlRoute": .string("routedLocal"),
            ])
        )
        precondition(started.authoritativeStartedTurnID() == "turn-1")
        CoveReducer.reduce(&state, .receivedEnvelope(started))
        precondition(state.session.activeSnapshot?.activeTurnId == "turn-1")
        precondition(state.session.activeSnapshot?.liveness == .live)
        precondition(state.session.activeSnapshot?.controlRoute == .routedLocal)
        var completed = started
        completed.eventId = "turn-completed-control"
        completed.timestamp = started.timestamp.addingTimeInterval(1)
        completed.payload = .object([
            "message": .object([
                "method": .string("turn/completed"),
                "params": .object([:])
            ]),
            "liveness": .string("live"),
            "controlRoute": .string("routedLocal"),
        ])
        precondition(completed.endsActiveTurn)
        CoveReducer.reduce(&state, .receivedEnvelope(completed))
        precondition(state.session.activeSnapshot?.activeTurnId == nil)

        func terminalSnapshot(
            eventID: String,
            timestamp: Date,
            status: CoveSessionStatus
        ) -> CoveWireEnvelope {
            CoveWireEnvelope(
                eventId: eventID,
                kind: .sessionSnapshot,
                timestamp: timestamp,
                source: .codexDesktop,
                sessionId: identity.sessionId,
                payload: .object([
                    "snapshotId": .string(identity.sessionId),
                    "status": .string(status.rawValue),
                    "priority": .number(90),
                    "title": .string("Desktop task"),
                    "liveness": .string("loaded"),
                    "unread": .bool(true),
                ])
            )
        }
        let failedAt = started.timestamp.addingTimeInterval(2)
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                terminalSnapshot(
                    eventID: "desktop-failed-1",
                    timestamp: failedAt,
                    status: .failed
                )
            )
        )
        precondition(state.session.snapshots.first {
            $0.sessionIdentity == identity
        }?.unread == true)
        CoveReducer.reduce(&state, .markRead(identity))
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                terminalSnapshot(
                    eventID: "desktop-failed-repeat",
                    timestamp: failedAt,
                    status: .failed
                )
            )
        )
        precondition(state.session.snapshots.first {
            $0.sessionIdentity == identity
        }?.unread == false)
        CoveReducer.reduce(
            &state,
            .receivedEnvelope(
                terminalSnapshot(
                    eventID: "desktop-interrupted-newer",
                    timestamp: failedAt.addingTimeInterval(1),
                    status: .interrupted
                )
            )
        )
        precondition(state.session.snapshots.first {
            $0.sessionIdentity == identity
        }?.unread == true)
    }

    static func testPendingSessionAttributionPreservesLaunchMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CoveSQLiteSessionMetadataStorage(
            url: directory.appendingPathComponent("sessions.sqlite3")
        )
        let pendingStartedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let terminalLocation = CoveTerminalLocationMetadata(
            adapter: "cursor",
            locationIdentifier: "editor-terminal-17",
            hostBundleIdentifier: "com.todesktop.230313mzl4w4u92",
            focusSocketIdentifier: "launch-1",
            tmuxPaneIdentifier: "%17",
            weztermPaneIdentifier: "417",
            ttyIdentifier: "ttys017",
            oscMarkerIdentifier: "cove-marker-17",
            editorTerminalIdentifier: "editor-terminal-17"
        )
        try storage.upsert(
            .init(
                sessionId: "launch-1",
                launchId: "launch-1",
                source: .localCli,
                status: .idle,
                terminalLocation: terminalLocation,
                updatedAt: pendingStartedAt,
                startedAt: pendingStartedAt
            )
        )

        let realStartedAt = pendingStartedAt.addingTimeInterval(30)
        try storage.upsert(
            .init(
                sessionId: "thread-real-1",
                launchId: "launch-1",
                turnId: "turn-1",
                source: .localCli,
                status: .active,
                updatedAt: realStartedAt,
                startedAt: realStartedAt
            ),
            replacingSessionId: "launch-1"
        )

        let pendingAfterAttribution = try storage.metadata(sessionId: "launch-1")
        precondition(pendingAfterAttribution == nil)
        let remaining = try storage.recent(limit: 10)
        precondition(remaining.count == 1)
        guard let attributed = remaining.first else {
            fatalError("Expected the attributed real session")
        }
        precondition(attributed.sessionId == "thread-real-1")
        precondition(attributed.startedAt == pendingStartedAt)
        precondition(attributed.terminalLocation == terminalLocation)
    }

    static func testLegacySettingsMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let settings = CoveSettings(
            themeFamily: .retroTerminal,
            palette: .terminalGreen,
            playSounds: false
        )
        let encodedSettings = try JSONEncoder().encode(settings)
        let settingsObject = try JSONSerialization.jsonObject(with: encodedSettings)
        let legacyData = try JSONSerialization.data(
            withJSONObject: [
                "settings": settingsObject,
                "isExpanded": true,
                "activeStatus": "blocked",
                "detail": "legacy transient content",
            ],
            options: [.sortedKeys]
        )
        try legacyData.write(to: directory.appendingPathComponent("state.json"))

        let storage = CoveFileStateStorage(
            url: directory.appendingPathComponent("settings.json")
        )
        let migrated = try storage.load()
        precondition(migrated?.settings == settings)
        precondition(migrated?.session.isExpanded == false)
        precondition(migrated?.session.activeStatus == .idle)
    }

    static func testDecisionEncoding() throws {
        let frame = CoveDecisionFrame(
            launchId: "launch-1",
            requestId: "req-1",
            result: .approval(decision: .acceptForSession, amendment: .object(["path": .string("/tmp/file")]))
        )
        let data = try JSONEncoder().encode(frame)
        let text = String(decoding: data, as: UTF8.self)
        precondition(text.contains("\"decision\":\"acceptForSession\""))
        precondition(text.contains("\"requestId\":\"req-1\""))

        let questionFrame = CoveDecisionFrame(
            launchId: "launch-1",
            requestId: "req-question",
            result: .question(
                answers: [
                    "theme": CoveQuestionAnswer(answers: ["Native Glass"])
                ]
            )
        )
        let questionObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(questionFrame)
        ) as? [String: Any]
        let result = questionObject?["result"] as? [String: Any]
        let answers = result?["answers"] as? [String: Any]
        let theme = answers?["theme"] as? [String: Any]
        precondition(theme?["answers"] as? [String] == ["Native Glass"])
        precondition(Set(result?.keys.map { $0 } ?? []) == Set(["answers"]))
    }

    static func testRemoteDecisionProtocol() throws {
        let frame = CoveDecisionFrame(
            launchId: "launch-remote",
            requestId: 42,
            result: .approval(decision: .accept)
        )
        let control = CoveRemoteDecisionControl(
            controlId: "control-42",
            decisionSocket: "/private/tmp/codex-cove/decision.sock",
            decision: frame
        )
        let encodedControl = try JSONEncoder().encode(control)
        let decodedControl = try JSONDecoder().decode(
            CoveRemoteDecisionControl.self,
            from: encodedControl
        )
        precondition(decodedControl == control)
        precondition(decodedControl.schemaVersion == 1)
        precondition(decodedControl.type == "decision")
        let controlObject = try JSONSerialization.jsonObject(
            with: encodedControl
        ) as? [String: Any]
        precondition(controlObject?["controlId"] as? String == "control-42")
        precondition(controlObject?["decisionSocket"] as? String == control.decisionSocket)

        for status in [
            CoveRemoteDecisionAcknowledgementStatus.delivered,
            .failed,
        ] {
            let acknowledgement = CoveRemoteDecisionAcknowledgement(
                controlId: control.controlId,
                status: status
            )
            let decoded = try JSONDecoder().decode(
                CoveRemoteDecisionAcknowledgement.self,
                from: JSONEncoder().encode(acknowledgement)
            )
            precondition(decoded == acknowledgement)
            precondition(decoded.isSupported)
        }

        let relayEncoded = Data(
            """
            {"schemaVersion":1,"type":"decisionAck","controlId":"rust-control","status":"delivered"}
            """.utf8
        )
        let relayAcknowledgement = try JSONDecoder().decode(
            CoveRemoteDecisionAcknowledgement.self,
            from: relayEncoded
        )
        precondition(relayAcknowledgement.isSupported)
        precondition(relayAcknowledgement.controlId == "rust-control")
        precondition(relayAcknowledgement.status == .delivered)

        precondition(
            !CoveRemoteDecisionAcknowledgement(
                schemaVersion: 2,
                controlId: control.controlId,
                status: .delivered
            ).isSupported
        )
        precondition(
            !CoveRemoteDecisionAcknowledgement(
                type: "event",
                controlId: control.controlId,
                status: .delivered
            ).isSupported
        )
        precondition(
            !CoveRemoteDecisionAcknowledgement(
                controlId: "unsafe/control/id",
                status: .delivered
            ).isSupported
        )

        let identity = CoveSessionIdentity(
            source: .remoteCli,
            hostId: "build-host",
            sessionId: "thread-1"
        )!
        let threadRequest = CoveThreadControlRequest(
            target: identity,
            operation: .steer,
            expectedTurnId: "turn-1",
            clientMessageId: "message-1",
            input: "Change direction"
        )
        let threadControl = CoveRemoteThreadControl(
            controlId: "control-thread",
            controlSocket: "fixture-control-route",
            launchId: "launch-remote",
            request: threadRequest
        )
        let decodedThreadControl = try JSONDecoder().decode(
            CoveRemoteThreadControl.self,
            from: JSONEncoder().encode(threadControl)
        )
        precondition(decodedThreadControl == threadControl)
        precondition(decodedThreadControl.type == "threadControl")
        let threadAcknowledgement = CoveRemoteThreadControlAcknowledgement(
            controlId: "control-thread",
            status: .accepted,
            turnId: "turn-2"
        )
        precondition(threadAcknowledgement.isSupported)
        precondition(
            threadAcknowledgement.result == .accepted(turnId: "turn-2")
        )
        precondition(
            CoveRemoteThreadControlAcknowledgement(
                controlId: "control-thread",
                status: .rejected,
                rejection: .turnMismatch
            ).result == .rejected(.turnMismatch)
        )
    }

    static func testPersistentRemoteSSHSafety() throws {
        let arguments = CoveRemoteRelayProtocol.persistentSSHArguments(
            alias: "dev249",
            remoteCommand: "codex-cove remote-relay-server"
        )
        precondition(arguments.first == "-T")
        precondition(arguments.suffix(2) == [
            "dev249",
            "codex-cove remote-relay-server",
        ])
        for required in [
            "StrictHostKeyChecking=yes",
            "BatchMode=yes",
            "ConnectTimeout=10",
            "ServerAliveInterval=15",
            "ServerAliveCountMax=2",
        ] {
            precondition(arguments.contains(required))
        }
    }

    static func testFixtureDecoding() throws {
        let eventsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/cove-events.v1.jsonl")
        let decisionURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/decision-frame.v1.json")
        let numericDecisionURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/decision-frame.v1.json")
        let lines = try String(contentsOf: eventsURL, encoding: .utf8).split(whereSeparator: \.isNewline)
        precondition(lines.count == 6)

        let envelopes = lines.map { line -> CoveWireEnvelope in
            precondition(line.count < 1_048_576)
            guard let envelope = CoveEventDecoder.decodeLine(String(line)) else {
                fatalError("Failed to decode fixture line")
            }
            return envelope
        }
        guard case let .approval(approval)? = envelopes[2].directRequest() else {
            fatalError("Expected approval request from runtime-shaped fixture")
        }
        precondition(approval.requestId == .integer(42))
        guard case let .question(question)? = envelopes[3].directRequest() else {
            fatalError("Expected question request from runtime-shaped fixture")
        }
        precondition(question.requestId == .string("question-request"))
        precondition(question.questionId == "theme")
        precondition(question.options.count == 2)
        precondition(envelopes[4].resolvedRequestID() == .integer(42))
        precondition(envelopes[5].source == .codexDesktop)
        precondition(envelopes[5].sessionId == "thread-desktop")
        precondition(envelopes[5].turnId == "turn-desktop")
        guard case let .approval(desktopApproval)? = envelopes[5].directRequest() else {
            fatalError("Expected Desktop hook approval")
        }
        precondition(desktopApproval.sessionId == "thread-desktop")

        let decisionData = try Data(contentsOf: decisionURL)
        let frame = try JSONDecoder().decode(CoveDecisionFrame.self, from: decisionData)
        if case let .approval(decision, amendment) = frame.result {
            precondition(decision == .acceptForSession)
            precondition(amendment?.objectValue?["path"]?.stringValue == "/tmp/file")
        } else {
            fatalError("Unexpected decision frame")
        }

        let numericDecisionData = try Data(contentsOf: numericDecisionURL)
        let numericFrame = try JSONDecoder().decode(
            CoveDecisionFrame.self,
            from: numericDecisionData
        )
        precondition(numericFrame.requestId == .integer(42))
        let numericRoundTrip = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(numericFrame)
        ) as? [String: Any]
        precondition(numericRoundTrip?["requestId"] as? Int == 42)
        precondition(!(numericRoundTrip?["requestId"] is String))
    }

    static func testDecisionSocketDelivery() async throws {
        let fixture = try PrivateDecisionSocketFixture(mode: 0o600)
        defer { fixture.close() }
        let receivedLine = Task.detached {
            try fixture.acceptOneLine()
        }
        let frame = CoveDecisionFrame(
            launchId: "launch-1",
            requestId: "request-7",
            result: .question(
                answers: [
                    "theme": CoveQuestionAnswer(answers: ["Native Glass"])
                ]
            )
        )

        try await CoveDecisionSocketClient().send(frame, to: fixture.socketPath)
        let line = try await receivedLine.value
        precondition(line.last == 0x0a)
        precondition(line.count <= CoveDecisionSocketClient.protocolMaximumFrameBytes)

        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        precondition(object?["schemaVersion"] as? Int == 1)
        precondition(object?["launchId"] as? String == "launch-1")
        precondition(object?["requestId"] as? String == "request-7")
        let result = object?["result"] as? [String: Any]
        let answers = result?["answers"] as? [String: Any]
        let theme = answers?["theme"] as? [String: Any]
        precondition(theme?["answers"] as? [String] == ["Native Glass"])
        precondition(Set(result?.keys.map { $0 } ?? []) == Set(["answers"]))
    }

    static func testThreadControlSocketDelivery() async throws {
        let fixture = try PrivateDecisionSocketFixture(mode: 0o600)
        defer { fixture.close() }
        let server = Task.detached {
            try fixture.acceptOneLine(
                replying: Data(
                    #"{"jsonrpc":"2.0","id":"cove-thread-control:message-1","result":{"turn":{"id":"turn-2"}}}"#.utf8
                )
            )
        }
        let identity = CoveSessionIdentity(
            source: .localCli,
            hostId: nil,
            sessionId: "thread-1"
        )!
        let request = CoveThreadControlRequest(
            target: identity,
            operation: .steer,
            expectedTurnId: "turn-1",
            clientMessageId: "message-1",
            input: "Change direction"
        )
        let result = await CoveThreadControlSocketClient().send(
            request,
            launchId: "launch-1",
            to: fixture.socketPath
        )
        precondition(result == .accepted(turnId: "turn-2"))
        let line = try await server.value
        let object = try JSONSerialization.jsonObject(
            with: line.dropLast()
        ) as? [String: Any]
        precondition(object?["launchId"] as? String == "launch-1")
        precondition(object?["operation"] as? String == "steer")
        precondition(object?["expectedTurnId"] as? String == "turn-1")
        precondition(object?["input"] as? String == "Change direction")
        let target = object?["target"] as? [String: Any]
        precondition(target?["source"] as? String == "localCli")
        precondition(target?["sessionId"] as? String == "thread-1")

        let wrongResponseServer = Task.detached {
            try fixture.acceptOneLine(
                replying: Data(
                    #"{"jsonrpc":"2.0","id":"cove-thread-control:other","result":{"turnId":"turn-3"}}"#.utf8
                )
            )
        }
        let wrongResponse = await CoveThreadControlSocketClient().send(
            request,
            launchId: "launch-1",
            to: fixture.socketPath
        )
        precondition(wrongResponse == .uncertain)
        _ = try await wrongResponseServer.value

        let rejectedServer = Task.detached {
            try fixture.acceptOneLine(
                replying: Data(
                    #"{"schemaVersion":1,"type":"threadControlAck","controlId":"message-1","status":"rejected","rejection":"turnMismatch"}"#.utf8
                )
            )
        }
        let rejected = await CoveThreadControlSocketClient().send(
            request,
            launchId: "launch-1",
            to: fixture.socketPath
        )
        precondition(rejected == .rejected(.turnMismatch))
        _ = try await rejectedServer.value

        let wrongOrigin = CoveThreadControlRequest(
            target: CoveSessionIdentity(
                source: .remoteCli,
                hostId: "fixture-host",
                sessionId: "thread-1"
            )!,
            operation: .steer,
            expectedTurnId: "turn-1",
            clientMessageId: "message-1",
            input: "Change direction"
        )
        let wrongOriginResult = await CoveThreadControlSocketClient().send(
            wrongOrigin,
            launchId: "launch-1",
            to: fixture.socketPath
        )
        precondition(wrongOriginResult == .rejected(.wrongOrigin))
    }

    static func testDesktopOwnedTurnDecisionBridge() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "cc-owned-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("decision.json")
        let fixture = try FakeCodexFixture(
            body: """
            #!/bin/sh
            IFS= read -r initialize || exit 1
            initialize_id=$(printf '%s' "$initialize" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            printf '{"id":"%s","result":{}}\\n' "$initialize_id"
            IFS= read -r initialized || exit 1
            IFS= read -r control || exit 1
            control_id=$(printf '%s' "$control" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            printf '{"id":"%s","result":{"turn":{"id":"turn-1"}}}\\n' "$control_id"
            printf '%s\\n' '{"jsonrpc":"2.0","id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"desktop-task","turnId":"turn-1","availableDecisions":["accept","decline"]}}'
            IFS= read -r decision || exit 1
            printf '%s' "$decision" > '\(receipt.path)'
            sleep 2
            """
        )
        defer { fixture.close() }
        let events = OwnedDesktopEventBox()
        let controller = CoveDesktopOwnedThreadControlClient(
            configuration: .init(
                realCodexURL: fixture.executableURL,
                requestTimeout: 2,
                maximumLineBytes: 64 * 1_024,
                clientVersion: "test"
            ),
            runtimeDirectory: directory.appendingPathComponent(
                "runtime",
                isDirectory: true
            )
        )
        defer { controller.stop() }
        controller.setEventHandler { events.receive($0) }
        let identity = CoveSessionIdentity(
            source: .codexDesktop,
            hostId: nil,
            sessionId: "desktop-task"
        )!
        let result = await controller.send(
            CoveThreadControlRequest(
                target: identity,
                operation: .start,
                clientMessageId: "message-1",
                input: "Continue"
            )
        )
        guard result == .accepted(turnId: "turn-1") else {
            fatalError("Unexpected Desktop control result: \(result)")
        }
        for _ in 0..<200 where events.value() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let event = events.value(),
              case let .approval(approval)? = event.directRequest(),
              let decisionSocket = approval.decisionSocket
        else { fatalError("Expected owned Desktop approval event") }
        precondition(event.source == .codexDesktop)
        precondition(event.sessionId == identity.sessionId)
        try await CoveDecisionSocketClient().send(
            .init(
                launchId: approval.launchId,
                requestId: approval.requestId,
                result: .approval(decision: .accept)
            ),
            to: decisionSocket
        )
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: receipt.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = try JSONSerialization.jsonObject(
            with: Data(contentsOf: receipt)
        ) as? [String: Any]
        precondition(received?["id"] as? Int == 42)
        let receivedResult = received?["result"] as? [String: Any]
        precondition(receivedResult?["decision"] as? String == "accept")
    }

    static func testDecisionSocketBoundsAndPrivacy() async throws {
        let oversizedAnswer = String(
            repeating: "x",
            count: CoveDecisionSocketClient.protocolMaximumFrameBytes
        )
        let oversizedFrame = CoveDecisionFrame(
            launchId: "launch-1",
            requestId: "request-large",
            result: .question(
                answers: [
                    "freeform": CoveQuestionAnswer(answers: [oversizedAnswer])
                ]
            )
        )
        do {
            try await CoveDecisionSocketClient().send(oversizedFrame, to: "/not/a/socket")
            fatalError("Expected oversized decision frame rejection")
        } catch CoveDecisionSocketError.frameTooLarge {
            // Size validation intentionally happens before filesystem access.
        }

        let fixture = try PrivateDecisionSocketFixture(mode: 0o666)
        defer { fixture.close() }
        let decisionFrame = CoveDecisionFrame(
            launchId: "launch-1",
            requestId: "request-unsafe",
            result: .approval(decision: .decline)
        )
        do {
            try await CoveDecisionSocketClient().send(decisionFrame, to: fixture.socketPath)
            fatalError("Expected insecure decision socket rejection")
        } catch CoveDecisionSocketError.insecureSocket {
            // The client must only use a user-private decision socket.
        }
    }
}

private final class OwnedDesktopEventBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var event: CoveWireEnvelope?

    func receive(_ event: CoveWireEnvelope) {
        lock.lock()
        guard self.event == nil else {
            lock.unlock()
            return
        }
        self.event = event
        lock.unlock()
        semaphore.signal()
    }

    func value() -> CoveWireEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return event
    }
}

private final class FakeCodexFixture: @unchecked Sendable {
    let executableURL: URL
    private let directoryURL: URL

    init(body: String) throws {
        directoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "cove-fake-codex-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        executableURL = directoryURL.appendingPathComponent("codex")
        let script = "#!/bin/sh\nset -eu\n\(body)\n"
        try Data(script.utf8).write(
            to: executableURL,
            options: [.atomic]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func close() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class PrivateDecisionSocketFixture: @unchecked Sendable {
    let socketPath: String
    private let directoryURL: URL
    private let listener: Int32

    init(mode: mode_t) throws {
        directoryURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "cc-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        socketPath = directoryURL.appendingPathComponent("decision.sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let copied = socketPath.withCString { source -> Int in
                withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                    memset(destination, 0, capacity)
                    return strlcpy(destination, source, capacity)
                }
            }
            guard copied < capacity else {
                throw POSIXError(.ENAMETOOLONG)
            }
            let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard chmod(socketPath, mode) == 0, listen(listener, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(listener)
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func acceptOneLine() throws -> Data {
        try acceptOneLine(replying: nil)
    }

    func acceptOneLine(replying response: Data?) throws -> Data {
        let client = accept(listener, nil, nil)
        guard client >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(client) }

        var result = Data()
        var byte: UInt8 = 0
        while result.count <= CoveDecisionSocketClient.protocolMaximumFrameBytes {
            let count = Darwin.read(client, &byte, 1)
            if count == 1 {
                result.append(byte)
                if byte == 0x0a {
                    if var response {
                        if response.last != 0x0a { response.append(0x0a) }
                        _ = response.withUnsafeBytes { bytes in
                            Darwin.write(client, bytes.baseAddress, bytes.count)
                        }
                    }
                    return result
                }
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw CoveDecisionSocketError.frameTooLarge
    }

    func close() {
        Darwin.close(listener)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
