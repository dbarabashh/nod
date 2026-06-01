import SwiftUI
import AppKit

final class FloatingPanel<Content: View>: NSPanel {
    init(contentRect: NSRect, content: Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        // Force dark appearance regardless of system theme — the SwiftUI
        // content is hardcoded white-on-dark (Theme.Palette.ink = frost,
        // borders = white.opacity(...)), so a light `.hudWindow` material
        // would leave the panel near-invisible for Light-mode users.
        self.appearance = NSAppearance(named: .vibrantDark)
        // Floating utility panels shouldn't be part of the user's screen-share.
        // Same default as Raycast / 1Password / Notification Center — the user's
        // private workspace doesn't bleed into the content they explicitly
        // shared with Zoom / Meet / Teams. Respected by all standard macOS
        // capture APIs (SCStream, CGWindowList, AVCaptureScreenInput).
        self.sharingType = .none
        self.collectionBehavior = [
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
        self.contentViewController = hostingController
        self.setContentSize(contentRect.size)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func positionOnLeftCenter(margin: CGFloat = 24) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = self.frame.size
        let origin = NSPoint(
            x: screenFrame.minX + margin,
            y: screenFrame.midY - size.height / 2
        )
        self.setFrameOrigin(origin)
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
        var newFrame = frame
        newFrame.size.width = newWidth
        setFrame(newFrame, display: true)
    }
}
