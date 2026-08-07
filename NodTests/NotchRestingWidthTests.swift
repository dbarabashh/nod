import XCTest
@testable import Nod

/// The resting demo bar draws its label with `.fixedSize()`, so a label wider
/// than its half is not truncated — it keeps drawing, straight under the
/// hardware cut-out, where nobody can read it and nothing on screen says
/// anything went wrong. This is the check that used to be a hardcoded number.
final class NotchRestingWidthTests: XCTestCase {
    private let notched = NotchGeometry(cutoutWidth: 200, cutoutHeight: 32, menuBarHeight: 24)

    /// What each half of the bar actually gets, after the cut-out and the bar's
    /// own padding are taken out of the surface.
    private func halfWidth(for stage: DemoStage) -> CGFloat {
        guard let surface = NotchPresentation.demo(stage).surfaceWidth(in: notched) else {
            return .nan
        }
        let padding = (notched.flare + DemoRestingBar.inset) * 2
        return (surface - notched.cutoutWidth - padding) / 2
    }

    func testTheLabelFitsBesideTheCutout() {
        let stage = DemoStage.listening("Following along")
        XCTAssertGreaterThanOrEqual(halfWidth(for: stage), stage.restingSideWidth)
    }

    func testALongerLabelWidensTheSurfaceRatherThanOverflowing() {
        let stage = DemoStage.listening("Following along and keeping track of what was decided")
        XCTAssertGreaterThanOrEqual(halfWidth(for: stage), stage.restingSideWidth)
    }

    func testTheClockSideIsNeverStarvedByAShortLabel() {
        // Both halves are `maxWidth: .infinity`, so the narrower content still
        // gets the same width — the clock must survive a one-word label.
        let stage = DemoStage.listening("Listening")
        XCTAssertGreaterThanOrEqual(halfWidth(for: stage), DemoStage.restingClockWidth)
    }

    func testAScreenWithoutACutoutSizesItselfFromItsContent() {
        let flat = NotchGeometry(cutoutWidth: 0, cutoutHeight: 0, menuBarHeight: 24)
        XCTAssertNil(NotchPresentation.demo(.listening("Following along…")).surfaceWidth(in: flat))
    }
}
