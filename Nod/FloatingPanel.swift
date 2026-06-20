import AppKit
import SwiftUI

final class FloatingPanel<Content: View>: NSPanel {
    init(contentRect: NSRect, content: Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        // The panel is transparent and its content is separate floating pills,
        // not one contiguous surface. A window shadow traces each opaque pill
        // individually, drawing a dark halo around every pill that's glaring
        // over light backgrounds. Depth comes from the pills' own SwiftUI
        // shadows instead.
        hasShadow = false
        isMovableByWindowBackground = true
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
        hostingController.sizingOptions = []
        hostingController.view.frame = NSRect(origin: .zero, size: contentRect.size)
        hostingController.view.autoresizingMask = [.width, .height]
        contentViewController = hostingController
        setContentSize(contentRect.size)
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
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
