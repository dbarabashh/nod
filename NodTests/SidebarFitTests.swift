import AppKit
import SwiftUI
import XCTest
@testable import Nod

/// The sidebar is wide enough for the words in it.
///
/// It was set to a measured 152 taken from another app, and every navigation
/// row in the footer ellipsized: the capture pill wrapped to two lines,
/// "Ambient context" showed as "Ambie…", the referral as "Give 50%, g…". The
/// width was fine; the labels were longer than the app it was measured from.
///
/// Measuring here rather than looking is the point — a label added next month
/// is exactly how this comes back, and nobody re-opens the window to check.
@MainActor
final class SidebarFitTests: XCTestCase {
    /// The row's own numbers, read from the row. The first version of this
    /// file wrote its own copy and was three points out of step the day it
    /// landed — a second hand-maintained model of the layout, inside the test
    /// written to stop hand-maintained models drifting.
    private let chrome = Theme.Space.x3 * 2 + SidebarRowMetrics.chrome

    /// Everything a person navigates by. The referral promo is deliberately not
    /// here: it is an offer rather than a destination, and it is allowed the
    /// tail that buys the other rows their room.
    private let navigation = [
        "Today", "Ask NOD", "Memory", "Beats", "Trash",
        "Shared with me", "Add project", "Settings", "Your account"
    ]

    private func measure(_ text: String, _ style: Theme.TextStyle) -> CGFloat {
        style.width(of: text)
    }

    func testEveryNavigationLabelFits() {
        for label in navigation {
            let needed = measure(label, Theme.Typography.ui) + chrome
            XCTAssertLessThanOrEqual(needed, Theme.Layout.sidebar, "\(label) needs \(needed)")
        }
    }

    func testTheAmbientRowFitsWithItsStatusWord() {
        // The longest row that is not a promo: a label and a state on one line.
        let needed = measure("Ambient context", Theme.Typography.ui)
            + measure("On", Theme.Typography.meta)
            + Theme.Space.x2
            + chrome
        XCTAssertLessThanOrEqual(needed, Theme.Layout.sidebar, "needs \(needed)")
    }

    func testTheCaptureLabelFitsOnOneLine() {
        // It wrapped at 152. A primary action that sets on two lines reads as a
        // paragraph, not a button.
        let needed = measure("New capture", Theme.Typography.uiEmphasis.weight(.semibold))
            + Theme.Space.x3 * 2
            + Theme.Space.x3 * 2
            + Theme.Control.iconMicro
            + Theme.Space.x2
        XCTAssertLessThanOrEqual(needed, Theme.Layout.sidebar, "needs \(needed)")
    }

    func testTheSidebarIsNoWiderThanItHasToBe() {
        // The other half of the check: a sidebar that grows to fit anything is
        // a sidebar nobody trims. One grid step narrower has to actually break
        // something, or this width is not earned.
        let narrower = Theme.Layout.sidebar - Theme.Space.x1
        let widest = navigation
            .map { measure($0, Theme.Typography.ui) + chrome }
            .max() ?? 0
        let ambient = measure("Ambient context", Theme.Typography.ui)
            + measure("On", Theme.Typography.meta) + Theme.Space.x2 + chrome
        XCTAssertGreaterThan(max(widest, ambient), narrower)
    }
}
