import AppKit
import SwiftUI

/// The quick-access panel: one hotkey away from anywhere, search across every
/// session, ask across all of them.
///
/// Deliberately NOT a `FloatingPanel`. That one is built never to steal focus
/// (`becomesKeyOnlyIfNeeded`, shown with `orderFrontRegardless`), which is
/// exactly right for a HUD you glance at during a call — and exactly wrong
/// here, where the first thing you do is type. This panel activates the app,
/// becomes key, and hands focus back to whatever you were in when it closes.
final class LauncherPanel: NSPanel {
    /// The app that was frontmost when the panel opened, so Escape returns the
    /// user exactly where they were instead of leaving Nod activated.
    private var previousApp: NSRunningApplication?
    private var onDismiss: (() -> Void)?

    static let width: CGFloat = 680
    /// Fraction of the screen height the panel's top edge sits at — above
    /// centre, where a launcher is expected and where it doesn't cover the
    /// window the user is reading.
    private static let verticalAnchor: CGFloat = 0.28

    init(content: some View, sharing: NSWindow.SharingType, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            // Non-activating keeps the app out of the Dock/⌘-Tab churn while
            // `canBecomeKey` (below) still lets the field take the caret.
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        // Safe here, unlike on `FloatingPanel`: that panel is a transparent
        // window holding separate pills, so a window shadow traces each one and
        // haloes them. This window IS the card — a single rounded, masked
        // surface filling its bounds — so AppKit derives one correct shadow
        // from its alpha.
        hasShadow = true
        // The whole point is to take the caret on appear, without a click.
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        acceptsMouseMovedEvents = true
        // Content is hardcoded white-on-dark, same as the floating panel.
        appearance = NSAppearance(named: .vibrantDark)
        // Follows the same "Visible when sharing" preference as the floating
        // panel — one switch for every Nod surface that can appear over a
        // shared screen, rather than a second rule the user has to discover.
        sharingType = sharing
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingController(rootView: content)
        hosting.view.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) {
            hosting.sizingOptions = [.preferredContentSize]
        }
        contentViewController = hosting
    }

    override var canBecomeKey: Bool {
        true
    }

    /// Never main: main-window status belongs to the Library/Settings windows,
    /// and taking it would swap the app's menu-bar context for a transient bar.
    override var canBecomeMain: Bool {
        false
    }

    /// Escape closes. The panel is borderless with no close button, so this is
    /// the only keyboard way out; `cancelOperation` is what AppKit routes both
    /// Escape and ⌘. through.
    override func cancelOperation(_: Any?) {
        dismiss()
    }

    func present() {
        // Remember who had focus before we take it — but only when we're not
        // already the active app, or reopening would record Nod itself.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }
        // Lay the SwiftUI content out first: the panel is created at a
        // placeholder height and only takes its real size once hosted, so
        // centring before that lands it noticeably off.
        contentViewController?.view.layoutSubtreeIfNeeded()
        anchorScreen = screenUnderPointer()
        recentre()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Every resize re-centres, whoever caused it.
    ///
    /// The content decides the panel's size — SwiftUI's hosting controller
    /// pushes a new frame as results and answers arrive, and it does that
    /// through `setFrame`, not `setContentSize`. A frame set from the old
    /// origin grows the panel to the right, which is the drift: the panel is
    /// centred when it opens and off-centre by the time it has content.
    /// Rewriting the origin here (rather than re-centring afterwards) keeps it
    /// centred within the same layout pass, with no recursion and no visible
    /// jump.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard isVisible, let visible = (anchorScreen ?? screenUnderPointer())?.visibleFrame else {
            super.setFrame(frameRect, display: flag)
            return
        }
        var rect = frameRect
        rect.origin = centredOrigin(for: rect.size, in: visible)
        super.setFrame(rect, display: flag)
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        onDismiss?()
        // Hand focus back rather than leaving an accessory app activated with
        // no visible window — the user's context is the app they came from.
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// Clicking away is a dismissal, the same as Escape.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// The screen the panel opened on, so growing content can't walk it onto a
    /// neighbouring display mid-session.
    private var anchorScreen: NSScreen?

    /// The screen with the pointer — that's the one the user is working on.
    /// `NSScreen.main` is the key window's screen and would drop the panel on
    /// the wrong display in a multi-monitor setup.
    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func recentre() {
        guard let visible = (anchorScreen ?? screenUnderPointer())?.visibleFrame else { return }
        setFrameOrigin(centredOrigin(for: frame.size, in: visible))
    }

    private func centredOrigin(for size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.maxY - visible.height * Self.verticalAnchor - size.height).rounded()
        )
    }
}
