import Foundation
import AppKit
import CoreGraphics
import XCTest

/// End-to-end acceptance coverage for the deterministic UI-test host.
///
/// Every test launches with a new mode-0700 state directory. The production
/// bundle ignores these launch arguments; only the dedicated UI-test host can
/// opt into fixtures and the in-memory decision sender.
final class CodexCoveUITests: XCTestCase {
    private var stateDirectory: URL!
    private var launchedApplications: [XCUIApplication] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexCoveUITests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        for application in launchedApplications.reversed() {
            if application.state != .notRunning {
                application.terminate()
            }
        }
        launchedApplications.removeAll()
        if let stateDirectory {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    // MARK: - Fixture isolation and queue acceptance

    @MainActor
    func testEmptyQueueFixtureLaunchesInIsolation() throws {
        let app = launchFixture("empty-queue")
        let overlay = element("cove.overlay", in: app)
        XCTAssertTrue(
            overlay.waitForExistence(timeout: 5),
            "The deterministic fixture overlay should launch"
        )

        let stateMarker = element("cove.fixture.state-directory", in: app)
        XCTAssertTrue(stateMarker.waitForExistence(timeout: 2))
        XCTAssertEqual(stringValue(of: stateMarker), stateDirectory.path)
        XCTAssertEqual(decisionAttemptCount(in: app), 0)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: stateDirectory.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o700)
    }

    @MainActor
    func testCollapsedIslandIsAnAccessibleExpandButton() {
        let app = launchFixture("collapsed-cue")
        let expand = app.buttons["cove.overlay.expand"].firstMatch
        let collapse = app.buttons["cove.overlay.collapse"].firstMatch

        // Launching under XCUITest can place the pointer over the island and
        // legitimately trigger its hover expansion. Normalize before checking AX.
        if collapse.waitForExistence(timeout: 2) {
            collapse.click()
        }

        XCTAssertTrue(
            expand.waitForExistence(timeout: 5),
            "The collapsed island must expose a stable AX button"
        )
        XCTAssertEqual(expand.label, "Open task queue")
        XCTAssertTrue(expand.isEnabled)
        XCTAssertTrue(expand.isHittable)

        expand.click()
        XCTAssertTrue(
            text("Queue", in: app).waitForExistence(timeout: 3),
            "The collapsed AX action must expand the task queue"
        )
    }

    @MainActor
    func testCollapsedIslandTransmitsBackdrop() throws {
        try XCTSkipIf(
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "Reduce Transparency intentionally replaces the native backdrop"
        )
        let originalCursorLocation = CGEvent(source: nil)?.location
        defer {
            if let originalCursorLocation {
                _ = CGWarpMouseCursorPosition(originalCursorLocation)
            }
        }
        movePointerAwayFromCove()
        let lightBackdrop = collapsedSurfaceColor(backdrop: "white")
        let darkBackdrop = collapsedSurfaceColor(backdrop: "black")
        XCTAssertGreaterThan(
            colorDistance(lightBackdrop, darkBackdrop),
            0.08,
            "A translucent island must preserve visible contrast from content behind it"
        )
    }

    @MainActor
    func testMinimalMenuBarCueRestoresCove() {
        let app = launchFixture("minimal-cue")
        let restore = app.buttons["cove.overlay.restore-island"].firstMatch
        XCTAssertTrue(
            restore.waitForExistence(timeout: 5),
            "Minimal mode must leave a clickable menu-bar cue"
        )
        XCTAssertTrue(restore.isHittable)
        if let screen = NSScreen.main {
            let menuBarHeight = max(
                screen.safeAreaInsets.top,
                screen.frame.maxY - screen.visibleFrame.maxY
            )
            XCTAssertEqual(
                restore.frame.height,
                max(24, menuBarHeight),
                accuracy: 1,
                "The minimal cue must match the active display's menu-bar height"
            )
        }

        restore.click()
        XCTAssertTrue(
            text("Queue", in: app).waitForExistence(timeout: 3),
            "Clicking the menu-bar cue must restore Cove"
        )
        XCTAssertFalse(restore.exists)
    }

    @MainActor
    func testQueueHasExactlyOneScrollOwner() {
        let app = launchFixture("mixed-20")
        let overlay = element("cove.overlay", in: app)
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Queue", in: app).waitForExistence(timeout: 3))

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                overlay.descendants(matching: .scrollView).count == 1
            },
            "The expanded queue must expose one, and only one, scroll owner"
        )
        XCTAssertEqual(
            overlay.descendants(matching: .scrollView).count,
            1,
            "Nested session/request scrollers make the attention queue unusable"
        )
        XCTAssertTrue(element("cove.queue.scroll", in: app).exists)
    }

    @MainActor
    func testOnlyWaitingTaskIsDiscoverableWithinFiveSeconds() {
        let app = launchFixture("mixed-20")
        let waitingRow = element(taskQueueRowIdentifier("fixture-task-3"), in: app)
        // Measure the in-app discovery path, not XCTest's cold process launch,
        // Accessibility loading, or automation-session bootstrap.
        let startedAt = Date()

        XCTAssertTrue(
            waitingRow.waitForExistence(timeout: 5),
            "The only waiting task must be visible without opening More or scrolling"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            5,
            "The canonical 20-task fixture must reveal the waiting task in under five seconds"
        )
        XCTAssertEqual(
            waitingRow.label,
            "Waiting for approval, Only waiting approval"
        )

        let waitingRows = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Waiting for approval,"
            )
        )
        XCTAssertEqual(waitingRows.count, 1)
    }

    @MainActor
    func testPrivacyRedactsVisibleAndAccessibilityCopy() {
        let app = launchFixture("privacy-redacted")
        let request = RequestIdentity(requestID: "fixture-approval")
        let overlay = element("cove.overlay", in: app)
        let row = element(request.identifier("queue-row"), in: app)

        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "Waiting for approval, Codex task")
        assertNoSensitiveAccessibilityCopy(in: overlay)

        openFocusedRequest(request, in: app)
        assertNoSensitiveAccessibilityCopy(in: overlay)
    }

    @MainActor
    func testPrivacyOffDoesNotRedactForHiddenSessionStatus() {
        let app = launchFixture("privacy-off-hidden-status")
        let request = RequestIdentity(requestID: "fixture-approval")
        let row = element(request.identifier("queue-row"), in: app)

        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(
            row.label,
            "Waiting for approval, Review fixture command approval"
        )

        openFocusedRequest(request, in: app)
        XCTAssertTrue(
            element(request.identifier("consequence"), in: app)
                .waitForExistence(timeout: 2),
            "Privacy Off must keep approval details visible"
        )

        app.terminate()
        XCTAssertTrue(waitUntil(timeout: 2) { app.state == .notRunning })

        let recoveryApp = launchFixture("privacy-off-locked-workspace")
        XCTAssertTrue(
            element("cove.overlay", in: recoveryApp).waitForExistence(timeout: 5)
        )
        recoveryApp.typeKey("w", modifierFlags: [.command, .shift])
        let workspace = recoveryApp.windows["Codex Cove Workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        let card = workspace.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.card."
            )
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        XCTAssertTrue(card.label.contains("Fixture task 1"))
        XCTAssertFalse(element("cove.workspace.privacy-reason", in: recoveryApp).exists)
    }

    @MainActor
    func testQueueSelectionOpenFocusAndVisibleOverflowActions() {
        let app = launchFixture("mixed-20")
        let waitingRow = element(taskQueueRowIdentifier("fixture-task-3"), in: app)
        XCTAssertTrue(waitingRow.waitForExistence(timeout: 5))

        XCTAssertEqual(jumpCount(in: app), 0)
        waitingRow.click()
        XCTAssertTrue(
            app.windows["Codex Cove Workspace"].waitForExistence(timeout: 2),
            "A primary row click must select the owning task in Workspace"
        )
        element("cove.workspace.close", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.element("cove.queue.scroll", in: app).exists
        })
        for (identifier, label) in [
            ("cove.queue.previous", "Select previous task"),
            ("cove.queue.next", "Select next task"),
        ] {
            let navigationControl = element(identifier, in: app)
            XCTAssertTrue(navigationControl.waitForExistence(timeout: 2))
            XCTAssertEqual(navigationControl.label, label)
        }
        let openSelected = element("cove.queue.open-in-codex", in: app)
        XCTAssertTrue(openSelected.waitForExistence(timeout: 2))
        XCTAssertTrue(openSelected.isEnabled)

        let actions = element(
            taskControlIdentifier("fixture-task-3", control: "queue-actions"),
            in: app
        )
        XCTAssertTrue(actions.waitForExistence(timeout: 2))
        actions.click()
        let overflowActions = [
            (label: "Open in Codex", control: "queue-action-open-in-codex"),
            (label: "Pin", control: "queue-action-pin"),
            (label: "Remind Me", control: "queue-action-reminder"),
            (label: "Mark Read", control: "queue-action-mark-read"),
            (label: "Archive", control: "queue-action-archive"),
        ]
        for action in overflowActions {
            let menuAction = element(
                taskControlIdentifier(
                    "fixture-task-3",
                    control: action.control
                ),
                in: app
            )
            XCTAssertTrue(
                menuAction.waitForExistence(timeout: 2),
                "The row overflow menu must visibly expose \(action.label)"
            )
            XCTAssertEqual(menuAction.title, action.label)
        }
        element(
            taskControlIdentifier(
                "fixture-task-3",
                control: "queue-action-open-in-codex"
            ),
            in: app
        ).click()
        XCTAssertTrue(
            waitUntil(timeout: 2) { self.jumpCount(in: app) == 1 },
            "The explicit overflow action must retain exact Codex routing"
        )
        actions.click()
        XCTAssertTrue(
            element(
                taskControlIdentifier(
                    "fixture-task-3",
                    control: "queue-action-pin"
                ),
                in: app
            ).waitForExistence(timeout: 2)
        )
        element(
            taskControlIdentifier(
                "fixture-task-3",
                control: "queue-action-pin"
            ),
            in: app
        ).click()

        waitingRow.rightClick()
        for action in overflowActions {
            let contextAction = element(
                taskControlIdentifier(
                    "fixture-task-3",
                    control: action.control
                ),
                in: app
            )
            XCTAssertTrue(
                contextAction.waitForExistence(timeout: 2),
                "Right-click must expose \(action.label) without opening details"
            )
        }
        app.typeKey(.escape, modifierFlags: [])

        let focus = element(
            taskControlIdentifier("fixture-task-3", control: "queue-focus"),
            in: app
        )
        XCTAssertTrue(focus.waitForExistence(timeout: 2))
        focus.click()
        XCTAssertTrue(
            element("cove.overlay.collapse", in: app)
                .waitForExistence(timeout: 3),
            "Details should move the selected row into the focused 520-point surface"
        )
        let overlay = element("cove.overlay", in: app)
        XCTAssertGreaterThanOrEqual(overlay.frame.width, 510)
        XCTAssertLessThanOrEqual(overlay.frame.width, 530)

        let focusedOpen = element(
            taskControlIdentifier(
                "fixture-task-3",
                control: "focused-open-in-codex"
            ),
            in: app
        )
        XCTAssertTrue(focusedOpen.waitForExistence(timeout: 2))
        XCTAssertEqual(focusedOpen.label, "Open in Codex")
        focusedOpen.click()
        XCTAssertTrue(overlay.exists)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            element("cove.queue.scroll", in: app)
                .waitForExistence(timeout: 3),
            "Escape must return focused detail to the keyboard-operable queue"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                !self.element("cove.queue.scroll", in: app).exists
                    && overlay.frame.width < 400
            },
            "A second Escape must collapse the queue"
        )
    }

    @MainActor
    func testOpenFailureIsVisibleAndAccessible() {
        let app = launchFixture("open-failure")
        let row = element(taskQueueRowIdentifier("fixture-task-1"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        row.rightClick()
        let openInCodex = element(
            taskControlIdentifier(
                "fixture-task-1",
                control: "queue-action-open-in-codex"
            ),
            in: app
        )
        XCTAssertTrue(openInCodex.waitForExistence(timeout: 2))
        openInCodex.click()

        let feedback = element("cove.session-open-failure", in: app)
        XCTAssertTrue(
            feedback.waitForExistence(timeout: 2),
            "A failed exact-origin jump must explain why Open did not navigate"
        )
        XCTAssertTrue(
            [feedback.label, stringValue(of: feedback)]
                .joined(separator: " ")
                .contains(
                    "The exact originating Codex location is not currently available."
                ),
            "The visible failure must expose its explanation to accessibility"
        )
        XCTAssertEqual(jumpCount(in: app), 1)
    }

    @MainActor
    func testQueueSectionsCollapseReorderAndArchiveCompleted() {
        let app = launchFixture("mixed-20")
        let attentionHeader = element(
            "cove.queue.section.needs-attention.toggle",
            in: app
        )
        let activeHeader = element(
            "cove.queue.section.active.toggle",
            in: app
        )
        XCTAssertTrue(attentionHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(activeHeader.waitForExistence(timeout: 5))
        XCTAssertLessThan(attentionHeader.frame.minY, activeHeader.frame.minY)

        let reorderActive = element(
            "cove.queue.section.active.reorder",
            in: app
        )
        XCTAssertTrue(reorderActive.waitForExistence(timeout: 2))
        reorderActive.click()
        let moveUp = app.menuItems["Move Up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 2))
        moveUp.click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(
                    of: self.element(
                        "cove.fixture.queue-section-order",
                        in: app
                    )
                ) == "1,0,2,3"
            },
            "Section reorder must persist immediately in the queue"
        )

        let activeRow = element(
            taskQueueRowIdentifier("fixture-task-1"),
            in: app
        )
        XCTAssertTrue(activeRow.waitForExistence(timeout: 2))
        let activeToggle = element(
            "cove.queue.section.active.toggle",
            in: app
        )
        activeToggle.click()
        XCTAssertTrue(
            waitUntil(timeout: 2) { !activeRow.exists },
            "Collapsing Active must hide its task rows"
        )
        activeToggle.click()
        XCTAssertTrue(activeRow.waitForExistence(timeout: 2))

        let archiveCompleted = element(
            "cove.queue.archive-all-completed",
            in: app
        )
        let queueScroll = element("cove.queue.scroll", in: app)
        for _ in 0..<8 where !archiveCompleted.isHittable {
            queueScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(archiveCompleted.isHittable)
        archiveCompleted.click()
        XCTAssertTrue(
            waitUntil(timeout: 2) { !archiveCompleted.exists },
            "Bulk archive must disappear after all completed tasks are archived"
        )
        XCTAssertTrue(
            element(taskQueueRowIdentifier("fixture-task-8"), in: app).exists,
            "Bulk completed archive must retain failed tasks"
        )
        XCTAssertFalse(
            element(taskQueueRowIdentifier("fixture-task-7"), in: app).exists,
            "Bulk completed archive must remove completed tasks"
        )
    }

    // MARK: - Workspace window, organization, and library

    @MainActor
    func testWorkspaceIsPrimaryOnDirectLaunch() {
        let app = launchFixture("workspace-primary")
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "A deliberate launch must open the primary Workspace window"
        )
        XCTAssertEqual(fixtureRunningApplication()?.activationPolicy, .regular)
        XCTAssertEqual(
            app.windows.descendants(matching: .any)
                .matching(identifier: "cove.workspace").count,
            1
        )
    }

    @MainActor
    func testWorkspaceCardShowsNestedAgentOutputAsItArrives() {
        let app = launchFixture("workspace-primary")
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let rootCard = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture parent task")
        ).firstMatch
        XCTAssertTrue(rootCard.waitForExistence(timeout: 2))
        XCTAssertTrue(stringValue(of: rootCard).contains("Initial child output"))
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                self.stringValue(of: rootCard).contains("live update arrived")
            },
            "The owning card must update when its nested agent streams output"
        )
    }

    @MainActor
    func testWorkspaceTargetsNestedAgentsAndNewTopLevelTasks() {
        let app = launchFixture("workspace-primary")
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let rootCard = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture parent task")
        ).firstMatch
        XCTAssertTrue(rootCard.waitForExistence(timeout: 2))
        rootCard.click()

        let inspector = element("cove.workspace.inspector", in: app)
        XCTAssertTrue(inspector.waitForExistence(timeout: 2))
        let inspectorScroll = inspector.scrollViews.firstMatch
        selectWorkspaceAgent(
            "Idle child agent",
            rootCard: rootCard,
            window: window,
            scrollView: inspectorScroll,
            app: app
        )
        XCTAssertTrue(stringValue(of: rootCard).hasPrefix("Selected"))
        XCTAssertTrue(text("Idle child agent", in: app).exists)

        let composer = element("cove.workspace.composer", in: app)
        for _ in 0..<8 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(composer.isHittable)
        composer.click()
        composer.typeText("Start the child again.")
        let send = element("cove.workspace.send", in: app)
        XCTAssertEqual(send.label, "Start Turn")
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertTrue(text("Send this prompt to Idle child agent?", in: app).exists)
        element("cove.workspace.confirm-send", in: app).click()
        XCTAssertTrue(text("Turn started.", in: app).waitForExistence(timeout: 2))
        XCTAssertEqual(
            threadControl(in: app),
            "localCli||fixture-agent-idle|start|"
        )

        selectWorkspaceAgent(
            "Active child agent",
            rootCard: rootCard,
            window: window,
            scrollView: inspectorScroll,
            app: app
        )
        let activeSend = element("cove.workspace.send", in: app)
        XCTAssertTrue(waitUntil(timeout: 2) {
            activeSend.label == "Steer Active Turn"
        })
        for _ in 0..<8 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        composer.click()
        composer.typeText("Steer the exact child.")
        XCTAssertTrue(activeSend.isEnabled)
        activeSend.click()
        XCTAssertTrue(text("Send this prompt to Active child agent?", in: app).exists)
        element("cove.workspace.confirm-send", in: app).click()
        XCTAssertTrue(
            text("Prompt steered to the active turn.", in: app)
                .waitForExistence(timeout: 2)
        )
        XCTAssertEqual(
            threadControl(in: app),
            "localCli||fixture-agent-active|steer|fixture-child-turn"
        )

        selectWorkspaceAgent(
            "Missing-turn child agent",
            rootCard: rootCard,
            window: window,
            scrollView: inspectorScroll,
            app: app
        )
        for _ in 0..<8 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        composer.click()
        composer.typeText("Must remain disabled.")
        XCTAssertFalse(element("cove.workspace.send", in: app).isEnabled)
        XCTAssertTrue(
            text(
                "Cove does not have the exact active turn ID. Open the task in Codex to continue.",
                in: app
            ).exists
        )

        selectWorkspaceAgent(
            "Pending child agent",
            rootCard: rootCard,
            window: window,
            scrollView: inspectorScroll,
            app: app
        )
        for _ in 0..<12 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        composer.click()
        composer.typeText("Must wait for approval.")
        XCTAssertFalse(element("cove.workspace.send", in: app).isEnabled)
        XCTAssertTrue(
            text(
                "Resolve this agent's approval or question before sending a prompt.",
                in: app
            ).exists
                || text(
                    "Resolve this agent's pending approval or question before sending a prompt.",
                    in: app
                ).exists
        )

        let open = app.buttons["Open in Codex"].firstMatch
        for _ in 0..<8 where !open.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(open.isHittable)
        open.click()
        XCTAssertEqual(jumpCount(in: app), 1)

        let topLevelCard = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "New top-level task")
        ).firstMatch
        XCTAssertTrue(topLevelCard.waitForExistence(timeout: 2))
        topLevelCard.click()
        XCTAssertTrue(text("New top-level task", in: app).waitForExistence(timeout: 2))
        for _ in 0..<8 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        composer.click()
        composer.typeText("Start the new task.")
        let topLevelSend = element("cove.workspace.send", in: app)
        XCTAssertEqual(topLevelSend.label, "Start Turn")
        XCTAssertTrue(topLevelSend.isEnabled)
        topLevelSend.click()
        element("cove.workspace.confirm-send", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.threadControl(in: app)
                == "codexDesktop||fixture-new-top-level|start|"
        })
    }

    @MainActor
    func testWorkspaceAgentOpenFailureOffersVerifiedParent() {
        let app = launchFixture("workspace-agent-open-fallback")
        XCTAssertTrue(element("cove.overlay", in: app).waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: [.command, .shift])
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let rootCard = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Openable parent task")
        ).firstMatch
        rootCard.click()
        let disclosure = window.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.agent.disclosure."
            )
        ).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 2))
        XCTAssertEqual(
            disclosure.label,
            "Expand child agents for Openable parent task"
        )
        disclosure.click()
        let child = app.buttons["Inspect Unavailable child location"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 2))
        child.click()
        let inspector = element("cove.workspace.inspector", in: app)
        let inspectorScroll = inspector.scrollViews.firstMatch
        let open = app.buttons["Open in Codex"].firstMatch
        for _ in 0..<12 where !open.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(open.isHittable)
        open.click()
        XCTAssertTrue(
            element("cove.session-open-failure", in: app)
                .waitForExistence(timeout: 2)
        )
        let openParent = element("cove.workspace.open-parent", in: app)
        XCTAssertTrue(openParent.waitForExistence(timeout: 2))
        XCTAssertEqual(jumpCount(in: app), 1)
        openParent.click()
        XCTAssertTrue(waitUntil(timeout: 2) { self.jumpCount(in: app) == 2 })
        XCTAssertFalse(element("cove.session-open-failure", in: app).exists)
    }

    @MainActor
    func testWorkspaceCombinesParentAndChildArtifactOrder() {
        let app = launchFixture("workspace-primary")
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let rootCard = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture parent task")
        ).firstMatch
        rootCard.click()
        let inspector = element("cove.workspace.inspector", in: app)
        let scroll = inspector.scrollViews.firstMatch
        let labels = window.textFields.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.artifact.label."
            )
        )
        for _ in 0..<10 where labels.count < 2 || !labels.firstMatch.isHittable {
            scroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(stringValue(of: labels.firstMatch), "Child artifact")
        XCTAssertEqual(stringValue(of: labels.element(boundBy: 1)), "Parent artifact")

        let artifactRows = window.groups.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.artifact.row."
            )
        )
        XCTAssertEqual(artifactRows.count, 2)
        let dragSource = artifactRows.element(boundBy: 1).coordinate(
            withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)
        )
        let dragDestination = artifactRows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        dragSource.click(
            forDuration: 0.6,
            thenDragTo: dragDestination,
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: labels.firstMatch) == "Parent artifact"
        })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: labels.firstMatch) == "Child artifact"
        })
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: labels.firstMatch) == "Parent artifact"
        })
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: labels.firstMatch) == "Child artifact"
        })
    }

    @MainActor
    func testWorkspaceFaviconRowsCardsFallbackAndSuggestionsStayOffline() {
        let app = launchFixture("workspace-favicon")
        XCTAssertTrue(element("cove.overlay", in: app).waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: [.command, .shift])
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let card = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Favicon fixture task")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.click()

        let inspector = element("cove.workspace.inspector", in: app)
        let scroll = inspector.scrollViews.firstMatch
        let labels = window.textFields.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.artifact.label."
            )
        )
        for _ in 0..<10 where labels.count < 2 || !labels.firstMatch.isHittable {
            scroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertEqual(labels.count, 2)
        XCTAssertTrue(text("suggestion-favicon.com", in: app).waitForExistence(timeout: 2))

        XCTAssertTrue(waitUntil(timeout: 2) {
            let value = self.fixtureFaviconStates()
            return [
                "card:loaded-favicon.com=loaded",
                "row:loaded-favicon.com=loaded",
                "card:fallback-favicon.com=fallback",
                "row:fallback-favicon.com=fallback",
            ].allSatisfy(value.contains)
        })
        XCTAssertFalse(fixtureFaviconStates().contains("suggestion-favicon.com"))
        XCTAssertEqual(
            app.images.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "favicon")
            ).count,
            0,
            "Artifact favicons must remain decorative in Accessibility."
        )
    }

    @MainActor
    func testWorkspacePrivacyDoesNotRenderOrFetchFavicons() {
        let app = launchFixture("workspace-favicon-privacy")
        XCTAssertTrue(element("cove.overlay", in: app).waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: [.command, .shift])
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let card = window.buttons.matching(
            identifier: "cove.workspace.card.redacted"
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.click()

        XCTAssertFalse(text("Loaded favicon", in: app).exists)
        XCTAssertFalse(text("Fallback favicon", in: app).exists)
        XCTAssertFalse(text("suggestion-favicon.com", in: app).exists)
        XCTAssertFalse(
            element("cove.workspace.artifact.label.loaded-favicon.com", in: app).exists
        )
        XCTAssertEqual(fixtureFaviconStates(), "")
    }

    @MainActor
    func testWorkspaceStartsCompletedHookOnlyLocalTask() {
        let app = launchFixture("mixed-20")
        XCTAssertTrue(element("cove.overlay", in: app).waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: [.command, .shift])
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let card = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture task 7")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.click()

        let composer = element("cove.workspace.composer", in: app)
        let inspectorScroll = element("cove.workspace.inspector", in: app)
            .scrollViews.firstMatch
        for _ in 0..<8 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(
            text(
                "Cove will verify and resume this local task with Codex before starting the turn.",
                in: app
            ).waitForExistence(timeout: 2)
        )
        composer.click()
        composer.typeText("Continue the completed local task.")
        let send = element("cove.workspace.send", in: app)
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertTrue(
            text("Send this prompt to Fixture task 7?", in: app)
                .waitForExistence(timeout: 2)
        )
        element("cove.workspace.confirm-send", in: app).click()
        XCTAssertTrue(text("Turn started.", in: app).waitForExistence(timeout: 2))
    }

    @MainActor
    func testWorkspaceGridBoardInspectorAndLibrary() {
        let app = launchFixture("mixed-20")
        XCTAssertTrue(element("cove.overlay", in: app).waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: [.command, .shift])
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 5),
            "The Workspace command must open one reusable native window"
        )
        XCTAssertGreaterThanOrEqual(window.frame.width, 900)
        XCTAssertGreaterThanOrEqual(window.frame.height, 600)
        XCTAssertTrue(element("cove.workspace", in: app).exists)
        XCTAssertTrue(
            element("cove.workspace.help", in: app).exists,
            "Workspace must expose its help documentation from the toolbar"
        )
        let appearance = element("cove.workspace.appearance", in: app)
        XCTAssertTrue(appearance.exists)
        appearance.click()
        XCTAssertTrue(app.menuItems["Follow System"].waitForExistence(timeout: 2))
        app.menuItems["Light"].click()
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: appearance) == "Light"
        })
        let lightSurface = sampledSurfaceColor(from: window.screenshot())
        appearance.click()
        app.menuItems["Dark"].click()
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: appearance) == "Dark"
        })
        let darkSurface = sampledSurfaceColor(from: window.screenshot())
        XCTAssertGreaterThan(
            lightSurface.red + lightSurface.green + lightSurface.blue,
            darkSurface.red + darkSurface.green + darkSurface.blue + 0.4,
            "Workspace Light and Dark must change the native window rendering"
        )
        appearance.click()
        app.menuItems["Follow System"].click()
        XCTAssertEqual(
            fixtureRunningApplication()?.activationPolicy,
            .regular,
            "An open Workspace must give Cove a normal Dock/App-Switcher identity"
        )

        let cards = window.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.card."
            )
        )
        XCTAssertGreaterThan(cards.count, 0)
        XCTAssertGreaterThan(cards.count, 1)
        let originalFirstCardID = cards.firstMatch.identifier
        let originalSecondCardID = cards.element(boundBy: 1).identifier
        cards.firstMatch.rightClick()
        XCTAssertTrue(
            app.menuItems["Move Later"].firstMatch.waitForExistence(timeout: 2)
        )
        app.typeKey("]", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                cards.firstMatch.identifier == originalSecondCardID
            },
            "The advertised keyboard equivalent must reorder the manual Grid"
        )
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                cards.firstMatch.identifier == originalFirstCardID
            },
            "Workspace reorder must participate in Undo"
        )
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                cards.firstMatch.identifier == originalSecondCardID
            },
            "Workspace reorder must participate in Redo"
        )
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                cards.firstMatch.identifier == originalFirstCardID
            },
            "Workspace reorder must remain undoable after Redo"
        )

        let firstCard = cards.firstMatch
        XCTAssertTrue(firstCard.isHittable)
        firstCard.click()
        XCTAssertTrue(
            element("cove.workspace.inspector", in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            element("cove.workspace.assignment", in: app).exists,
            "Board placement needs a keyboard-accessible inspector control"
        )

        let alias = element("cove.workspace.alias", in: app)
        XCTAssertTrue(alias.waitForExistence(timeout: 2))
        alias.click()
        alias.typeKey("a", modifierFlags: [.command])
        alias.typeText("Release dashboard")
        XCTAssertEqual(stringValue(of: alias), "Release dashboard")

        let inspectorScroll = element("cove.workspace.inspector", in: app)
            .scrollViews.firstMatch
        let artifactLabel = element("cove.workspace.link-label", in: app)
        let artifactURL = element("cove.workspace.link-url", in: app)
        for _ in 0..<8 where !artifactLabel.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(artifactLabel.isHittable)
        artifactLabel.click()
        artifactLabel.typeText("Release issue")
        artifactURL.click()
        artifactURL.typeText("https://artifact-one.test/releases/1")
        element("cove.workspace.link-add", in: app).click()
        XCTAssertTrue(text("artifact-one.test", in: app).waitForExistence(timeout: 2))
        artifactLabel.click()
        artifactLabel.typeText("Build docs")
        artifactURL.click()
        artifactURL.typeText("https://artifact-two.test/docs")
        element("cove.workspace.link-add", in: app).click()
        XCTAssertTrue(text("artifact-two.test", in: app).waitForExistence(timeout: 2))

        let savedLabels = window.textFields.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.artifact.label."
            )
        )
        XCTAssertEqual(savedLabels.count, 2)
        savedLabels.firstMatch.click()
        savedLabels.firstMatch.typeKey("a", modifierFlags: .command)
        savedLabels.firstMatch.typeText("Renamed release issue")
        savedLabels.firstMatch.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(stringValue(of: savedLabels.firstMatch), "Renamed release issue")
        savedLabels.firstMatch.click()
        savedLabels.firstMatch.typeKey("a", modifierFlags: .command)
        savedLabels.firstMatch.typeText("Discard this edit")
        savedLabels.firstMatch.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(stringValue(of: savedLabels.firstMatch), "Renamed release issue")

        let reorderMenus = window.menuButtons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.artifact.reorder."
            )
        )
        XCTAssertEqual(reorderMenus.count, 2)
        savedLabels.element(boundBy: 1).click()
        savedLabels.element(boundBy: 1).typeKey("a", modifierFlags: .command)
        savedLabels.element(boundBy: 1).typeText("Focus-saved docs")
        reorderMenus.firstMatch.click()
        let moveEarlier = app.menuItems["Move Earlier"]
        XCTAssertTrue(moveEarlier.waitForExistence(timeout: 2))
        XCTAssertFalse(moveEarlier.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(
            stringValue(of: savedLabels.element(boundBy: 1)),
            "Focus-saved docs"
        )
        reorderMenus.element(boundBy: 1).click()
        XCTAssertTrue(app.menuItems["Move Earlier"].waitForExistence(timeout: 2))
        app.menuItems["Move Earlier"].click()
        XCTAssertEqual(stringValue(of: savedLabels.firstMatch), "Focus-saved docs")
        reorderMenus.firstMatch.click()
        XCTAssertTrue(app.menuItems["Move Later"].waitForExistence(timeout: 2))
        app.menuItems["Move Later"].click()
        XCTAssertTrue(waitUntil(timeout: 2) {
            self.stringValue(of: savedLabels.firstMatch) == "Renamed release issue"
        })
        let artifactOpen = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cove.workspace.artifact.open.")
        ).firstMatch
        XCTAssertTrue(artifactOpen.waitForExistence(timeout: 2))
        artifactOpen.click()

        let composer = element("cove.workspace.composer", in: app)
        for _ in 0..<8 where !composer.isHittable {
            inspectorScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        XCTAssertTrue(composer.isHittable)
        composer.click()
        composer.typeText("Steer the active fixture turn.")
        let send = element("cove.workspace.send", in: app)
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertTrue(
            text("Send this prompt to Release dashboard?", in: app)
                .waitForExistence(timeout: 2)
        )
        element("cove.workspace.confirm-send", in: app).click()
        XCTAssertTrue(
            text("Prompt steered to the active turn.", in: app)
                .waitForExistence(timeout: 2)
        )
        XCTAssertEqual(stringValue(of: composer), "")

        let board = element("cove.workspace.board", in: app)
        XCTAssertTrue(board.waitForExistence(timeout: 2))
        board.click()
        for column in ["Inbox", "Doing", "Review", "Blocked"] {
            XCTAssertTrue(text(column, in: app).waitForExistence(timeout: 2))
        }

        let columns = element("cove.workspace.columns", in: app)
        XCTAssertTrue(columns.waitForExistence(timeout: 2))
        columns.click()
        XCTAssertTrue(
            element("cove.workspace.columns.sheet", in: app)
                .waitForExistence(timeout: 2)
        )
        let newColumn = element("cove.workspace.columns.new-name", in: app)
        newColumn.click()
        newColumn.typeText("Ready to ship")
        element("cove.workspace.columns.add", in: app).click()
        XCTAssertTrue(
            text("Ready to ship", in: app)
                .waitForExistence(timeout: 2)
        )
        element("cove.workspace.columns.done", in: app).click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                !self.element("cove.workspace.columns.sheet", in: app).exists
            }
        )

        let library = element("cove.workspace.prompt-library", in: app)
        XCTAssertTrue(library.waitForExistence(timeout: 2))
        XCTAssertTrue(library.isHittable)
        library.click()
        XCTAssertTrue(
            element("cove.workspace.prompt-library.sheet", in: app)
                .waitForExistence(timeout: 2)
        )
        let templateName = element("cove.workspace.template.name", in: app)
        let templateBody = element("cove.workspace.template.body", in: app)
        templateName.click()
        templateName.typeText("Review changes")
        templateBody.click()
        templateBody.typeText("Review the current changes and report risks.")
        element("cove.workspace.template.favorite", in: app).click()
        element("cove.workspace.template.save", in: app).click()
        let savedTemplate = text("Review changes", in: app)
        XCTAssertTrue(savedTemplate.waitForExistence(timeout: 2))
        savedTemplate.click()
        let useTemplate = element("cove.workspace.template.use", in: app)
        XCTAssertTrue(useTemplate.isEnabled)
        useTemplate.click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                !self.element("cove.workspace.prompt-library.sheet", in: app).exists
            }
        )
        XCTAssertEqual(
            stringValue(of: composer),
            "Review the current changes and report risks."
        )

        element("cove.workspace.close", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 2) { !window.exists })
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.fixtureRunningApplication()?.activationPolicy == .accessory
            },
            "Closing Workspace must restore Cove's menu-bar accessory identity"
        )
        app.activate()
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.windows.descendants(matching: .any)
                .matching(identifier: "cove.workspace").count,
            1
        )
        let reopenedLabels = window.textFields.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.artifact.label."
            )
        )
        XCTAssertTrue(waitUntil(timeout: 2) {
            reopenedLabels.allElementsBoundByIndex.contains {
                self.stringValue(of: $0) == "Renamed release issue"
            }
        })
        let artifactRemove = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "cove.workspace.artifact.remove.")
        ).firstMatch
        XCTAssertTrue(artifactRemove.waitForExistence(timeout: 2))
        let reopenedScroll = element("cove.workspace.inspector", in: app)
            .scrollViews.firstMatch
        for _ in 0..<8 where !artifactRemove.isHittable {
            reopenedScroll.scroll(byDeltaX: 0, deltaY: -220)
        }
        artifactRemove.click()
    }

    @MainActor
    func testWorkspacePrivacyRedactsContentAndAccessibility() {
        let app = launchFixture("privacy-redacted")
        XCTAssertTrue(element("cove.overlay", in: app).waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: [.command, .shift])
        let window = app.windows["Codex Cove Workspace"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let card = window.buttons.matching(
            identifier: "cove.workspace.card.redacted"
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        XCTAssertFalse(card.label.contains("Fixture attention task"))
        XCTAssertFalse(card.label.contains("Local CLI"))
        card.click()

        XCTAssertTrue(
            element("cove.workspace.inspector", in: app)
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            text(
                "Privacy Mode is On, so Workspace titles and user-authored details are hidden.",
                in: app
            ).waitForExistence(timeout: 2)
        )
        XCTAssertTrue(text("Origin hidden", in: app).exists)
        XCTAssertTrue(
            text(
                "Prompt drafts and templates are hidden by Cove privacy protection.",
                in: app
            )
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(element("cove.workspace.alias", in: app).exists)
        XCTAssertFalse(element("cove.workspace.composer", in: app).exists)
        XCTAssertFalse(element("cove.workspace.artifact.choose", in: app).exists)
        let library = element("cove.workspace.prompt-library", in: app)
        XCTAssertTrue(library.exists)
        XCTAssertFalse(library.isEnabled)

        element("cove.workspace.board", in: app).click()
        XCTAssertTrue(text("Workflow column", in: app).waitForExistence(timeout: 2))
        XCTAssertFalse(text("Inbox", in: app).exists)
        assertNoSensitiveAccessibilityCopy(in: window)
    }

    // MARK: - Approval safety and delivery lifecycle

    @MainActor
    func testPositiveApprovalRequiresASeparateConfirmation() {
        let app = launchFixture("command-approval")
        let request = RequestIdentity(requestID: "fixture-approval")
        openFocusedRequest(request, in: app)

        for control in ["category", "source", "consequence", "scope"] {
            XCTAssertTrue(
                element(request.identifier(control), in: app)
                    .waitForExistence(timeout: 2),
                "Approval review must expose \(control) before a decision"
            )
        }

        let allowOnce = element(request.identifier("allow-once"), in: app)
        XCTAssertTrue(allowOnce.waitForExistence(timeout: 2))
        allowOnce.click()

        XCTAssertEqual(decisionAttemptCount(in: app), 0)
        let confirm = element(request.identifier("confirm-allow"), in: app)
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 2),
            "A positive scope choice must stage, not send, the approval"
        )
        XCTAssertTrue(confirm.label.localizedCaseInsensitiveContains("allow"))

        let selectedScope = element(request.identifier("scope"), in: app)
        XCTAssertTrue(selectedScope.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayText(of: selectedScope)
                .localizedCaseInsensitiveContains("allow once")
                || stringValue(of: selectedScope)
                    .localizedCaseInsensitiveContains("allow once"),
            "The review must expose the initially staged one-time scope"
        )

        let allowForTask = element(
            request.identifier("allow-for-task"),
            in: app
        )
        XCTAssertTrue(allowForTask.waitForExistence(timeout: 2))
        allowForTask.click()
        XCTAssertEqual(
            decisionAttemptCount(in: app),
            0,
            "Correcting the staged scope must not send either choice"
        )
        XCTAssertTrue(
            displayText(of: selectedScope)
                .localizedCaseInsensitiveContains("allow for this task")
                || stringValue(of: selectedScope)
                    .localizedCaseInsensitiveContains("allow for this task"),
            "The review must visibly replace the wrong scope before send"
        )

        confirm.click()
        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))
    }

    @MainActor
    func testTaskScopedApprovalAlsoRequiresConfirmation() {
        let app = launchFixture("permission-approval")
        let request = RequestIdentity(requestID: "fixture-approval")
        openFocusedRequest(request, in: app)

        let allowForTask = element(
            request.identifier("allow-for-task"),
            in: app
        )
        XCTAssertTrue(allowForTask.waitForExistence(timeout: 2))
        allowForTask.click()
        XCTAssertEqual(decisionAttemptCount(in: app), 0)

        let selectedScope = element(request.identifier("scope"), in: app)
        XCTAssertTrue(selectedScope.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayText(of: selectedScope)
                .localizedCaseInsensitiveContains("allow for this task")
                || stringValue(of: selectedScope)
                    .localizedCaseInsensitiveContains("allow for this task"),
            "The review must repeat the selected task-wide scope before send"
        )

        let confirm = element(request.identifier("confirm-allow"), in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        XCTAssertTrue(
            confirm.label.localizedCaseInsensitiveContains("allow"),
            "The staged task-wide scope must still require explicit confirmation"
        )
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))
    }

    @MainActor
    func testRapidRepeatedConfirmationAndReturnSendExactlyOnce() {
        let app = launchFixture("file-approval")
        let request = RequestIdentity(requestID: "fixture-approval")
        openFocusedRequest(request, in: app)

        element(request.identifier("allow-once"), in: app).click()
        let confirm = element(request.identifier("confirm-allow"), in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.click()

        // Exercise both repeated pointer activation and the default-key path
        // while the first async attempt is still in flight/success feedback.
        for _ in 0 ..< 3 where confirm.exists && confirm.isEnabled {
            confirm.click()
        }
        for _ in 0 ..< 4 {
            app.typeKey(.return, modifierFlags: [])
        }

        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))
        XCTAssertFalse(
            waitForDecisionAttemptCount(2, in: app, timeout: 1.2),
            "Single-flight delivery must ignore repeated click and Return events"
        )
        XCTAssertEqual(decisionAttemptCount(in: app), 1)
    }

    @MainActor
    func testDeliveryFailureOffersRetryAndOpenInCodex() {
        let app = launchFixture("delivery-failure")
        let request = RequestIdentity(requestID: "fixture-approval")
        openFocusedRequest(request, in: app)

        element(request.identifier("allow-once"), in: app).click()
        element(request.identifier("confirm-allow"), in: app).click()
        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))

        let status = element(request.identifier("delivery-status"), in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(
            displayText(of: status).localizedCaseInsensitiveContains("failed")
                || stringValue(of: status)
                    .localizedCaseInsensitiveContains("failed")
                || displayText(of: status)
                    .localizedCaseInsensitiveContains("could not")
                || displayText(of: status)
                    .localizedCaseInsensitiveContains("not sent"),
            "A failed send needs a persistent, explicit failure state"
        )

        let retry = element(request.identifier("retry"), in: app)
        let open = element(request.identifier("open-in-codex"), in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 2))
        XCTAssertTrue(open.waitForExistence(timeout: 2))

        open.click()
        XCTAssertTrue(
            retry.exists,
            "Open in Codex must not silently resolve an unsent request"
        )
        retry.click()
        XCTAssertTrue(waitForDecisionAttemptCount(2, in: app))
    }

    // MARK: - Question drafts, keyboard access, and full labels

    @MainActor
    func testDirtyQuestionEscapeKeepsThenDiscardsTheDraft() {
        let app = launchFixture("single-question")
        let request = RequestIdentity(requestID: "fixture-question")
        openFocusedRequest(request, in: app)

        let answer = element(
            request.questionAnswerIdentifier(questionID: "fixture-question"),
            in: app
        )
        XCTAssertTrue(answer.waitForExistence(timeout: 2))
        answer.click()
        answer.typeText("Preserve this deterministic answer")

        app.typeKey(.escape, modifierFlags: [])
        let keepEditing = element(
            request.identifier("dirty-keep-editing"),
            in: app
        )
        let discard = element(request.identifier("dirty-discard"), in: app)
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 2))
        XCTAssertTrue(discard.exists)

        keepEditing.click()
        XCTAssertEqual(
            stringValue(of: answer),
            "Preserve this deterministic answer"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(discard.waitForExistence(timeout: 2))
        discard.click()
        XCTAssertTrue(
            element(request.identifier("queue-row"), in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(answer.exists)
    }

    @MainActor
    func testSingleQuestionCanBeCompletedWithKeyboardAndAX() {
        let app = launchFixture("single-question")
        let request = RequestIdentity(requestID: "fixture-question")
        openFocusedRequest(request, in: app)

        let container = element(
            request.identifier("question-container"),
            in: app
        )
        XCTAssertTrue(container.waitForExistence(timeout: 2))
        XCTAssertTrue(
            labeledElement(
                "1. Which deterministic option should Codex use?",
                in: app
            ).exists
        )

        let answer = element(
            request.questionAnswerIdentifier(questionID: "fixture-question"),
            in: app
        )
        answer.click()
        answer.typeText("Keyboard-authored response")
        let send = element(request.identifier("question-send"), in: app)
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(send.isEnabled)

        // Command-Return is the focused-form submit shortcut and leaves plain
        // Return available to the active text field.
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))
    }

    @MainActor
    func testMultiQuestionShowsFullLabelsAt520PointsAndSendsAllAnswers() {
        let app = launchFixture("multi-question")
        let request = RequestIdentity(requestID: "fixture-multi-question")
        openFocusedRequest(request, in: app)

        let overlay = element("cove.overlay", in: app)
        XCTAssertGreaterThanOrEqual(overlay.frame.width, 510)
        XCTAssertLessThanOrEqual(overlay.frame.width, 530)

        let architectureQuestion = labeledElement(
            "1. Choose the complete architecture option without truncating this label.",
            in: app
        )
        let architectureChoice = labeledElement(
            "Native application with local public Codex interfaces",
            in: app
        )
        XCTAssertTrue(architectureQuestion.waitForExistence(timeout: 2))
        XCTAssertTrue(architectureChoice.waitForExistence(timeout: 2))
        XCTAssertEqual(
            displayText(of: architectureQuestion),
            "1. Choose the complete architecture option without truncating this label."
        )
        XCTAssertEqual(
            architectureChoice.label,
            "Native application with local public Codex interfaces"
        )
        XCTAssertGreaterThan(architectureQuestion.frame.width, 100)
        XCTAssertGreaterThan(architectureQuestion.frame.height, 0)
        XCTAssertGreaterThanOrEqual(
            architectureQuestion.frame.minX,
            overlay.frame.minX - 1
        )
        XCTAssertLessThanOrEqual(
            architectureQuestion.frame.maxX,
            overlay.frame.maxX + 1
        )

        element(
            request.questionChoiceIdentifier(
                questionID: "architecture",
                choiceID: "native"
            ),
            in: app
        ).click()
        let notes = element(
            request.questionAnswerIdentifier(questionID: "notes"),
            in: app
        )
        notes.click()
        notes.typeText("Keep the entire implementation local.")

        let send = element(request.identifier("question-send"), in: app)
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))
    }

    @MainActor
    func testFocusedQuestionRemainsOperableAtTwoHundredPercentTextSize() {
        let app = launchFixture(
            "multi-question",
            textScale: 2
        )
        let request = RequestIdentity(requestID: "fixture-multi-question")
        openFocusedRequest(request, in: app)

        let overlay = element("cove.overlay", in: app)
        let focusedScroll = element("cove.focused.scroll", in: app)
        XCTAssertTrue(focusedScroll.waitForExistence(timeout: 3))
        XCTAssertEqual(
            stringValue(of: element("cove.fixture.text-scale", in: app)),
            "2.00"
        )
        let focusedScreenshot = XCTAttachment(screenshot: app.screenshot())
        focusedScreenshot.name = "Focused form at 200 percent text size"
        focusedScreenshot.lifetime = .keepAlways
        add(focusedScreenshot)
        XCTAssertGreaterThanOrEqual(overlay.frame.width, 510)
        XCTAssertLessThanOrEqual(overlay.frame.width, 530)

        let question = labeledElement(
            "1. Choose the complete architecture option without truncating this label.",
            in: app
        )
        XCTAssertTrue(question.waitForExistence(timeout: 3))
        XCTAssertEqual(
            displayText(of: question),
            "1. Choose the complete architecture option without truncating this label."
        )
        XCTAssertGreaterThan(question.frame.height, 20)
        XCTAssertGreaterThanOrEqual(question.frame.minX, overlay.frame.minX - 1)
        XCTAssertLessThanOrEqual(question.frame.maxX, overlay.frame.maxX + 1)

        let choice = element(
            request.questionChoiceIdentifier(
                questionID: "architecture",
                choiceID: "native"
            ),
            in: app
        )
        revealFocusedElement(choice, in: app)
        choice.click()

        let notes = element(
            request.questionAnswerIdentifier(questionID: "notes"),
            in: app
        )
        revealFocusedElement(notes, in: app)
        notes.click()
        notes.typeText("Accessible text remains operable.")

        let send = element(request.identifier("question-send"), in: app)
        revealFocusedElement(send, in: app)
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertTrue(waitForDecisionAttemptCount(1, in: app))
    }

    // MARK: - Settings information architecture and precision controls

    @MainActor
    func testEverySettingsPaneIsPointerAndAXReachable() {
        let app = launchFixture("settings-appearance")
        XCTAssertTrue(
            app.windows["Codex Cove Settings"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(element("settings.appearance.workspace", in: app).exists)
        for pane in [
            "appearance",
            "residents",
            "general",
            "notifications",
            "sounds",
            "privacyAndQuiet",
            "sessions",
        ] {
            let sidebarItem = element("settings.sidebar.\(pane)", in: app)
            XCTAssertTrue(
                sidebarItem.waitForExistence(timeout: 2),
                "Missing AX navigation item for \(pane)"
            )
            sidebarItem.click()
            XCTAssertTrue(
                element("settings.pane.\(pane).title", in: app)
                    .waitForExistence(timeout: 2),
                "Settings pane \(pane) should be reachable from the sidebar"
            )
            XCTAssertTrue(
                element("settings.pane.\(pane).help", in: app).exists,
                "Settings pane \(pane) should link to its detailed help"
            )
        }
    }

    @MainActor
    func testSettingsSidebarSupportsKeyboardNavigation() {
        let app = launchFixture("settings-appearance")
        XCTAssertTrue(
            app.windows["Codex Cove Settings"].waitForExistence(timeout: 5)
        )

        let appearance = element("settings.sidebar.appearance", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 2))
        appearance.click()

        for pane in [
            "residents",
            "general",
            "notifications",
            "sounds",
            "privacyAndQuiet",
            "sessions",
        ] {
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(
                element("settings.pane.\(pane).title", in: app)
                    .waitForExistence(timeout: 2),
                "Down Arrow should navigate the Settings sidebar to \(pane)"
            )
        }
    }

    @MainActor
    func testCustomThemeDraftPersistsWhenSettingsCloses() throws {
        let app = launchFixture("settings-appearance")
        let settingsWindow = app.windows["Codex Cove Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        let surfaceFill = element(
            "settings.appearance.surface-fill",
            in: app
        )
        let solidOption = surfaceFill.descendants(matching: .radioButton)[
            "Solid"
        ].firstMatch
        revealAndClick(solidOption, in: app)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: solidOption) == "1"
            }
        )

        let themeName = element(
            "settings.appearance.custom-theme-name",
            in: app
        )
        revealAndClick(themeName, in: app)
        replaceText(
            in: themeName,
            with: "Close Saved Theme",
            commitsWithReturn: false,
            app: app
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 2) { !settingsWindow.exists })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: stateDirectory.appendingPathComponent(
                    "Themes",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.count,
            1,
            "Closing Settings must persist the edited custom theme"
        )

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(
            stringValue(
                of: element("settings.appearance.custom-theme", in: app)
            ),
            "Close Saved Theme"
        )
    }

    @MainActor
    func testInstalledSurfaceAppliesThemeColorAndOpacity() throws {
        let app = launchFixture("settings-appearance")
        let settingsWindow = app.windows["Codex Cove Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        let collapse = element("cove.overlay.collapse", in: app)
        let expand = element("cove.overlay.expand", in: app)
        XCTAssertTrue(
            expand.waitForExistence(timeout: 3),
            "Opening Settings must automatically collapse Cove"
        )
        XCTAssertFalse(collapse.exists)

        let baseline = sampledSurfaceColor(from: expand.screenshot())

        let palette = element("settings.appearance.palette", in: app)
        revealAndClick(palette, in: app)
        let terminalGreen = app.menuItems["Terminal Green"]
        XCTAssertTrue(terminalGreen.waitForExistence(timeout: 2))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: palette) == "Terminal Green"
            }
        )
        let themed = sampledSurfaceColor(from: expand.screenshot())
        XCTAssertGreaterThan(
            colorDistance(baseline, themed),
            0.025,
            "The installed collapsed surface must use the selected theme color"
        )

        let surfaceFill = element(
            "settings.appearance.surface-fill",
            in: app
        )
        let solidOption = surfaceFill.descendants(matching: .radioButton)[
            "Solid"
        ].firstMatch
        revealAndClick(solidOption, in: app)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: solidOption) == "1"
            },
            "Solid must be selectable as the live surface fill"
        )
        let solidSurface = sampledSurfaceColor(from: expand.screenshot())
        XCTAssertGreaterThan(
            colorDistance(themed, solidSurface),
            0.012,
            "Switching from Gradient to Solid must update the live island"
        )

        let backgroundColor = element(
            "settings.appearance.color.background",
            in: app
        )
        revealAndClick(backgroundColor, in: app)
        let colorsPanel = app.windows["Colors"]
        XCTAssertTrue(
            colorsPanel.waitForExistence(timeout: 2),
            "Theme colors must open the native color wheel"
        )
        colorsPanel.buttons[XCUIIdentifierCloseWindow].click()

        let themeName = element(
            "settings.appearance.custom-theme-name",
            in: app
        )
        revealAndClick(themeName, in: app)
        replaceText(
            in: themeName,
            with: "UI Saved Theme",
            commitsWithReturn: false,
            app: app
        )
        let saveTheme = element(
            "settings.appearance.save-custom-theme",
            in: app
        )
        revealAndClick(saveTheme, in: app)
        let dismissThemeAlert = element(
            "settings.theme-alert.dismiss",
            in: app
        )
        XCTAssertTrue(dismissThemeAlert.waitForExistence(timeout: 2))
        dismissThemeAlert.click()
        XCTAssertEqual(
            stringValue(
                of: element("settings.appearance.custom-theme", in: app)
            ),
            "UI Saved Theme"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: stateDirectory.appendingPathComponent(
                    "Themes",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.count,
            1,
            "Saving in Settings must persist one custom theme document"
        )

        let opacityField = element(
            "settings.appearance.collapsed-opacity.field",
            in: app
        )
        revealAndClick(opacityField, in: app)
        replaceText(
            in: opacityField,
            with: "35",
            commitsWithReturn: true,
            app: app
        )
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: opacityField) == "35"
            }
        )
        let translucent = sampledSurfaceColor(from: expand.screenshot())
        XCTAssertGreaterThan(
            colorDistance(solidSurface, translucent),
            0.012,
            "The installed collapsed surface must use its configured opacity"
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 2) { !settingsWindow.exists })
        expand.click()
        XCTAssertTrue(
            collapse.waitForExistence(timeout: 3),
            "Cove may expand again after Settings closes"
        )
    }

    @MainActor
    func testEverySettingsPaneRemainsOperableAtTwoHundredPercentTextSize() {
        let app = launchFixture(
            "settings-appearance",
            textScale: 2
        )
        let settingsWindow = app.windows["Codex Cove Settings"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 5)
        )
        XCTAssertGreaterThanOrEqual(
            settingsWindow.frame.width,
            980,
            "The 200% Settings layout must receive its full minimum width"
        )
        XCTAssertGreaterThanOrEqual(
            settingsWindow.frame.height,
            680,
            "The 200% Settings layout must receive its full minimum height"
        )
        XCTAssertEqual(
            stringValue(of: element("settings.fixture.text-scale", in: app)),
            "2.00"
        )
        let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
        settingsScreenshot.name = "Settings at 200 percent text size"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)

        let panes: [(raw: String, title: String, control: String)] = [
            ("appearance", "Appearance", "settings.appearance.animate-panel"),
            ("residents", "Residents", "settings.residents.preview-state"),
            ("general", "General", "settings.general.global-shortcuts"),
            (
                "notifications",
                "Notifications",
                "settings.notifications.global-enabled"
            ),
            ("sounds", "Sounds", "settings.sounds.global.enabled"),
            (
                "privacyAndQuiet",
                "Privacy & Quiet",
                "settings.privacy.conservative-capture"
            ),
            ("sessions", "Sessions & Data", "settings.sessions.minimal-island"),
        ]

        for pane in panes {
            let sidebarItem = element("settings.sidebar.\(pane.raw)", in: app)
            XCTAssertTrue(sidebarItem.waitForExistence(timeout: 3))
            XCTAssertTrue(sidebarItem.isHittable)
            sidebarItem.click()

            let title = element("settings.pane.\(pane.raw).title", in: app)
            XCTAssertTrue(title.waitForExistence(timeout: 3))
            XCTAssertEqual(displayText(of: title), pane.title)
            XCTAssertGreaterThan(title.frame.height, 20)

            let control = element(pane.control, in: app)
            let valueBeforeInteraction = stringValue(of: control)
            revealAndClick(control, in: app)
            XCTAssertTrue(
                control.exists,
                "The \(pane.title) pane control must remain operable at 200%"
            )

            if control.elementType == .popUpButton
                || control.elementType == .comboBox
            {
                app.typeKey(.downArrow, modifierFlags: [])
                app.typeKey(.return, modifierFlags: [])
            }
            XCTAssertTrue(
                waitUntil(timeout: 2) {
                    self.stringValue(of: control) != valueBeforeInteraction
                },
                "The \(pane.title) control should respond at 200%"
            )

            if pane.raw == "notifications" {
                let finalHostCell = element(
                    "settings.notifications.followUp.host",
                    in: app
                )
                let hostValueBefore = stringValue(of: finalHostCell)
                revealAndClick(finalHostCell, in: app)
                XCTAssertNotEqual(
                    stringValue(of: finalHostCell),
                    hostValueBefore,
                    "The last notification content control must remain reachable at 200%"
                )
            }
        }
    }

    @MainActor
    func testExactTimingFieldCommitsAndValidates() {
        let app = launchFixture("settings-general")
        let field = element("settings.general.hover-delay.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        revealAndClick(field, in: app)
        replaceText(
            in: field,
            with: "1.35",
            commitsWithReturn: true,
            app: app
        )

        XCTAssertTrue(
            waitUntil(timeout: 2) { self.stringValue(of: field) == "1.35" }
        )

        replaceText(
            in: field,
            with: "9.99",
            commitsWithReturn: true,
            app: app
        )
        let validation = element(
            "settings.general.hover-delay.validation",
            in: app
        )
        XCTAssertTrue(validation.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayText(of: validation).localizedCaseInsensitiveContains("0")
                && displayText(of: validation)
                    .localizedCaseInsensitiveContains("3"),
            "Out-of-range exact values must announce the accepted range"
        )

        replaceText(
            in: field,
            with: "1.35",
            commitsWithReturn: true,
            app: app
        )
        let collapseField = element(
            "settings.general.collapse-delay.field",
            in: app
        )
        let idleField = element(
            "settings.general.idle-auto-hide.field",
            in: app
        )
        replaceText(
            in: collapseField,
            with: "12",
            commitsWithReturn: true,
            app: app
        )
        replaceText(
            in: idleField,
            with: "45",
            commitsWithReturn: true,
            app: app
        )
        XCTAssertEqual(stringValue(of: field), "1.35")
        XCTAssertEqual(stringValue(of: collapseField), "12")
        XCTAssertEqual(stringValue(of: idleField), "45")

        let reset = element(
            "settings.general.reset-interaction-defaults",
            in: app
        )
        revealAndClick(reset, in: app)
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: field) == "0.25"
                    && self.stringValue(of: collapseField) == "6"
                    && self.stringValue(of: idleField) == "0"
            },
            "Reset Interaction Defaults must restore exactly 0.25 s, 6 s, and 0 s; got \(stringValue(of: field)), \(stringValue(of: collapseField)), and \(stringValue(of: idleField))"
        )
    }

    @MainActor
    func testSilencedProjectTokensAddDedupeAndRemove() {
        let app = launchFixture("settings-privacy")
        let field = element(
            "settings.privacy.silenced-projects.field",
            in: app
        )
        revealAndClick(field, in: app)
        field.typeText("Comma Project,")
        let commaRemove = element(
            "settings.privacy.silenced-projects.token.0.remove",
            in: app
        )
        XCTAssertTrue(commaRemove.waitForExistence(timeout: 2))
        XCTAssertTrue(commaRemove.label.hasSuffix("Comma Project"))
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(
            commaRemove.waitForExistence(timeout: 1),
            "Backspace in an empty token field must remove the final token"
        )

        let suggestions = element(
            "settings.privacy.silenced-projects.suggestions",
            in: app
        )
        revealAndClick(suggestions, in: app)
        let firstSuggestion = element(
            "settings.privacy.silenced-projects.suggestion.0",
            in: app
        )
        XCTAssertTrue(firstSuggestion.waitForExistence(timeout: 2))
        XCTAssertEqual(firstSuggestion.title, "Fixture task 1")
        firstSuggestion.click()
        let suggestedRemove = element(
            "settings.privacy.silenced-projects.token.0.remove",
            in: app
        )
        XCTAssertTrue(suggestedRemove.waitForExistence(timeout: 2))
        XCTAssertTrue(suggestedRemove.label.hasSuffix("Fixture task 1"))
        suggestedRemove.click()
        XCTAssertFalse(suggestedRemove.waitForExistence(timeout: 1))

        revealAndClick(field, in: app)
        field.typeText(" Codex Cove ")
        field.typeKey(.return, modifierFlags: [])

        let remove = element(
            "settings.privacy.silenced-projects.token.0.remove",
            in: app
        )
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        XCTAssertTrue(
            remove.label.hasPrefix("Remove silenced project Codex Cove"),
            "The remove action must name the complete token"
        )

        revealAndClick(field, in: app)
        field.typeText("codex cove")
        field.typeKey(.return, modifierFlags: [])
        let validation = element(
            "settings.privacy.silenced-projects.validation",
            in: app
        )
        scrollSettingsDetail(in: app, deltaY: -180)
        XCTAssertTrue(validation.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayText(of: validation)
                .localizedCaseInsensitiveContains("already")
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                    "settings.privacy.silenced-projects.token.",
                    ".remove"
                )
            ).count,
            1,
            "Case-insensitive equivalent rules must deduplicate"
        )

        remove.click()
        XCTAssertFalse(remove.waitForExistence(timeout: 1))
    }

    @MainActor
    func testPrivacyModeSuppressesLiveSilencedProjectSuggestions() {
        let app = launchFixture("settings-privacy-redacted")
        let settingsWindow = app.windows["Codex Cove Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        let suggestions = element(
            "settings.privacy.silenced-projects.suggestions",
            in: app
        )
        XCTAssertTrue(suggestions.waitForExistence(timeout: 3))
        XCTAssertFalse(
            suggestions.isEnabled,
            "Privacy Mode must disable suggestions derived from live task metadata"
        )

        let accessibleCopy = ([settingsWindow]
            + settingsWindow.descendants(matching: .any).allElementsBoundByIndex)
            .flatMap { [$0.label, stringValue(of: $0)] }
            .joined(separator: "\n")
        XCTAssertFalse(accessibleCopy.contains("Fixture task 1"))
        XCTAssertFalse(accessibleCopy.contains("Deterministic fixture detail 1"))
    }

    @MainActor
    func testNotificationMatrixLabelsAndPrivacyAwarePreview() {
        let app = launchFixture("settings-notifications")

        let kinds: [(raw: String, label: String)] = [
            ("approval", "Approval"),
            ("input", "Question/Input"),
            ("completed", "Completed"),
            ("failed", "Failed"),
            ("interrupted", "Interrupted"),
            ("followUp", "Follow-up"),
        ]
        let cells: [(component: String, label: String)] = [
            ("enabled", "Enabled"),
            ("task-title", "Task title"),
            ("detail", "Detail"),
            ("project", "Project"),
            ("source", "Source"),
            ("host", "Host"),
        ]

        for kind in kinds {
            let select = element(
                "settings.notifications.\(kind.raw).select",
                in: app
            )
            XCTAssertTrue(select.waitForExistence(timeout: 5))
            XCTAssertEqual(
                select.label,
                "Select \(kind.label) notification preview"
            )
            for cell in cells {
                let checkbox = element(
                    "settings.notifications.\(kind.raw).\(cell.component)",
                    in: app
                )
                XCTAssertTrue(
                    checkbox.exists,
                    "Missing \(kind.label), \(cell.label) matrix cell"
                )
                XCTAssertEqual(
                    checkbox.label,
                    "\(kind.label), \(cell.label)"
                )
            }
        }

        element("settings.notifications.failed.select", in: app).click()
        let previewBody = element(
            "settings.notifications.preview.body",
            in: app
        )
        XCTAssertTrue(previewBody.waitForExistence(timeout: 2))
        XCTAssertTrue(
            displayText(of: previewBody)
                .contains("Codex is ready for your review.")
        )

        element("settings.sidebar.privacyAndQuiet", in: app).click()
        let privacyPicker = element("settings.privacy.mode", in: app)
        XCTAssertTrue(privacyPicker.waitForExistence(timeout: 2))
        XCTAssertEqual(stringValue(of: privacyPicker), "Off")
        revealAndClick(privacyPicker, in: app)
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: privacyPicker) == "On"
            }
        )

        element("settings.sidebar.notifications", in: app).click()
        let override = element(
            "settings.notifications.preview.privacy-override",
            in: app
        )
        XCTAssertTrue(override.waitForExistence(timeout: 2))
        XCTAssertEqual(
            displayText(of: override),
            "Privacy is On, so content choices are hidden in the delivered banner."
        )
        XCTAssertFalse(
            displayText(of: previewBody).contains("Refine Codex Cove settings")
        )
        XCTAssertFalse(
            displayText(of: previewBody)
                .contains("Codex is ready for your review.")
        )
    }

    @MainActor
    func testSoundEventDisclosuresStartCollapsedWithCompleteSummaries() {
        let app = launchFixture("settings-sounds")
        let globalEnabled = element("settings.sounds.global.enabled", in: app)
        XCTAssertTrue(globalEnabled.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: globalEnabled), "0")
        globalEnabled.click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: globalEnabled) == "1"
            }
        )

        let events: [(raw: String, label: String)] = [
            ("approvalRequested", "Approval requested"),
            ("needsInput", "Question needs input"),
            ("taskCompleted", "Task completed"),
            ("taskFailed", "Task failed"),
        ]

        for event in events {
            let disclosure = element(
                "settings.sounds.event.\(event.raw).disclosure",
                in: app
            )
            XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
            XCTAssertEqual(disclosure.elementType, .disclosureTriangle)
            XCTAssertTrue(disclosure.label.hasPrefix(event.label))
            XCTAssertTrue(disclosure.label.contains("Cove 8-bit"))
            XCTAssertTrue(
                disclosure.label.localizedCaseInsensitiveContains("effective")
            )
            XCTAssertEqual(stringValue(of: disclosure), "0")
            XCTAssertFalse(
                element(
                    "settings.sounds.event.\(event.raw).source",
                    in: app
                ).exists,
                "Per-event detail controls should begin collapsed"
            )
        }

        let firstDisclosure = element(
            "settings.sounds.event.approvalRequested.disclosure",
            in: app
        )
        XCTAssertTrue(firstDisclosure.isHittable)
        firstDisclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5)
        ).click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: firstDisclosure) == "1"
            },
            "Clicking the disclosure arrow should expand its controls"
        )
        let source = element(
            "settings.sounds.event.approvalRequested.source",
            in: app
        )
        revealAndClick(source, in: app)
        let glass = app.menuItems["Glass"].firstMatch
        XCTAssertTrue(glass.waitForExistence(timeout: 2))
        glass.click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: source)
                    .localizedCaseInsensitiveContains("glass")
            }
        )
        let preview = element(
            "settings.sounds.event.approvalRequested.preview",
            in: app
        )
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(
            preview.isEnabled,
            "Fixture Preview must stay disabled to prevent sound playback"
        )
        let volumeField = element(
            "settings.sounds.event.approvalRequested.volume.field",
            in: app
        )
        replaceText(
            in: volumeField,
            with: "65",
            commitsWithReturn: true,
            app: app
        )
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: volumeField) == "65"
            }
        )
        firstDisclosure.coordinate(
            withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5)
        ).click()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                self.stringValue(of: firstDisclosure) == "0"
            }
        )
        XCTAssertTrue(firstDisclosure.label.contains("Glass"))
        XCTAssertTrue(firstDisclosure.label.contains("65% effective"))
    }

    @MainActor
    func testResidentPaneExplainsAutomaticAssignmentNotSelection() {
        let app = launchFixture("settings-residents")
        let description = element(
            "settings.residents.assignment-description",
            in: app
        )
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        XCTAssertEqual(
            displayText(of: description),
            "Cove automatically assigns each task a resident from the selected set. The gallery previews that set; individual residents are not selected per task."
        )
        let cardResidents = element(
            "settings.residents.workspace-cards",
            in: app
        )
        let cardMotion = element(
            "settings.residents.workspace-card-motion",
            in: app
        )
        XCTAssertTrue(cardResidents.waitForExistence(timeout: 2))
        XCTAssertTrue(cardMotion.exists)
        revealAndClick(cardResidents, in: app)
        XCTAssertTrue(waitUntil(timeout: 2) { !cardMotion.isEnabled })
        revealAndClick(cardResidents, in: app)
        XCTAssertTrue(waitUntil(timeout: 2) { cardMotion.isEnabled })
        let characterSet = element("settings.residents.character-set", in: app)
        revealAndClick(characterSet, in: app)
        for set in ["Dungeon / D&D", "Tech Creatures", "Virus / Bacteria"] {
            XCTAssertTrue(app.menuItems[set].waitForExistence(timeout: 2))
        }
        app.menuItems["Virus / Bacteria"].click()
        XCTAssertTrue(
            element("settings.residents.preview.shellRunner", in: app)
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            element("settings.residents.preview.beaconKeeper", in: app).exists
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Choose resident")
            ).count,
            0
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Select resident")
            ).count,
            0
        )
    }

    // MARK: - Launch and interaction helpers

    @MainActor
    @discardableResult
    private func launchFixture(
        _ fixture: String,
        textScale: Double? = nil,
        backdrop: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-fixture", fixture,
            "--ui-test-state-dir", stateDirectory.path,
        ]
        if let textScale {
            app.launchArguments += [
                "--ui-test-text-scale", String(textScale),
            ]
        }
        if let backdrop {
            app.launchArguments += ["--ui-test-backdrop", backdrop]
        }
        launchedApplications.append(app)
        app.launch()
        return app
    }

    private func fixtureRunningApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "local.chris.codexcove.uitesthost"
        ).first { !$0.isTerminated }
    }

    @MainActor
    private func collapsedSurfaceColor(
        backdrop: String
    ) -> (red: Double, green: Double, blue: Double) {
        let app = launchFixture("collapsed-cue", backdrop: backdrop)
        let expand = app.buttons["cove.overlay.expand"].firstMatch
        let collapse = app.buttons["cove.overlay.collapse"].firstMatch
        if collapse.waitForExistence(timeout: 2) {
            collapse.click()
        }
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let color = sampledSurfaceColor(from: expand.screenshot())
        app.terminate()
        XCTAssertTrue(
            waitUntil(timeout: 2) { app.state == .notRunning },
            "The first backdrop fixture must stop before relaunch"
        )
        return color
    }

    @MainActor
    private func movePointerAwayFromCove() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let safePoint = CGPoint(
            x: bounds.minX + 20,
            y: bounds.maxY - 20
        )
        XCTAssert(
            CGWarpMouseCursorPosition(safePoint) == .success,
            "The backdrop fixture must normalize hover state before sampling"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    @MainActor
    private func openFocusedRequest(
        _ request: RequestIdentity,
        in app: XCUIApplication
    ) {
        let row = element(request.identifier("queue-row"), in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "Fixture request should appear in Needs Attention"
        )
        let review = app.buttons["Review"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 2))
        review.click()
        let containerControl = request.requestID.contains("approval")
            ? "container"
            : "question-container"
        XCTAssertTrue(
            element(request.identifier(containerControl), in: app)
                .waitForExistence(timeout: 3),
            "Review should open the request's focused surface"
        )
    }

    @MainActor
    private func revealAndClick(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        if !element.exists || !element.isHittable {
            let settingsWindow = app.windows["Codex Cove Settings"]
            let detail = settingsWindow.coordinate(
                withNormalizedOffset: CGVector(dx: 0.78, dy: 0.65)
            )
            for _ in 0 ..< 20 {
                if element.exists && element.isHittable { break }
                detail.scroll(byDeltaX: 0, deltaY: -260)
            }
        }
        XCTAssertTrue(
            element.waitForExistence(timeout: 2),
            "Element should exist after revealing: \(element)"
        )
        XCTAssertTrue(element.isHittable, "Element should be reachable: \(element)")
        element.click()
    }

    @MainActor
    private func revealFocusedElement(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        if !element.exists || !element.isHittable {
            let scrollView = self.element("cove.focused.scroll", in: app)
            for _ in 0 ..< 8 {
                if element.exists && element.isHittable { break }
                guard scrollView.exists else { break }
                scrollView.scroll(byDeltaX: 0, deltaY: -220)
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable, "Focused control should remain reachable")
    }

    @MainActor
    private func scrollSettingsDetail(
        in app: XCUIApplication,
        deltaY: CGFloat
    ) {
        let scrollViews = app.windows["Codex Cove Settings"].scrollViews
            .allElementsBoundByIndex
            .filter { $0.frame.width > 300 }
        guard let scrollView = scrollViews.last, scrollView.exists else {
            return
        }
        scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
    }

    @MainActor
    private func replaceText(
        in field: XCUIElement,
        with value: String,
        commitsWithReturn: Bool,
        app: XCUIApplication
    ) {
        revealAndClick(field, in: app)
        field.typeKey("a", modifierFlags: [.command])
        field.typeText(value)
        if commitsWithReturn {
            field.typeKey(.return, modifierFlags: [])
        }
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    @MainActor
    private func sampledSurfaceColor(
        from screenshot: XCUIScreenshot,
        xFractions: Range<Double> = 0.78 ..< 0.90
    ) -> (red: Double, green: Double, blue: Double) {
        guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation)
        else {
            XCTFail("Could not decode the surface screenshot")
            return (0, 0, 0)
        }
        let xRange = max(
            0,
            Int(Double(bitmap.pixelsWide) * xFractions.lowerBound)
        ) ..< max(
            1,
            Int(Double(bitmap.pixelsWide) * xFractions.upperBound)
        )
        let yRange = max(0, Int(Double(bitmap.pixelsHigh) * 0.42))
            ..< max(1, Int(Double(bitmap.pixelsHigh) * 0.58))
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: 2) {
            for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else { continue }
                red += Double(color.redComponent)
                green += Double(color.greenComponent)
                blue += Double(color.blueComponent)
                count += 1
            }
        }
        guard count > 0 else {
            XCTFail("The sampled surface area contained no pixels")
            return (0, 0, 0)
        }
        return (red / count, green / count, blue / count)
    }

    private func colorDistance(
        _ lhs: (red: Double, green: Double, blue: Double),
        _ rhs: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }

    @MainActor
    private func labeledElement(
        _ label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == %@ OR value == %@",
                    label,
                    label
                )
            )
            .firstMatch
    }

    @MainActor
    private func text(
        _ label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR value == %@",
                label,
                label
            )
        ).firstMatch
    }

    @MainActor
    private func decisionAttemptCount(in app: XCUIApplication) -> Int {
        let marker = element("cove.fixture.decision-attempt-count", in: app)
        guard marker.waitForExistence(timeout: 2) else { return -1 }
        return Int(stringValue(of: marker)) ?? -1
    }

    @MainActor
    private func jumpCount(in app: XCUIApplication) -> Int {
        if let value = Int(fixtureMarkerValue(named: "jump-count.txt")) {
            return value
        }
        let marker = element("cove.fixture.jump-count", in: app)
        guard marker.waitForExistence(timeout: 2) else { return -1 }
        return Int(stringValue(of: marker)) ?? -1
    }

    @MainActor
    private func threadControl(in app: XCUIApplication) -> String {
        let value = fixtureMarkerValue(named: "thread-control.txt")
        return value.isEmpty
            ? stringValue(of: element("cove.fixture.thread-control", in: app))
            : value
    }

    @MainActor
    private func waitForDecisionAttemptCount(
        _ expected: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 3
    ) -> Bool {
        waitUntil(timeout: timeout) {
            self.decisionAttemptCount(in: app) == expected
        }
    }

    @MainActor
    private func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        if let value = element.value {
            return String(describing: value)
        }
        return ""
    }

    private func fixtureFaviconStates() -> String {
        fixtureMarkerValue(named: "favicon-states.txt")
    }

    private func fixtureMarkerValue(named name: String) -> String {
        let url = stateDirectory.appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @MainActor
    private func selectWorkspaceAgent(
        _ name: String,
        rootCard: XCUIElement,
        window: XCUIElement,
        scrollView: XCUIElement,
        app: XCUIApplication
    ) {
        rootCard.click()
        let disclosureQuery = window.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "cove.workspace.agent.disclosure."
            )
        )
        for _ in 0..<12 where !disclosureQuery.firstMatch.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: 220)
        }
        let disclosure = disclosureQuery.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 2))
        XCTAssertTrue(disclosure.isHittable)
        if stringValue(of: disclosure) != "Expanded" {
            disclosure.click()
        }
        for _ in 0..<8 where !app.buttons["Inspect \(name)"].firstMatch.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: 220)
        }
        let agent = app.buttons["Inspect \(name)"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 2))
        XCTAssertTrue(agent.isHittable)
        agent.click()
    }

    @MainActor
    private func displayText(of element: XCUIElement) -> String {
        element.label.isEmpty ? stringValue(of: element) : element.label
    }

    @MainActor
    private func assertNoSensitiveAccessibilityCopy(
        in root: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = [
            "Fixture attention task",
            "Codex needs a safe response",
            "Review fixture command approval",
            "This fixture action demonstrates its consequence before sending.",
            "/fixture/decision.sock",
        ]
        let exposedCopy = ([root] + root.descendants(matching: .any)
            .allElementsBoundByIndex)
            .flatMap { [$0.label, stringValue(of: $0)] }
            .joined(separator: "\n")

        for secret in forbidden {
            XCTAssertFalse(
                exposedCopy.contains(secret),
                "Privacy Mode exposed sensitive accessibility copy: \(secret)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(pollInterval)
            )
        } while Date() < deadline
        return condition()
    }

    // MARK: - Stable private fixture identifiers

    private struct RequestIdentity {
        let requestID: String
        let launchID = "fixture-launch"
        let sessionID = "fixture-session"
        let turnID = "fixture-turn"
        let source: String? = nil
        let hostID: String? = nil

        private var requestFingerprint: String {
            CodexCoveUITests.fingerprint(
                [
                    "s:\(requestID)",
                    launchID,
                    sessionID,
                    turnID,
                    source ?? "-",
                    hostID ?? "-",
                ].joined(separator: "\u{1f}")
            )
        }

        func identifier(_ control: String) -> String {
            "cove.request.\(requestFingerprint).\(Self.stableSlug(control))"
        }

        func questionAnswerIdentifier(questionID: String) -> String {
            identifier(
                "question.\(CodexCoveUITests.fingerprint(questionID)).answer"
            )
        }

        func questionChoiceIdentifier(
            questionID: String,
            choiceID: String
        ) -> String {
            identifier(
                "question.\(CodexCoveUITests.fingerprint(questionID))"
                    + ".choice.\(CodexCoveUITests.fingerprint(choiceID))"
            )
        }

        private static func stableSlug(_ value: String) -> String {
            let scalars = value.lowercased().unicodeScalars.map {
                scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar)
                    ? Character(String(scalar))
                    : "-"
            }
            let collapsed = String(scalars).split(separator: "-")
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            return collapsed.isEmpty
                ? CodexCoveUITests.fingerprint(value)
                : collapsed
        }
    }

    private func taskQueueRowIdentifier(_ sessionID: String) -> String {
        taskControlIdentifier(sessionID, control: "queue-row")
    }

    private func taskControlIdentifier(
        _ sessionID: String,
        control: String
    ) -> String {
        "cove.task.\(Self.fingerprint(sessionID)).\(control)"
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
