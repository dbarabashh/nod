import SwiftUI

/// The silhouette of a surface hanging off the menu bar: the top corners flare
/// *outward* so the surface's edges meet the flat bar tangentially instead of at
/// a visible corner, and the bottom corners are ordinary rounded ones.
///
/// `flare` doubles as a horizontal inset — the body occupies the rect minus
/// `flare` on each side, and the two top curves fill that margin. Callers size
/// the rect to the body width plus `2 * flare` (see `NotchPresentation.surfaceSize`).
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set {
            flare = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let flare = max(0, min(flare, rect.width / 2))
        let bodyLeft = rect.minX + flare
        let bodyRight = rect.maxX - flare
        let bottom = max(0, min(bottomRadius, min(rect.height - flare, (bodyRight - bodyLeft) / 2)))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: rect.minY + flare),
            control: CGPoint(x: bodyLeft, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyLeft, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft + bottom, y: rect.maxY),
            control: CGPoint(x: bodyLeft, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRight - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.maxY - bottom),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRight, y: rect.minY + flare))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

extension NotchGeometry {
    /// The silhouette this screen calls for: notch-shaped where there's a
    /// cut-out to blend into, a plain rounded rectangle where there isn't.
    ///
    /// Type-erased so the two branches share one modifier chain at the call
    /// site. Safe to erase here: which branch applies is a property of the
    /// display, so it never flips mid-animation — only `bottomRadius` does, and
    /// that interpolates inside whichever concrete shape is in play.
    func surfaceShape(bottomRadius: CGFloat) -> AnyShape {
        guard hasCutout else {
            return AnyShape(RoundedRectangle(cornerRadius: bottomRadius, style: .continuous))
        }
        return AnyShape(NotchShape(flare: flare, bottomRadius: bottomRadius))
    }
}
