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

    /// The timeout only binds the walk when it is set on the *system-wide*
    /// element. `AXUIElementSetMessagingTimeout` applies to the object it is
    /// given and nothing else, so setting it on the application element — as
    /// this did — left every window and child on the 6-second global default,
    /// which is the stall it exists to prevent.
    private func boundMessaging() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    /// Every non-empty string exposed by the app's windows, in traversal order.
    ///
    /// `windowTitleFilter` narrows the walk to the windows whose title it
    /// accepts. That is the whole reason browsers can be read at all: a native
    /// conferencing app *is* the meeting, but a browser holds the call in one
    /// window among many, and only that window is ours to look at.
    ///
    /// `descendingInto` reads only the subtree under the first element with
    /// that accessibility role, and nothing above it. A browser passes
    /// `AXWebArea` so the page is read without the toolbar, the tab strip or the
    /// bookmarks bar — without it a call in a browser reports the *browser's*
    /// labels as participants: a Google Meet call came back as "Back, Forward,
    /// Reload, Extensions, Bookmarks, Tab Search" plus the names of the user's
    /// bookmarks, sixteen of them, not one a person. No blocklist can fix that,
    /// since bookmarks are arbitrary text. A window with no such role is read as
    /// nothing rather than as furniture.
    ///
    /// Blocking — call it off the main actor.
    func texts(
        forProcessID pid: pid_t,
        windowTitleFilter: ((String) -> Bool)? = nil,
        descendingInto role: String? = nil
    ) -> [String] {
        boundMessaging()
        let application = AXUIElementCreateApplication(pid)

        guard let windows = copyElements(application, kAXWindowsAttribute) else { return [] }

        var collected: [String] = []
        var visited = 0
        for window in windows {
            if let windowTitleFilter {
                let title = copyString(window, kAXTitleAttribute) ?? ""
                guard windowTitleFilter(title) else { continue }
            }
            let root = role.map { firstDescendant(of: window, role: $0) } ?? window
            guard let root else { continue }
            walk(root, depth: 0, visited: &visited, into: &collected)
        }
        return collected
    }

    /// Breadth-first: the page sits a couple of levels under the window while
    /// the toolbar beside it is the deepest thing there, so depth-first would
    /// walk all of the chrome before finding any of the content.
    ///
    /// On a budget of its own, separate from the walk's. Sharing one made the
    /// search's cost the collection's loss — and a search that spent the budget
    /// returned nil, so the window read as *nothing at all* rather than as the
    /// page.
    private func firstDescendant(of window: AXUIElement, role: String) -> AXUIElement? {
        var queue = [window]
        var index = 0
        while index < queue.count, index < Self.descentBudget {
            let element = queue[index]
            index += 1
            if copyString(element, kAXRoleAttribute) == role { return element }
            // Only what the budget can still reach: one level of a browser
            // window is hundreds of children, and every one of them costs an
            // IPC round trip to fetch and is retained until the search ends.
            let remaining = Self.descentBudget - queue.count
            guard remaining > 0 else { continue }
            queue += copyChildren(element, limit: remaining)
        }
        return nil
    }

    /// Enough to cross a browser's chrome and no more. Past this the search
    /// would be walking the page's own contents, which is the walk's job.
    private static let descentBudget = 400

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
    func focusedWindowText(
        forProcessID pid: pid_t,
        bundleID: String = ""
    ) -> (title: String, url: String?, texts: [String])? {
        boundMessaging()
        let application = AXUIElementCreateApplication(pid)

        // A window can be main without holding focus (a sheet is up, focus is in
        // a panel), and some apps expose only one of the two.
        guard let window = copyElement(application, kAXFocusedWindowAttribute)
            ?? copyElement(application, kAXMainWindowAttribute)
        else { return nil }

        var collected: [String] = []
        var visited = 0
        walk(window, depth: 0, visited: &visited, into: &collected)
        let url = Self.exposesPageURL(bundleID: bundleID) ? pageURL(of: window) : nil
        return (copyString(window, kAXTitleAttribute) ?? "", url, collected)
    }

    /// The address of the page in a browser window, when there is one.
    ///
    /// The blocklist matches on the window title, and a title is whatever the
    /// page chose to call itself — a bank whose tab reads "Dashboard" slips
    /// past every domain the user typed in. The web area names the actual URL,
    /// so the exclusion can be checked against the thing the user excluded.
    private func pageURL(of window: AXUIElement) -> String? {
        if let direct = copyURL(window, kAXURLAttribute) { return direct }
        guard let area = firstDescendant(of: window, role: Self.webAreaRole) else { return nil }
        return copyURL(area, kAXURLAttribute)
    }

    /// Whether looking for a web area in this app is worth the search.
    ///
    /// Finding one costs a breadth-first walk of up to `descentBudget`
    /// elements, and in Word, Finder or a terminal that walk runs to the end
    /// and returns nothing — every tick, all day. A list of bundle ids goes
    /// stale in the direction that costs nothing: an unlisted browser falls
    /// back to matching the exclusion on the title, which is what every app did
    /// before this existed.
    static func exposesPageURL(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "ai.perplexity.comet",
        "com.openai.atlas"
    ]

    /// Not an SDK constant — `AXWebArea` is declared in no public header, so the
    /// role travels as a string here the same way it does at the call sites.
    static let webAreaRole = "AXWebArea"

    private func walk(_ element: AXUIElement, depth: Int, visited: inout Int, into collected: inout [String]) {
        guard depth <= maxDepth, visited < maxElements else { return }
        visited += 1

        collected.append(contentsOf: copyStrings(element, Self.textAttributes))

        guard let children = copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            walk(child, depth: depth + 1, visited: &visited, into: &collected)
        }
    }

    /// Every requested attribute in one round trip.
    ///
    /// Each `AXUIElementCopyAttributeValue` is a synchronous IPC call into the
    /// target process, and the walk makes one per attribute per element — four
    /// on every node of a 2000-element budget. Asking for them together is the
    /// same information for a quarter of the traffic.
    ///
    /// With no options, an attribute the element doesn't support comes back as
    /// `CFNull` or a wrapped `AXError` in its own position, so the cast is what
    /// filters them and the positions still line up.
    private func copyStrings(_ element: AXUIElement, _ attributes: [String]) -> [String] {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(),
            &values
        )
        guard status == .success, let values = values as? [Any] else { return [] }
        return values.compactMap { value in
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func copyURL(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
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

    /// At most `limit` children, fetched as a range rather than as a whole
    /// array. `AXUIElementCopyAttributeValues` exists for exactly this — the
    /// docs call out large arrays — and the search only ever looks at the front
    /// of the queue.
    private func copyChildren(_ element: AXUIElement, limit: Int) -> [AXUIElement] {
        var values: CFArray?
        let status = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &values)
        guard status == .success else { return [] }
        return values as? [AXUIElement] ?? []
    }

    private func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    /// Selection leads: what the user highlighted is the strongest statement of
    /// intent accessibility exposes, and if the capture is truncated it is the
    /// part worth keeping.
    private static let textAttributes = [
        kAXSelectedTextAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute
    ]
}
