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
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        let hostingController = NSHostingController(rootView: content)
        hostingController.view.frame = NSRect(origin: .zero, size: contentRect.size)
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
