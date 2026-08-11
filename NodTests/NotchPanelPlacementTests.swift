import XCTest
@testable import Nod

/// The canvas is 460×460 and almost entirely transparent; the surface the user
/// actually sees is a small pill top-centred inside it. Clamping has to keep
/// *that* on screen, which is why it can't just fence the window frame.
final class NotchPanelPlacementTests: XCTestCase {
    private let canvas = CGSize(width: 460, height: 460)
    private let surface = CGSize(width: 132, height: 26)
    private let topInset: CGFloat = 30
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 850)

    private func clamp(_ origin: CGPoint) -> NSPoint {
        NotchPanel.clampedOrigin(origin, canvas: canvas, surface: surface, topInset: topInset, visible: visible)
    }

    func testAPositionInsideTheScreenIsLeftAlone() {
        let origin = CGPoint(x: 400, y: 300)
        XCTAssertEqual(clamp(origin), NSPoint(x: 400, y: 300))
    }

    /// The pill sits 164pt in from the canvas's left edge, so the canvas has to
    /// be allowed to hang that far off-screen before the pill itself would.
    func testTheCanvasMayHangOffTheLeftSoThePillReachesTheEdge() {
        let clamped = clamp(CGPoint(x: -10_000, y: 300))
        XCTAssertEqual(clamped.x, -164)
    }

    func testTheCanvasMayHangOffTheBottomSoThePillReachesIt() {
        // Pill top is `topInset` below the canvas top, so 460 - 30 - 26 = 404pt
        // of empty canvas sits under it.
        let clamped = clamp(CGPoint(x: 400, y: -10_000))
        XCTAssertEqual(clamped.y, -404)
    }

    func testAPositionFromALargerDisplayIsPulledBackOnScreen() {
        // Saved on a 3440-wide monitor, restored on the 1440-wide built-in.
        let clamped = clamp(CGPoint(x: 3_000, y: 300))
        XCTAssertEqual(clamped.x, visible.maxX - 164 - surface.width)
    }

    /// A visible frame narrower than the surface leaves no valid range at all;
    /// the clamp must not invert its own bounds and fling the panel away.
    func testADisplaySmallerThanTheSurfaceStillYieldsAPointOnIt() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 20)
        let clamped = NotchPanel.clampedOrigin(
            CGPoint(x: 5_000, y: 5_000),
            canvas: canvas,
            surface: surface,
            topInset: topInset,
            visible: tiny
        )
        XCTAssertEqual(clamped.x, -164)
        XCTAssertEqual(clamped.y, -404)
    }
}
