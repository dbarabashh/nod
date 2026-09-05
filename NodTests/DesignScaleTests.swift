import SwiftUI
import XCTest
@testable import Nod

/// The grid, asserted.
///
/// The scale it replaces was not wrong so much as absent: `spacing:` in the
/// view tree ran 1, 2, 3, 5, 7, 9, 11 and 14 as often as it ran 4, 8 and 12,
/// and the type sizes clustered at 11, 11.5, 12, 12.5, 13 with nothing saying
/// which was which. Nothing caught that, because there was nothing to catch it
/// against. These are that something.
@MainActor
final class DesignScaleTests: XCTestCase {
    private let base: CGFloat = 4

    private var spacing: [(name: String, value: CGFloat)] {
        [
            ("x1", Theme.Space.x1), ("x2", Theme.Space.x2), ("x3", Theme.Space.x3),
            ("x4", Theme.Space.x4), ("x6", Theme.Space.x6), ("x8", Theme.Space.x8),
            ("x10", Theme.Space.x10), ("x12", Theme.Space.x12)
        ]
    }

    private var roles: [(name: String, style: Theme.TextStyle)] {
        [
            ("display", Theme.Typography.display),
            ("pageTitle", Theme.Typography.pageTitle),
            ("cardTitle", Theme.Typography.cardTitle),
            ("editor", Theme.Typography.editor),
            ("sectionTitle", Theme.Typography.sectionTitle),
            ("ui", Theme.Typography.ui),
            ("uiEmphasis", Theme.Typography.uiEmphasis),
            ("secondary", Theme.Typography.secondary),
            ("meta", Theme.Typography.meta),
            ("micro", Theme.Typography.micro)
        ]
    }

    // MARK: - The grid

    func testEverySpacingStepIsOnTheGrid() {
        for step in spacing {
            XCTAssertEqual(step.value.truncatingRemainder(dividingBy: base), 0, step.name)
        }
    }

    func testEveryRadiusIsOnTheGrid() {
        for radius in [Theme.Radii.chip, Theme.Radii.surface, Theme.Radii.card] {
            XCTAssertEqual(radius.truncatingRemainder(dividingBy: base), 0, "\(radius)")
        }
    }

    func testEveryControlSizeIsOnTheGrid() {
        let sizes: [(String, CGFloat)] = [
            ("height", Theme.Control.height), ("heightCompact", Theme.Control.heightCompact),
            ("icon", Theme.Control.icon), ("iconMicro", Theme.Control.iconMicro)
        ]
        for size in sizes {
            XCTAssertEqual(size.1.truncatingRemainder(dividingBy: base), 0, size.0)
        }
    }

    // MARK: - Type

    func testNoRoleSetsAtAHalfPoint() {
        // Where the old ladder actually lived: 11.5, 12.5, 13.5, 9.5. A half
        // point is not a decision anybody can repeat, which is why the same
        // role came back a different size in the next view.
        for role in roles {
            XCTAssertEqual(role.style.size.truncatingRemainder(dividingBy: 1), 0, role.name)
        }
    }

    func testAnythingSomebodyOperatesIsAtLeastThirteenPoint() {
        // The one accessibility floor the scale carries. The old tree put row
        // labels at 11.
        for role in [Theme.Typography.ui, Theme.Typography.uiEmphasis] {
            XCTAssertGreaterThanOrEqual(role.size, 13, "\(role.size)")
        }
        XCTAssertGreaterThanOrEqual(Theme.Typography.secondary.size, 12)
    }

    func testTheDeclaredLeadingStillMatchesTheShippedFace() {
        // The only assertion here that can fail for a reason outside this file:
        // the roles declare a line box, and what has to be added to reach it
        // depends on the system face. If Apple reflows SF, these move.
        XCTAssertEqual(Theme.Typography.ui.lineSpacing, 2)
        XCTAssertEqual(Theme.Typography.secondary.lineSpacing, 1)
        XCTAssertEqual(Theme.Typography.editor.lineSpacing, 4)
        // Declared nothing, so it sets at the face's own leading.
        XCTAssertEqual(Theme.Typography.display.lineSpacing, 0)
    }

    func testAControlIsTallerThanTheTextInIt() {
        XCTAssertGreaterThan(Theme.Control.heightCompact, Theme.Typography.ui.size)
        XCTAssertGreaterThan(Theme.Control.height, Theme.Control.heightCompact)
    }
}
