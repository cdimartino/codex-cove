import Foundation
import CoveCore

private struct FoundationTestRunner {
    private(set) var assertionCount = 0

    mutating func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertionCount += 1
        guard condition() else {
            fatalError(
                "Milestone 1/3 foundation test failed at \(file):\(line): \(message)"
            )
        }
    }
}

private func approvalRequest(
    id: CoveRequestID = .string("approval-1"),
    launchID: String = "launch-1",
    sessionID: String = "session-1",
    turnID: String = "turn-1"
) -> CoveDirectRequest {
    .approval(
        CoveApprovalRequest(
            schemaVersion: 1,
            category: .command,
            requestId: id,
            launchId: launchID,
            sessionId: sessionID,
            turnId: turnID,
            title: "Allow command?",
            detail: "swift test",
            choices: [
                CoveChoice(identifier: "accept", label: "Allow once"),
                CoveChoice(identifier: "decline", label: "Decline"),
            ],
            amendments: [],
            permissionProfile: nil,
            decisionSocket: "/tmp/codex-cove-foundation.sock"
        )
    )
}

private func decisionFrame(
    requestID: CoveRequestID = .string("approval-1"),
    launchID: String = "launch-1"
) -> CoveDecisionFrame {
    CoveDecisionFrame(
        launchId: launchID,
        requestId: requestID,
        result: .approval(decision: .accept)
    )
}

private func testSemanticTypography(_ runner: inout FoundationTestRunner) {
    let themes = CoveThemeCatalog.palettes
    runner.expect(themes.count == 15, "the built-in catalog must contain 15 themes")
    runner.expect(
        Set(themes.map(\.identifier)).count == themes.count,
        "every built-in theme must have a unique identifier"
    )

    let expectedMinimums: [CoveTextRole: Double] = [
        .title: 13,
        .body: 13,
        .status: 12,
        .metadata: 11,
        .badge: 11,
        .data: 11,
    ]
    runner.expect(
        CoveTextRole.allCases.count == expectedMinimums.count,
        "the test must account for every semantic typography role"
    )

    for theme in themes {
        let typography = theme.semanticTypography
        runner.expect(
            typography.satisfiesInformativeTextFloor,
            "\(theme.identifier) must satisfy the global informative-text floor"
        )
        runner.expect(
            typography.family == theme.fontName,
            "\(theme.identifier) must preserve its configured font family"
        )

        for role in CoveTextRole.allCases {
            let pointSize = typography.pointSize(for: role)
            let expectedMinimum = expectedMinimums[role]!
            runner.expect(
                pointSize >= expectedMinimum,
                "\(theme.identifier) \(role.rawValue) rendered at \(pointSize), below \(expectedMinimum)"
            )
            runner.expect(
                pointSize >= CoveSemanticTypography.informativeTextFloor,
                "\(theme.identifier) \(role.rawValue) must remain at least 11 pt"
            )
            runner.expect(
                typography.weight(for: role)
                    == (role == .title ? .semibold : theme.fontWeight),
                "\(theme.identifier) \(role.rawValue) resolved the wrong weight"
            )
        }
    }

    for scale in [0, -1, .nan, .infinity] {
        let typography = CoveSemanticTypography(
            family: "Fixture",
            themeWeight: .light,
            themeScale: scale
        )
        runner.expect(
            typography.satisfiesInformativeTextFloor,
            "invalid or undersized theme scale \(scale) must not bypass role minimums"
        )
    }
}

private func testContrastMatrix(_ runner: inout FoundationTestRunner) {
    let themes = CoveThemeCatalog.palettes
    let contexts = CoveThemeContrastMatrix.endpointContexts(
        opacityRange: 0.35 ... 1,
        usesOpaqueSemanticBacking: true
    )

    runner.expect(contexts.count == 16, "the endpoint matrix must contain 16 contexts")
    runner.expect(
        Set(contexts.map(\.id)).count == contexts.count,
        "every endpoint contrast context must have stable unique identity"
    )
    runner.expect(
        Set(contexts.map { $0.presentation.rawValue })
            == Set(CoveOverlayContrastPresentation.allCases.map(\.rawValue)),
        "the matrix must include collapsed and expanded presentations"
    )
    runner.expect(
        Set(contexts.map(\.opacity)) == Set([0.35, 1]),
        "the matrix must include both legal opacity endpoints"
    )
    runner.expect(
        Set(contexts.map { $0.desktop.rawValue })
            == Set(CoveRepresentativeDesktopBackground.allCases.map(\.rawValue)),
        "the matrix must include representative light and dark desktops"
    )
    runner.expect(
        Set(contexts.map { $0.contrastState.rawValue })
            == Set(CoveContrastState.allCases.map(\.rawValue)),
        "the matrix must include normal and Increased Contrast states"
    )
    runner.expect(
        contexts.allSatisfy(\.usesOpaqueSemanticBacking),
        "the enforced matrix must use the permitted opaque semantic backing"
    )

    var evaluatedCount = 0
    for theme in themes {
        let results = CoveThemeContrastMatrix.evaluate(
            theme: theme,
            contexts: contexts
        )
        let skippedBorderPairs = theme.borderStyle == .none
            || theme.borderWidth <= 0
            ? CoveSemanticBackgroundRole.allCases.count
            : 0
        let expectedPairsPerContext = CoveSemanticContrastPair.overlay.count
            - skippedBorderPairs
        runner.expect(
            results.count == contexts.count * expectedPairsPerContext,
            "\(theme.identifier) did not evaluate every exposed semantic pair"
        )
        runner.expect(
            Set(results.map(\.id)).count == results.count,
            "\(theme.identifier) produced duplicate contrast result identities"
        )

        for context in contexts {
            let contextResults = results.filter { $0.context == context }
            runner.expect(
                contextResults.count == expectedPairsPerContext,
                "\(theme.identifier) \(context.id) omitted a semantic pair"
            )
            for backgroundRole in CoveSemanticBackgroundRole.allCases {
                let rendered = CoveThemeContrastMatrix.renderedBackgroundColor(
                    backgroundRole,
                    theme: theme,
                    context: context
                )
                let expectedHex = backgroundRole == .background
                    ? theme.backgroundHex
                    : theme.surfaceHex
                runner.expect(
                    rendered == CoveSRGBColor(hex: expectedHex),
                    "opaque backing must be independent of desktop and presentation alpha"
                )
            }
        }

        let violations = results.filter { !$0.passes }
        let violationSummary = violations.map {
            "\($0.pair.id)=\(String(format: "%.2f", $0.ratio))"
        }.joined(separator: ", ")
        runner.expect(
            violations.isEmpty,
            "\(theme.identifier) has enforced contrast failures: \(violationSummary)"
        )
        evaluatedCount += results.count
    }

    runner.expect(
        evaluatedCount == 6_080,
        "expected 6,080 enforced built-in contrast evaluations, got \(evaluatedCount)"
    )
    runner.expect(
        CoveThemeContrastMatrix.violationsForBuiltInThemes(
            contexts: { _ in contexts }
        ).isEmpty,
        "the aggregate built-in contrast audit must have no violations"
    )
}

private func testGeometry(_ runner: inout FoundationTestRunner) {
    let narrowScreen = CoveScreenMetrics(
        screenWidth: 320,
        screenHeight: 900,
        safeAreaTop: 32,
        safeAreaLeft: 18,
        safeAreaRight: 18
    )
    runner.expect(
        narrowScreen.availableTopWidth == 284,
        "safe-area insets must reduce available top width"
    )
    runner.expect(
        CoveOverlayGeometry.resolvedWidth(
            screen: narrowScreen,
            desiredWidth: 520
        ) == 284,
        "focused content must clamp to a narrow screen's safe width"
    )

    let narrowLayout = CoveOverlayGeometry.layout(
        screen: narrowScreen,
        desiredWidth: 520,
        desiredHeight: 520,
        expanded: true
    )
    runner.expect(narrowLayout.width == 284, "layout must use the clamped width")
    runner.expect(narrowLayout.originX == 18, "clamped layout must remain in the safe area")
    runner.expect(
        narrowLayout.originY + narrowLayout.height == narrowScreen.screenHeight,
        "overlay geometry must remain anchored to the physical top edge"
    )
    runner.expect(narrowLayout.insetFromTop == 0, "overlay top anchoring must have no gap")

    let notchedScreen = CoveScreenMetrics(
        screenWidth: 1_512,
        screenHeight: 982,
        safeAreaTop: 32,
        auxiliaryTopLeftWidth: 663,
        auxiliaryTopRightWidth: 664
    )
    runner.expect(notchedScreen.topObstructionWidth == 185, "notch width must be derived")
    runner.expect(
        CoveOverlayGeometry.resolvedWidth(
            screen: notchedScreen,
            desiredWidth: 210
        ) == 245,
        "collapsed width must grow to notch width plus both cue gutters"
    )

    for (width, height, expanded) in [
        (210.0, 61.4, false),
        (400.0, 520.0, true),
        (520.0, 520.0, true),
    ] {
        let layout = CoveOverlayGeometry.layout(
            screen: notchedScreen,
            desiredWidth: width,
            desiredHeight: height,
            expanded: expanded
        )
        runner.expect(
            layout.originY + layout.height == notchedScreen.screenHeight,
            "\(width)x\(height) overlay must remain top anchored"
        )
        runner.expect(
            layout.originX >= notchedScreen.safeAreaLeft
                && layout.originX + layout.width
                    <= notchedScreen.screenWidth - notchedScreen.safeAreaRight,
            "\(width)x\(height) overlay must remain horizontally on screen"
        )
    }

    let zeroWidthScreen = CoveScreenMetrics(
        screenWidth: 100,
        screenHeight: 100,
        safeAreaTop: 0,
        safeAreaLeft: 50,
        safeAreaRight: 50
    )
    runner.expect(
        CoveOverlayGeometry.resolvedWidth(
            screen: zeroWidthScreen,
            desiredWidth: 400
        ) == 0,
        "width resolution must safely clamp when no horizontal space remains"
    )

    let genericTopLayout = CoveGeometryResolver.topCenterLayout(
        for: narrowScreen,
        desiredWidth: 520,
        desiredHeight: 100,
        topGap: 8
    )
    runner.expect(genericTopLayout.width == 284, "generic geometry must clamp width")
    runner.expect(
        genericTopLayout.originY + genericTopLayout.height
            == narrowScreen.screenHeight - narrowScreen.safeAreaTop - 8,
        "generic top-center layout must anchor below the safe-area top gap"
    )
    runner.expect(
        genericTopLayout.insetFromTop == 40,
        "generic layout must report its total top inset"
    )
}

private func testSilencedProjectRules(_ runner: inout FoundationTestRunner) {
    let normalized = CoveSilencedProjectRules.normalize([
        "  Alpha  ",
        "",
        "\n\t",
        "alpha",
        "BETA",
        " beta ",
        "Cafe\u{301}",
        "Caf\u{00E9}",
        "Gamma",
    ])
    runner.expect(
        normalized == ["Alpha", "BETA", "Cafe\u{301}", "Gamma"],
        "normalization must trim, remove empty tokens, canonically deduplicate, and preserve first spelling"
    )
    runner.expect(
        CoveSilencedProjectRules.containsEquivalent(normalized, to: "  aLpHa\n"),
        "equivalence lookup must ignore case and surrounding whitespace"
    )
    runner.expect(
        CoveSilencedProjectRules.containsEquivalent(normalized, to: "Caf\u{00E9}"),
        "equivalence lookup must use canonical Unicode mapping"
    )
    runner.expect(
        !CoveSilencedProjectRules.containsEquivalent(normalized, to: "   "),
        "an empty candidate must never match"
    )

    let overLimit = (0 ..< 125).map { "Project \($0)" }
    let limited = CoveSilencedProjectRules.normalize(overLimit)
    runner.expect(
        limited.count == CoveSilencedProjectRules.maximumCount,
        "normalization must enforce the 100-token maximum"
    )
    runner.expect(
        limited == Array(overLimit.prefix(100)),
        "the 100-token limit must preserve first-seen ordering"
    )
    runner.expect(
        CoveSilencedProjectRules.normalize(overLimit, maximumCount: 3)
            == ["Project 0", "Project 1", "Project 2"],
        "the explicit count limit must be honored"
    )
    runner.expect(
        CoveSilencedProjectRules.normalize(overLimit, maximumCount: 0).isEmpty,
        "a non-positive count limit must produce no rules"
    )
}

private func appendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

/// Generates a small, valid mono PCM WAV without relying on a checked-in media
/// fixture. The imported-sound test can therefore remain completely temporary.
private func fixtureWAVData(sampleCount: Int = 800) -> Data {
    let sampleRate: UInt32 = 8_000
    let dataSize = UInt32(sampleCount)
    var data = Data("RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataSize, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(8), to: &data)
    data.append(Data("data".utf8))
    appendLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: 128, count: sampleCount))
    return data
}

private func expectImportedSoundError(
    _ expected: CoveImportedSoundError,
    _ message: String,
    runner: inout FoundationTestRunner,
    operation: () throws -> Void
) {
    do {
        try operation()
        runner.expect(false, "\(message): operation unexpectedly succeeded")
    } catch let error as CoveImportedSoundError {
        runner.expect(
            error == expected,
            "\(message): expected \(expected), received \(error)"
        )
    } catch {
        runner.expect(
            false,
            "\(message): received unexpected error \(error)"
        )
    }
}

private func testImportedSoundOwnershipAndRemoval(
    _ runner: inout FoundationTestRunner
) {
    let fileManager = FileManager.default
    guard let temporaryBasePath = ProcessInfo.processInfo.environment[
        "COVE_IMPORTED_SOUND_TEST_ROOT"
    ] else {
        fatalError("COVE_IMPORTED_SOUND_TEST_ROOT is required")
    }
    let temporaryRoot = URL(
        fileURLWithPath: temporaryBasePath,
        isDirectory: true
    )
        .appendingPathComponent(
            "CodexCoveImportedSoundTests-\(UUID().uuidString)",
            isDirectory: true
        )
    do {
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        fatalError("Could not create imported-sound test directory: \(error)")
    }
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let sourceURL = temporaryRoot.appendingPathComponent("Fixture Tone.wav")
    let sourceData = fixtureWAVData()
    do {
        try sourceData.write(to: sourceURL, options: .atomic)
    } catch {
        fatalError("Could not write imported-sound WAV fixture: \(error)")
    }

    let storeRoot = temporaryRoot.appendingPathComponent(
        "Imported",
        isDirectory: true
    )
    let store = CoveImportedSoundStore(rootURL: storeRoot)
    let imported: CoveImportedSound
    do {
        imported = try store.importSound(from: sourceURL)
    } catch {
        fatalError(
            "Valid owned sound import failed at \(store.rootURL.path): \(error)"
        )
    }

    runner.expect(
        imported.displayName == "Fixture Tone",
        "import must preserve the source display name without its extension"
    )
    let listedSounds = try? store.list()
    runner.expect(
        listedSounds?.count == 1
            && listedSounds?.first?.id == imported.id
            && listedSounds?.first?.displayName == imported.displayName
            && listedSounds?.first?.storedFilename == imported.storedFilename,
        "the private manifest must list the successfully imported sound"
    )
    guard let ownedURL = store.url(for: imported.id) else {
        fatalError("The imported sound did not resolve through its owned manifest")
    }
    runner.expect(
        ownedURL.deletingLastPathComponent().standardizedFileURL
            == storeRoot.standardizedFileURL,
        "an imported sound must resolve only inside the private store root"
    )
    runner.expect(
        ownedURL.standardizedFileURL != sourceURL.standardizedFileURL,
        "import must copy rather than adopt the external source path"
    )
    runner.expect(
        (try? Data(contentsOf: ownedURL)) == sourceData,
        "the owned copy must retain the validated source bytes"
    )
    runner.expect(
        fileManager.fileExists(atPath: sourceURL.path),
        "import must preserve the external source file"
    )

    let rootAttributes: [FileAttributeKey: Any]
    let fileAttributes: [FileAttributeKey: Any]
    do {
        rootAttributes = try fileManager.attributesOfItem(atPath: storeRoot.path)
        fileAttributes = try fileManager.attributesOfItem(atPath: ownedURL.path)
    } catch {
        fatalError("Could not read owned imported-sound permissions: \(error)")
    }
    let rootMode = rootAttributes[.posixPermissions] as? NSNumber
    let fileMode = fileAttributes[.posixPermissions] as? NSNumber
    runner.expect(
        rootMode.map { $0.intValue & 0o777 } == 0o700,
        "the owned imported-sound directory must be mode 0700"
    )
    runner.expect(
        fileMode.map { $0.intValue & 0o777 } == 0o600,
        "an owned imported sound must be mode 0600"
    )

    expectImportedSoundError(
        .unknownSound,
        "removal must reject an identifier absent from the owned manifest",
        runner: &runner
    ) {
        try store.remove(id: UUID().uuidString.lowercased())
    }
    runner.expect(
        fileManager.fileExists(atPath: ownedURL.path)
            && fileManager.fileExists(atPath: sourceURL.path),
        "a rejected removal must preserve both owned and external files"
    )

    let linkedSource = temporaryRoot.appendingPathComponent("Linked Tone.wav")
    do {
        try fileManager.createSymbolicLink(
            at: linkedSource,
            withDestinationURL: sourceURL
        )
    } catch {
        fatalError("Could not create imported-sound symlink fixture: \(error)")
    }
    expectImportedSoundError(
        .invalidSource,
        "import must reject a symbolic-link source",
        runner: &runner
    ) {
        _ = try store.importSound(from: linkedSource)
    }
    runner.expect(
        (try? store.list())?.map(\.id) == [imported.id]
            && fileManager.fileExists(atPath: sourceURL.path),
        "a rejected symlink import must preserve manifest and source state"
    )

    let externalURL = temporaryRoot.appendingPathComponent("external.wav")
    let externalData = Data([0x43, 0x4F, 0x56, 0x45])
    let unsafeRoot = temporaryRoot.appendingPathComponent(
        "UnsafeImported",
        isDirectory: true
    )
    let unsafeID = UUID().uuidString.lowercased()
    let unsafeManifestURL = unsafeRoot.appendingPathComponent("manifest.json")
    let unsafeManifest: [String: Any] = [
        "schemaVersion": 1,
        "sounds": [[
            "id": unsafeID,
            "displayName": "External",
            "storedFilename": "../external.wav",
            "importedAt": "2026-08-01T12:00:00Z",
        ]],
    ]
    do {
        try externalData.write(to: externalURL, options: .atomic)
        try fileManager.createDirectory(
            at: unsafeRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let manifestData = try JSONSerialization.data(
            withJSONObject: unsafeManifest,
            options: [.sortedKeys]
        )
        try manifestData.write(to: unsafeManifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: unsafeManifestURL.path
        )
    } catch {
        fatalError("Could not create unsafe imported-sound manifest: \(error)")
    }
    let unsafeStore = CoveImportedSoundStore(rootURL: unsafeRoot)
    expectImportedSoundError(
        .unsafeStorage,
        "removal must reject a manifest entry that escapes the store root",
        runner: &runner
    ) {
        try unsafeStore.remove(id: unsafeID)
    }
    runner.expect(
        (try? Data(contentsOf: externalURL)) == externalData,
        "a traversal-shaped manifest entry must never delete or modify an external file"
    )
    runner.expect(
        unsafeStore.url(for: unsafeID) == nil,
        "an unsafe manifest path must never resolve as an owned sound URL"
    )

    do {
        try store.remove(id: imported.id)
    } catch {
        fatalError("Owned imported-sound removal failed: \(error)")
    }
    runner.expect(
        !fileManager.fileExists(atPath: ownedURL.path),
        "removal must delete the file owned by the private manifest"
    )
    runner.expect(
        (try? store.list())?.isEmpty == true && store.url(for: imported.id) == nil,
        "removal must delete the manifest entry and owned URL mapping"
    )
    runner.expect(
        (try? Data(contentsOf: sourceURL)) == sourceData,
        "owned removal must preserve the original external source"
    )
}

private func testNotificationPresentation(_ runner: inout FoundationTestRunner) {
    let kinds = CoveNotificationEventKind.allCases
    runner.expect(kinds.count == 6, "the notification matrix must contain six event kinds")

    let context = CoveNotificationDisplayContext(
        taskTitle: "Secret task",
        detail: "Private payload 9Z",
        project: "Secret project",
        source: "Remote CLI",
        host: "example-host"
    )

    var matrixEvaluationCount = 0
    for kind in kinds {
        for mask in 0 ..< 64 {
            let rule = CoveNotificationRule(
                enabled: mask & 1 != 0,
                includesTaskTitle: mask & 2 != 0,
                includesDetail: mask & 4 != 0,
                includesProject: mask & 8 != 0,
                includesSource: mask & 16 != 0,
                includesHost: mask & 32 != 0
            )
            let presentation = CoveNotificationPresentationBuilder.presentation(
                kind: kind,
                rule: rule,
                context: context,
                redactsSensitiveContent: false,
                count: 3,
                genericBodyWhenEmpty: "Generic body"
            )
            let expectedTitle = rule.includesTaskTitle
                ? "Secret task"
                : CoveNotificationPresentationBuilder.genericTitle(for: kind)
            var expectedBody = ["3 related requests"]
            if rule.includesDetail { expectedBody.append("Private payload 9Z") }
            if rule.includesProject { expectedBody.append("Project: Secret project") }
            if rule.includesSource { expectedBody.append("Remote CLI") }
            if rule.includesHost { expectedBody.append("Host: example-host") }

            runner.expect(
                presentation.title == expectedTitle,
                "\(kind.rawValue) mask \(mask) resolved the wrong title"
            )
            runner.expect(
                presentation.body == expectedBody.joined(separator: " · "),
                "\(kind.rawValue) mask \(mask) resolved the wrong body"
            )

            for count in [1, 4] {
                let redacted = CoveNotificationPresentationBuilder.presentation(
                    kind: kind,
                    rule: rule,
                    context: context,
                    fallbackTitle: "Fallback secret",
                    fallbackDetail: "Fallback detail",
                    redactsSensitiveContent: true,
                    count: count,
                    genericBodyWhenEmpty: "Generic body"
                )
                runner.expect(
                    redacted.title == (count > 1
                        ? "\(count) Codex tasks need attention"
                        : CoveNotificationPresentationBuilder.genericTitle(for: kind)),
                    "redaction must hide task titles for \(kind.rawValue), mask \(mask), count \(count)"
                )
                runner.expect(
                    redacted.body == "Sensitive details are hidden by Codex Cove privacy.",
                    "redaction must hide all body fields for \(kind.rawValue), mask \(mask), count \(count)"
                )
                runner.expect(
                    !redacted.title.contains("Secret")
                        && !redacted.body.contains("Private payload 9Z")
                        && !redacted.body.contains("Secret project")
                        && !redacted.body.contains("Remote CLI")
                        && !redacted.body.contains("example-host"),
                    "redaction leaked sensitive notification context"
                )
            }
            matrixEvaluationCount += 1
        }
    }
    runner.expect(
        matrixEvaluationCount == 384,
        "expected 384 notification kind/rule evaluations"
    )

    let emptyRule = CoveNotificationRule(
        enabled: true,
        includesTaskTitle: true,
        includesDetail: true,
        includesProject: true,
        includesSource: true,
        includesHost: true
    )
    let fallback = CoveNotificationPresentationBuilder.presentation(
        kind: .input,
        rule: emptyRule,
        context: CoveNotificationDisplayContext(
            taskTitle: "  ",
            detail: "\n",
            project: " ",
            source: nil,
            host: nil
        ),
        fallbackTitle: " Fallback title ",
        fallbackDetail: " Fallback detail ",
        redactsSensitiveContent: false,
        genericBodyWhenEmpty: "Generic body"
    )
    runner.expect(fallback.title == "Fallback title", "title fallback must trim whitespace")
    runner.expect(fallback.body == "Fallback detail", "detail fallback must trim whitespace")

    var preferences = CoveNotificationPreferences()
    for (index, kind) in kinds.enumerated() {
        let uniqueRule = CoveNotificationRule(
            enabled: index.isMultiple(of: 2),
            includesTaskTitle: index & 1 != 0,
            includesDetail: index & 2 != 0,
            includesProject: index & 4 != 0,
            includesSource: index == 4,
            includesHost: index == 5
        )
        preferences.set(uniqueRule, for: kind)
        runner.expect(
            preferences.rule(for: kind) == uniqueRule,
            "notification preferences must round-trip the \(kind.rawValue) row"
        )
    }
}

private func testActionDraftsAndDirtyExit(_ runner: inout FoundationTestRunner) {
    let request = approvalRequest()
    let key = request.key
    let otherKey = approvalRequest(
        id: .integer(1),
        launchID: "launch-2",
        sessionID: "session-2",
        turnID: "turn-2"
    ).key
    let choice = CoveChoice(identifier: "accept", label: "Allow once")

    for (decision, requiresConfirmation, scopeLabel) in [
        (CoveApprovalDecision.accept, true, "Allow once"),
        (.acceptForSession, true, "Allow for this task"),
        (.decline, false, nil),
        (.cancel, false, nil),
    ] {
        let draft = CoveApprovalDraft(choice: choice, decision: decision)
        runner.expect(
            draft.requiresConfirmation == requiresConfirmation,
            "\(decision.rawValue) confirmation staging is wrong"
        )
        runner.expect(
            draft.scopeLabel == scopeLabel,
            "\(decision.rawValue) scope label is wrong"
        )
    }

    var drafts = CoveActionDraftState()
    runner.expect(!drafts.hasDirtyDrafts, "a new draft store must be clean")
    runner.expect(
        CoveDirtyExitDisposition.resolve(requestKey: key, drafts: drafts) == .exit,
        "a request with no draft must exit immediately"
    )

    drafts.setQuestionAnswers(["q1": ["", "  "]], for: key)
    runner.expect(!drafts.isDirty(key), "blank question answers must remain clean")
    drafts.setQuestionAnswer(["Answer"], questionID: "q1", for: key)
    runner.expect(drafts.isDirty(key), "a non-empty question answer must become dirty")
    runner.expect(
        drafts.question(for: key)?.answers == ["q1": ["Answer"]],
        "question answers must remain keyed by request and question"
    )
    runner.expect(
        CoveDirtyExitDisposition.resolve(requestKey: key, drafts: drafts)
            == .confirmDiscard(key),
        "leaving a dirty question must require discard confirmation"
    )
    runner.expect(
        CoveDirtyExitDisposition.resolve(requestKey: nil, drafts: drafts) == .exit,
        "an unrelated exit without a focused request must remain available"
    )

    let approvalDraft = CoveApprovalDraft(choice: choice, decision: .accept)
    drafts.setApproval(approvalDraft, for: otherKey)
    runner.expect(
        drafts.approval(for: otherKey) == approvalDraft,
        "approval drafts must remain isolated by the complete request key"
    )
    runner.expect(
        drafts.dirtyRequestKeys == Set([key, otherKey]),
        "dirty identities must include both independent action drafts"
    )
    drafts.retain(keys: [otherKey])
    runner.expect(drafts[key] == nil, "retain must discard requests no longer live")
    runner.expect(drafts.isDirty(otherKey), "retain must preserve a live dirty draft")
    drafts.clear(otherKey)
    runner.expect(!drafts.hasDirtyDrafts, "clearing the last draft must restore clean state")
}

private func testDecisionDeliveryLifecycle(_ runner: inout FoundationTestRunner) {
    let request = approvalRequest()
    let key = request.key
    let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let staleID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let firstAttempt = CoveDecisionAttempt(
        attemptID: firstID,
        request: request,
        frame: decisionFrame(),
        socketPath: "/tmp/codex-cove-foundation.sock"
    )

    var delivery = CoveDecisionDeliveryState()
    runner.expect(delivery.canBeginSending(key), "an unseen request must be sendable")
    delivery.setStaged(key)
    runner.expect(delivery.isStaged(key), "positive action must enter staged state")
    runner.expect(delivery.canBeginSending(key), "a staged action must be confirmable")
    delivery.setSending(firstAttempt)
    runner.expect(delivery.isSending(key), "confirmation must enter sending state")
    runner.expect(
        delivery.isSending(key, attemptID: firstID),
        "sending state must retain its exact attempt identity"
    )
    runner.expect(!delivery.canBeginSending(key), "single-flight must block duplicate sends")

    delivery.setSucceeded(key, attemptID: staleID)
    runner.expect(delivery.isSending(key), "a stale success must not finish the live attempt")
    let staleAttempt = CoveDecisionAttempt(
        attemptID: staleID,
        request: request,
        frame: decisionFrame(),
        socketPath: "/tmp/stale.sock"
    )
    delivery.setFailed(staleAttempt, message: "stale failure")
    runner.expect(delivery.isSending(key), "a stale failure must not replace the live attempt")

    delivery.setFailed(firstAttempt, message: "socket unavailable")
    runner.expect(
        delivery.errorMessage(for: key) == "socket unavailable",
        "delivery failure must remain visible"
    )
    runner.expect(
        delivery.retryAttempt(for: key) == firstAttempt,
        "delivery failure must retain the immutable retry payload"
    )
    runner.expect(delivery.canBeginSending(key), "a failed request must permit retry")

    let retryAttempt = firstAttempt.renewed()
    runner.expect(
        retryAttempt.attemptID != firstAttempt.attemptID,
        "retry must receive a fresh attempt identity"
    )
    runner.expect(
        retryAttempt.request == firstAttempt.request
            && retryAttempt.frame == firstAttempt.frame
            && retryAttempt.socketPath == firstAttempt.socketPath,
        "retry must preserve the exact request, frame, and socket payload"
    )
    delivery.setSending(retryAttempt)
    delivery.setSucceeded(key, attemptID: retryAttempt.attemptID)
    runner.expect(delivery.isSucceeded(key), "the matching retry write must succeed")
    runner.expect(!delivery.canBeginSending(key), "a written request must not resend")
    delivery.setStaged(key)
    runner.expect(delivery.isSucceeded(key), "staging must not regress a successful write")

    delivery.clear(key)
    runner.expect(delivery.status(for: key) == nil, "clear must remove terminal delivery state")
}

private var runner = FoundationTestRunner()

print("Running Milestone 1 semantic typography tests…")
testSemanticTypography(&runner)
print("Running Milestone 1 enforced contrast matrix tests…")
testContrastMatrix(&runner)
print("Running overlay geometry tests…")
testGeometry(&runner)
print("Running Milestone 3 silenced-project normalization tests…")
testSilencedProjectRules(&runner)
print("Running Milestone 3 imported-sound ownership and removal tests…")
testImportedSoundOwnershipAndRemoval(&runner)
print("Running Milestone 3 notification rule and redaction matrix tests…")
testNotificationPresentation(&runner)
print("Running Milestone 1 action draft and dirty-exit tests…")
testActionDraftsAndDirtyExit(&runner)
print("Running Milestone 1 decision delivery lifecycle tests…")
testDecisionDeliveryLifecycle(&runner)

print("Milestone 1/3 foundation tests passed (\(runner.assertionCount) assertions)")
