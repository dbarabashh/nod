import AppKit

/// The hardware cut-out on one screen, or its absence.
///
/// A Mac without a notch — an external display, an Air before 2022, a Mac mini —
/// gets a free-standing rounded pill in the same place instead, so every code
/// path downstream has a surface to draw and only the silhouette changes.
struct NotchGeometry: Equatable {
    let cutoutWidth: CGFloat
    let cutoutHeight: CGFloat

    static let island = NotchGeometry(cutoutWidth: 0, cutoutHeight: 0)

    var hasCutout: Bool {
        cutoutWidth > 0
    }

    /// The resting surface — just wide enough to cover the cut-out on a notched
    /// Mac, a deliberate pill everywhere else.
    var collapsedSize: CGSize {
        guard hasCutout else { return CGSize(width: 168, height: 30) }
        return CGSize(width: cutoutWidth, height: cutoutHeight)
    }

    /// How far the top corners flare outward to meet the menu bar. Zero in
    /// island mode, where the surface floats free and has no bar to meet.
    var flare: CGFloat {
        hasCutout ? 10 : 0
    }
}

extension NSScreen {
    /// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` (macOS 12+) are the
    /// menu-bar strips either side of the cut-out; what's missing between them
    /// is the cut-out. Both read nil on a screen that has none, which is also
    /// how every external display answers.
    var nodNotchGeometry: NotchGeometry {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return .island
        }
        let width = frame.width - (left.width + right.width)
        guard width > 0, left.height > 0 else { return .island }
        return NotchGeometry(cutoutWidth: width, cutoutHeight: left.height)
    }

    /// Where the notch surface belongs: the display that actually has a cut-out,
    /// otherwise wherever the menu bar currently is.
    static var nodNotchHost: NSScreen? {
        screens.first { $0.nodNotchGeometry.hasCutout } ?? main ?? screens.first
    }
}
