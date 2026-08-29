import AppKit
import SwiftUI

/// The window the notch surface lives in: a transparent canvas pinned to the
/// top centre of the screen, sitting above the menu bar.
///
/// The canvas is a fixed size and **never resizes**. Every state change is a
/// SwiftUI shape animating inside it, which is what lets the surface morph on a
/// spring — a window resized in step with its content leaves frames where the
/// two disagree, which AppKit renders as the content sliding or clipping. It is
/// also why nothing here needs the manual repaint the old floating panel did.
final class NotchPanel: NSPanel {
    /// Wide enough for the largest `NotchPresentation` plus room for the
    /// surface's shadow, and no wider: the canvas is transparent but it is still
    /// a window over the menu bar, and anything past this sits on top of the
    /// menu titles and the status items either side.
    ///
    /// The height is generous rather than measured because opened states are
    /// content-sized on purpose (`NotchPresentation.surfaceHeight`) — a wrapped
    /// line or a larger system text size grows the surface, and a canvas cut to
    /// today's tallest state would clip it. The consent gate is the one that
    /// matters: its buttons are what the user has to be able to reach.
    static let canvasSize = NSSize(width: 460, height: 460)

    init(content: some View, sharing: NSWindow.SharingType) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // ARC owns this through the controller; AppKit's default would release
        // it a second time on `close()`.
        isReleasedWhenClosed = false
        // Above `.mainMenu`, or the menu bar draws over the surface that is
        // supposed to be hanging off it.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        // The surface draws its own shadow so it can follow the animating
        // silhouette. A window shadow would trace the transparent canvas's
        // bounds instead and lag a frame behind every morph.
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Cursor and hover changes have to arrive while the panel isn't key —
        // it never becomes key on its own, being a non-activating accessory
        // window, and without this the pointer stops updating over controls.
        acceptsMouseMovedEvents = true
        // The one surface that does NOT follow the Appearance setting. It hangs
        // off the cut-out and has to read as part of the machine — a light
        // shape growing out of a black bezel reads as a window sitting on the
        // screen, which is the illusion this whole surface exists to avoid.
        appearance = NSAppearance(named: .vibrantDark)
        sharingType = sharing
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        // Hosted as a view rather than a view controller: a controller derives
        // the window's size from the content, which is exactly the resize this
        // design avoids.
        let hosting = NotchHostingView(rootView: AnyView(content))
        hosting.frame = NSRect(origin: .zero, size: Self.canvasSize)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Centre the canvas on the screen's cut-out and hang it from the top edge.
    /// Called on creation and again whenever the display arrangement changes.
    func anchor(to screen: NSScreen) {
        let frame = screen.frame
        setFrameOrigin(
            NSPoint(
                x: floor(frame.midX - Self.canvasSize.width / 2),
                y: frame.maxY - Self.canvasSize.height
            )
        )
    }

    /// Put the canvas back where the user left it, or at the default anchor if
    /// they never moved it on this display. The saved point is clamped rather
    /// than trusted: a display that changed resolution, or one whose arrangement
    /// moved it in the global coordinate space, can strand a perfectly valid
    /// old position off-screen.
    func restore(_ origin: CGPoint?, on screen: NSScreen, geometry: NotchGeometry) {
        guard let origin else {
            anchor(to: screen)
            return
        }
        setFrameOrigin(Self.clampedOrigin(
            origin,
            canvas: Self.canvasSize,
            surface: geometry.collapsedSize,
            topInset: geometry.topInset,
            visible: screen.visibleFrame
        ))
    }

    /// Dragging is the floating panel's alone — see `CaptureSurfacePreference`.
    /// `isMovableByWindowBackground` rather than a drag handle: the canvas is
    /// transparent everywhere the surface isn't, so the only draggable area is
    /// the surface itself, and AppKit's own drag threshold leaves clicks on the
    /// controls alone.
    func setMovable(_ movable: Bool) {
        isMovable = movable
        isMovableByWindowBackground = movable
    }

    /// Where the canvas may sit so that the resting surface stays fully on
    /// screen. The canvas is far larger than the surface and mostly empty, so
    /// clamping the canvas itself would fence the surface hundreds of points
    /// away from every edge — what has to stay reachable is the pill, which
    /// sits top-centred inside the canvas.
    static func clampedOrigin(
        _ origin: CGPoint,
        canvas: CGSize,
        surface: CGSize,
        topInset: CGFloat,
        visible: CGRect
    ) -> NSPoint {
        let offsetX = (canvas.width - surface.width) / 2
        let offsetY = canvas.height - topInset - surface.height
        // A visible frame smaller than the surface has no valid range at all;
        // `min` after `max` would then silently invert the bounds.
        let minX = visible.minX - offsetX
        let maxX = max(minX, visible.maxX - offsetX - surface.width)
        let minY = visible.minY - offsetY
        let maxY = max(minY, visible.maxY - offsetY - surface.height)
        return NSPoint(
            x: floor(min(max(origin.x, minX), maxX)),
            y: floor(min(max(origin.y, minY), maxY))
        )
    }
}

/// Hosting view that takes a click, and the keyboard, without the app being
/// activated first.
///
/// Without `acceptsFirstMouse` a click on an inactive app's window only
/// activates it, and the button the user was aiming at needs a second click.
/// The notch is pressed while the user is in a call, in another app, and every
/// one of its controls is a single deliberate action.
///
/// `acceptsFirstResponder` is what lets the surface take the keyboard once the
/// panel is key — the consent and language gates bind Return and Escape
/// (`.defaultAction` / `.cancelAction`), and a view that refuses first
/// responder never sees them.
private final class NotchHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor @objc dynamic required init?(coder: NSCoder) {
        fatalError("NotchHostingView is created in code, never from a nib")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
