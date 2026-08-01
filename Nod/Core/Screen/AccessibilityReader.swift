import ApplicationServices
import Foundation

/// Reads the on-screen *text* of a running app from its accessibility tree.
///
/// Text, not pixels: the tree already carries labelled strings, so there is no
/// screenshot to render, no OCR to run, and nothing image-shaped to store. Apps
/// that draw into a canvas (Google Docs, some Electron shells) expose nothing
/// here — that is a known blind spot, not a bug to work around with capture.
struct AccessibilityReader {
    /// Depth cap. A conferencing window's participant list sits a handful of
    /// levels down; deeper walks cost time and add nothing but chrome.
    private let maxDepth: Int
    /// Ceiling on collected elements, so a pathological tree (Electron apps
    /// routinely expose thousands of nodes) cannot stall the walk.
    private let maxElements: Int
    /// Per-message ceiling on AX round trips. An unresponsive app would
    /// otherwise block the caller for the system default of 6 seconds.
    private let messagingTimeout: Float

    init(maxDepth: Int = 12, maxElements: Int = 2_000, messagingTimeout: Float = 0.2) {
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.messagingTimeout = messagingTimeout
    }

    /// Every non-empty string exposed by the app's windows, in traversal order.
    ///
    /// `windowTitleFilter` narrows the walk to the windows whose title it
    /// accepts. That is the whole reason browsers can be read at all: a native
    /// conferencing app *is* the meeting, but a browser holds the call in one
    /// window among many, and only that window is ours to look at.
    ///
    /// Blocking — call it off the main actor.
    func texts(forProcessID pid: pid_t, windowTitleFilter: ((String) -> Bool)? = nil) -> [String] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        guard let windows = copyElements(application, kAXWindowsAttribute) else { return [] }

        var collected: [String] = []
        var visited = 0
        for window in windows {
            if let windowTitleFilter {
                let title = copyString(window, kAXTitleAttribute) ?? ""
                guard windowTitleFilter(title) else { continue }
            }
            walk(window, depth: 0, visited: &visited, into: &collected)
        }
        return collected
    }

    /// The text of the one window the user is actually in.
    ///
    /// `texts(forProcessID:)` walks *every* window an app owns, which is what a
    /// roster needs and the opposite of what ambient capture needs: the other
    /// windows of a browser or a chat client are ones the user is not looking
    /// at, and merging them would both store unread windows and label the
    /// result with whichever title came last. Accessibility names the focused
    /// window directly, so ask for it instead of filtering after the fact.
    ///
    /// Blocking — call it off the main actor.
    func focusedWindowText(forProcessID pid: pid_t) -> (title: String, texts: [String])? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        // A window can be main without holding focus (a sheet is up, focus is in
        // a panel), and some apps expose only one of the two.
        guard let window = copyElement(application, kAXFocusedWindowAttribute)
            ?? copyElement(application, kAXMainWindowAttribute)
        else { return nil }

        var collected: [String] = []
        var visited = 0
        walk(window, depth: 0, visited: &visited, into: &collected)
        return (copyString(window, kAXTitleAttribute) ?? "", collected)
    }

    private func walk(_ element: AXUIElement, depth: Int, visited: inout Int, into collected: inout [String]) {
        guard depth <= maxDepth, visited < maxElements else { return }
        visited += 1

        for attribute in Self.textAttributes {
            guard let text = copyString(element, attribute), !text.isEmpty else { continue }
            collected.append(text)
        }

        guard let children = copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            walk(child, depth: depth + 1, visited: &visited, into: &collected)
        }
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static let textAttributes = [
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute
    ]
}
