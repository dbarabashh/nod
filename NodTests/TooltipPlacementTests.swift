import XCTest
@testable import Nod

/// The hover card is positioned against its anchor, and the anchor can be one
/// 20pt glyph from the container's edge — which is how the notch's rightmost
/// control ended up with its hint sliced in half by the surface it sits on.
final class TooltipPlacementTests: XCTestCase {
    private let container: CGFloat = 380

    private func glyph(atMidX midX: CGFloat) -> CGRect {
        CGRect(x: midX - 10, y: 30, width: 20, height: 20)
    }

    func testCompactCardCentresOnItsControl() {
        let left = TooltipSpace.leftEdge(
            for: glyph(atMidX: 190), cardWidth: 120, containerWidth: container, isCompact: true
        )
        XCTAssertEqual(left + 60, 190, accuracy: 0.01)
    }

    func testCardNeverRunsPastTheRightEdge() {
        let left = TooltipSpace.leftEdge(
            for: glyph(atMidX: 366), cardWidth: 130, containerWidth: container, isCompact: true
        )
        XCTAssertLessThanOrEqual(left + 130, container - TooltipSpace.sideMargin + 0.01)
        XCTAssertGreaterThanOrEqual(left, TooltipSpace.sideMargin)
    }

    func testCardNeverRunsPastTheLeftEdge() {
        let left = TooltipSpace.leftEdge(
            for: glyph(atMidX: 14), cardWidth: 130, containerWidth: container, isCompact: true
        )
        XCTAssertEqual(left, TooltipSpace.sideMargin, accuracy: 0.01)
    }

    /// A full card hangs off the anchor's left edge rather than centring, so a
    /// list of rows keeps its hints aligned with the text they explain.
    func testFullCardStartsAtTheAnchor() {
        let anchor = CGRect(x: 40, y: 200, width: 90, height: 22)
        let left = TooltipSpace.leftEdge(
            for: anchor, cardWidth: 200, containerWidth: container, isCompact: false
        )
        XCTAssertEqual(left, 40, accuracy: 0.01)
    }

    /// A card wider than what it's drawn in can only be pinned to one side; the
    /// left one, so the text starts where it can be read.
    func testCardWiderThanTheContainerPinsLeft() {
        let left = TooltipSpace.leftEdge(
            for: glyph(atMidX: 100), cardWidth: 500, containerWidth: container, isCompact: true
        )
        XCTAssertEqual(left, TooltipSpace.sideMargin, accuracy: 0.01)
    }

    /// The compact card measures narrow enough that centring it on the last
    /// control in the notch's row doesn't need clamping in the first place.
    func testNotchHintsFitTheSurface() {
        for hint in [
            "Mute · hold to switch",
            "Nod answers in English",
            "Hidden from screen shares",
            "Open Nod window",
            "Tuck into the notch",
            "Open in Nod",
            "Copy summary"
        ] {
            let width = TooltipCard.width(text: hint, detail: nil, icon: nil, isCompact: true)
            XCTAssertLessThan(width, 160, "\(hint) is too wide for a glyph-sized control")
        }
    }
}
