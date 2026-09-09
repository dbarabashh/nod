import AppKit

/// The hardware cut-out on one screen, or its absence.
///
/// Two genuinely different surfaces come out of this, not one with a tweak. With
/// a cut-out, Nod continues the machine: the shape hangs *from* the bezel, fills
/// dead space, and wears no outline because an outline would give the illusion
/// away. Without one — every external display, and every Mac older than 2021 —
/// there is no dead space to occupy and no bezel to continue, so it stops
/// pretending: a floating card that sits *below* the menu bar and admits it is
/// an app.
struct NotchGeometry: Equatable {
    let cutoutWidth: CGFloat
    let cutoutHeight: CGFloat
    /// How much of the top of the screen the menu bar owns. Only meaningful
    /// without a cut-out, where it is what the surface has to clear.
    let menuBarHeight: CGFloat

    static let island = NotchGeometry(cutoutWidth: 0, cutoutHeight: 0, menuBarHeight: 24)

    var hasCutout: Bool {
        cutoutWidth > 0
    }

    /// What folding the bar away is called here. The cut-out is a place; the
    /// floating panel is not, so "tuck into the notch" would name something that
    /// is not on this user's screen. Lives on the geometry because that is what
    /// the answer depends on — both bars ask it, and neither should own it.
    var tuckLabel: String {
        hasCutout ? "Tuck into the notch" : "Minimize"
    }

    /// The resting surface. With a cut-out it must cover the hardware exactly
    /// — a pixel of daylight around a notch is instantly visible — and reach
    /// the bottom of the menu bar, which on recent macOS sits a couple of
    /// points below the notch; a surface cut to the notch alone left its
    /// lower edge showing under a wider pill. Without a cut-out it is a
    /// compact pill, sized for a glance rather than to cover anything.
    var collapsedSize: CGSize {
        guard hasCutout else { return CGSize(width: 132, height: 26) }
        return CGSize(width: cutoutWidth, height: max(cutoutHeight, menuBarHeight))
    }

    /// How far the top corners flare outward to meet the menu bar. Zero without
    /// a cut-out: nothing to meet, and a flare on a free-floating card reads as
    /// a rendering fault.
    var flare: CGFloat {
        hasCutout ? 10 : 0
    }

    /// Where the surface starts, measured down from the top of the screen.
    ///
    /// Zero with a cut-out — it hangs from the very top, through the bezel.
    /// Without one it clears the menu bar entirely, because the middle of that
    /// bar is not dead space: on a wide app it is still menu titles, and in a
    /// full-screen call it is the content itself.
    var topInset: CGFloat {
        hasCutout ? 0 : menuBarHeight + 6
    }

    /// A free-floating card needs a hairline at rest; a shape continuing the
    /// bezel must not have one.
    var showsEdgeAtRest: Bool {
        !hasCutout
    }
}

extension NSScreen {
    /// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (macOS 12+) are the
    /// menu-bar strips either side of the cut-out; what's missing between them
    /// is the cut-out. Both read nil on a screen that has none, which is also
    /// how every external display answers.
    var nodNotchGeometry: NotchGeometry {
        let menuBar = max(0, frame.maxY - visibleFrame.maxY)
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return NotchGeometry(cutoutWidth: 0, cutoutHeight: 0, menuBarHeight: menuBar)
        }
        let width = frame.width - (left.width + right.width)
        guard width > 0, left.height > 0 else {
            return NotchGeometry(cutoutWidth: 0, cutoutHeight: 0, menuBarHeight: menuBar)
        }
        return NotchGeometry(cutoutWidth: width, cutoutHeight: left.height, menuBarHeight: menuBar)
    }

    /// The same screen seen as though it had no cut-out — what the preview
    /// toggle shows, and what every external display genuinely is.
    var nodIslandGeometry: NotchGeometry {
        NotchGeometry(
            cutoutWidth: 0,
            cutoutHeight: 0,
            menuBarHeight: max(0, frame.maxY - visibleFrame.maxY)
        )
    }

    /// Where the notch surface belongs: the display that actually has a cut-out,
    /// otherwise wherever the menu bar currently is.
    static var nodNotchHost: NSScreen? {
        screens.first { $0.nodNotchGeometry.hasCutout } ?? main ?? screens.first
    }
}
