import AppKit
import ApplicationServices
import Foundation

enum CoveEditorWindowFocusMarker {
    private static let prefix = "Codex Cove editor window "

    static func make(focusSocketIdentifier: String) -> String? {
        guard focusSocketIdentifier.utf8.count == 12,
              focusSocketIdentifier.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102:
                      return true
                  default:
                      return false
                  }
              }) else {
            return nil
        }
        return prefix + focusSocketIdentifier
    }
}

@MainActor
enum CoveEditorWindowFocusing {
    private struct Match {
        let application: NSRunningApplication
        let applicationElement: AXUIElement
        let windowElement: AXUIElement
    }

    private enum SearchFailure: Error {
        case traversalLimit
    }

    private static let maximumTraversalElements = 25_000
    private static let maximumTraversalDepth = 64
    private static let verificationTimeout: TimeInterval = 1.5
    private static let verificationPollInterval: TimeInterval = 0.025

    static func focus(
        bundleIdentifier: String?,
        applicationName: String,
        focusSocketIdentifier: String
    ) -> Bool {
        guard AXIsProcessTrusted(),
              let marker = CoveEditorWindowFocusMarker.make(
                  focusSocketIdentifier: focusSocketIdentifier
              ) else {
            return false
        }

        let applications = candidateApplications(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )
        guard !applications.isEmpty else { return false }

        var match: Match?
        var remainingElements = maximumTraversalElements
        do {
            for application in applications {
                let applicationElement = AXUIElementCreateApplication(
                    application.processIdentifier
                )
                for window in copyElements(
                    from: applicationElement,
                    attribute: kAXWindowsAttribute as CFString
                ) {
                    let markerCount = try countMarkers(
                        window,
                        marker: marker,
                        depth: 0,
                        remainingElements: &remainingElements
                    )
                    if markerCount > 0 {
                        // The anchor is an exact window identity. Multiple
                        // matching anchors anywhere in the candidate editor
                        // processes are ambiguous, including duplicates in a
                        // single native window.
                        guard markerCount == 1, match == nil else {
                            return false
                        }
                        match = Match(
                            application: application,
                            applicationElement: applicationElement,
                            windowElement: window
                        )
                    }
                }
            }
        } catch {
            return false
        }

        guard let match else { return false }

        // These setters are not implemented uniformly by every Electron
        // release, so the raise and the final identity verification are the
        // authoritative checks.
        _ = AXUIElementSetAttributeValue(
            match.applicationElement,
            kAXFocusedWindowAttribute as CFString,
            match.windowElement
        )
        _ = AXUIElementSetAttributeValue(
            match.windowElement,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            match.windowElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard AXUIElementPerformAction(
            match.windowElement,
            kAXRaiseAction as CFString
        ) == .success,
        match.application.activate(options: []) else {
            return false
        }

        // Reassert after application activation so an already-frontmost editor
        // cannot keep a different window as its key window.
        _ = AXUIElementSetAttributeValue(
            match.applicationElement,
            kAXFocusedWindowAttribute as CFString,
            match.windowElement
        )
        _ = AXUIElementPerformAction(
            match.windowElement,
            kAXRaiseAction as CFString
        )

        let deadline = Date().addingTimeInterval(verificationTimeout)
        repeat {
            if isFocused(match) {
                return true
            }
            Thread.sleep(forTimeInterval: verificationPollInterval)
        } while Date() < deadline
        return false
    }

    private static func candidateApplications(
        bundleIdentifier: String?,
        applicationName: String
    ) -> [NSRunningApplication] {
        if let bundleIdentifier {
            guard isSafeBundleIdentifier(bundleIdentifier) else { return [] }
            return NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).filter { !$0.isTerminated }
        }
        guard !applicationName.isEmpty,
              applicationName.utf8.count <= 128 else {
            return []
        }
        return NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.localizedName == applicationName
        }
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 65...90, 97...122, 45, 46:
                    return true
                default:
                    return false
                }
            }
    }

    private static func countMarkers(
        _ element: AXUIElement,
        marker: String,
        depth: Int,
        remainingElements: inout Int
    ) throws -> Int {
        guard depth <= maximumTraversalDepth,
              remainingElements > 0 else {
            throw SearchFailure.traversalLimit
        }
        remainingElements -= 1

        var count = 0
        if copyString(from: element, attribute: kAXRoleAttribute as CFString)
            == (kAXButtonRole as String) {
            for attribute in [
                kAXTitleAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
                kAXIdentifierAttribute,
            ] {
                if copyString(from: element, attribute: attribute as CFString)
                    == marker {
                    // Count the accessible element once even when Electron
                    // exposes the same marker through several attributes.
                    count = 1
                    break
                }
            }
        }

        for child in copyElements(
            from: element,
            attribute: kAXChildrenAttribute as CFString
        ) {
            count += try countMarkers(
                child,
                marker: marker,
                depth: depth + 1,
                remainingElements: &remainingElements
            )
        }
        return count
    }

    private static func copyElements(
        from element: AXUIElement,
        attribute: CFString
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value)
            == .success,
        let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }

    private static func copyString(
        from element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value)
            == .success else {
            return nil
        }
        return value as? String
    }

    private static func isFocused(_ match: Match) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
            == match.application.processIdentifier else {
            return false
        }
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            match.applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success,
        let focusedWindow else {
            return false
        }
        return CFEqual(focusedWindow, match.windowElement)
    }
}
