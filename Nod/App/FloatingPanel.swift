import AppKit
import SwiftUI

final class FloatingPanel<Content: View>: NSPanel {
    // The currently open header menu (modes / mic / language), if any. SwiftUI
    // `Menu` is a native NSMenu popup anchored to its button; when the panel is
    // dragged via `isMovableByWindowBackground` the popup desyncs and appears to
    // lag behind the moving panel. Dragging is the user's intent to reposition,
    // so the open menu is dismissed the instant the panel starts moving.
    private weak var trackingMenu: NSMenu?
    /// Set by `positionOnTopRight`. While it holds, every resize re-anchors to
    /// that corner instead of growing downward from a stale origin.
    private var topRightMargin: CGFloat?

    /// `sizesToContent` hands the height to SwiftUI. The capture panel does the
    /// opposite — it drives its own width through `animateWidth`, and a hosting
    /// controller pushing sizes back would fight that — but a card whose height
    /// depends on how its text wraps has no size the caller can know in advance.
    init(contentRect: NSRect, content: Content, sizesToContent: Bool = false) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // ARC owns this window through the coordinator's reference, and AppKit's
        // default would release it again on `close()`. Harmless for the capture
        // panel, which is closed once at sign-out; not harmless for the
        // detection card, which is closed and rebuilt for every call.
        isReleasedWhenClosed = false
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        // The panel is transparent and its content is separate floating pills,
        // not one contiguous surface. A window shadow traces each opaque pill
        // individually, drawing a dark halo around every pill that's glaring
        // over light backgrounds. Depth comes from the pills' own SwiftUI
        // shadows instead.
        hasShadow = false
        // A card that re-anchors on every resize would snap back mid-drag, so
        // the two behaviours are mutually exclusive: the panel you keep is
        // draggable, the card that appears for a minute is not.
        isMovableByWindowBackground = !sizesToContent
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Deliver mouse-moved / cursor-update events even while the panel isn't
        // the key window. Without this, `pointerStyle(.link)` (.linkCursor) on
        // the pills can't update the pointer on a non-activating accessory-app
        // panel, and the cursor appears to vanish over hovered controls.
        acceptsMouseMovedEvents = true
        // Force dark appearance regardless of system theme — the SwiftUI
        // content is hardcoded white-on-dark (Theme.Palette.ink = frost,
        // borders = white.opacity(...)), so a light `.hudWindow` material
        // would leave the panel near-invisible for Light-mode users.
        appearance = NSAppearance(named: .vibrantDark)
        // Floating utility panels shouldn't be part of the user's screen-share
        // by default. Same default as Raycast / 1Password / Notification Center —
        // the user's private workspace doesn't bleed into the content they
        // explicitly shared with Zoom / Meet / Teams. Respected by all standard
        // macOS capture APIs (SCStream, CGWindowList, AVCaptureScreenInput).
        // AppDelegate overrides this from PanelSharingPreference when the user
        // opts the panel into screen shares (e.g. presenting with Nod on screen).
        sharingType = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        let hostingController = NSHostingController(rootView: content)
        // The panel's width is driven explicitly (animateWidth); the SwiftUI
        // content fills whatever size the window is. Clear sizingOptions so the
        // controller doesn't try to push the content's own preferred size back
        // onto the window — with flexible-width content that size is undefined
        // and would fight the resize animation.
        // Sized by the content, or by the caller — never half of each.
        if sizesToContent, #available(macOS 13.3, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        } else {
            hostingController.sizingOptions = []
        }
        hostingController.view.frame = NSRect(origin: .zero, size: contentRect.size)
        hostingController.view.autoresizingMask = [.width, .height]
        contentViewController = hostingController
        setContentSize(contentRect.size)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuDidBeginTracking(_ note: Notification) {
        trackingMenu = note.object as? NSMenu
    }

    @objc private func panelDidMove(_ note: Notification) {
        NotificationCenter.default.post(name: .nodPanelDidMove, object: self)
        if let menu = trackingMenu {
            trackingMenu = nil
            menu.cancelTrackingWithoutAnimation()
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Top-right, where macOS itself puts things that ask for a moment of
    /// attention — and the opposite corner from the capture panel, so a
    /// detection card never lands on top of it.
    func positionOnTopRight(margin: CGFloat = 12) {
        topRightMargin = margin
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(Self.topRightOrigin(for: frame.size, in: visible, margin: margin))
    }

    /// The content decides the height, and SwiftUI applies it through
    /// `setFrame` from the existing origin — which grows the card downward off
    /// its corner. Rewriting the origin here keeps it anchored within the same
    /// layout pass, with no second pass and no visible jump.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard let topRightMargin, let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            super.setFrame(frameRect, display: flag)
            return
        }
        var rect = frameRect
        rect.origin = Self.topRightOrigin(for: rect.size, in: visible, margin: topRightMargin)
        super.setFrame(rect, display: flag)
    }

    private static func topRightOrigin(for size: NSSize, in visible: NSRect, margin: CGFloat) -> NSPoint {
        NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
    }

    func positionOnLeftCenter(margin: CGFloat = 24) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: screenFrame.minX + margin,
            y: screenFrame.midY - size.height / 2
        )
        setFrameOrigin(origin)
    }
}

extension NSWindow {
    /// Sets the window width, keeping the left edge fixed so anchored content
    /// never jumps — it only grows or shrinks to the right. Applied instantly
    /// (no animation) on purpose: animating the window width while the SwiftUI
    /// content's width changes in lockstep leaves frames where the content is
    /// wider than the window, which NSHostingController renders as content
    /// sliding/clipping. A snap keeps window and content size consistent at
    /// every step; the response card's own fade softens the transition.
    func setWidth(to newWidth: CGFloat) {
        guard frame.size.width != newWidth else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, frame.size.width != newWidth else { return }
            var newFrame = frame
            newFrame.size.width = newWidth
            setFrame(newFrame, display: true)
        }
    }

    /// Repaints the whole content view. The panel is transparent, buffered, and
    /// fixed-height, so when SwiftUI swaps tall content for shorter content the
    /// exposed region keeps stale pixels in the backing store until the next
    /// incidental redraw. Marking the content dirty and forcing a display clears
    /// it. Deferred to the next runloop so it runs AFTER SwiftUI has committed
    /// the new layout (repainting before that would just redraw the old content).
    func forceRedraw() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            contentView?.needsDisplay = true
            displayIfNeeded()
        }
    }
}
