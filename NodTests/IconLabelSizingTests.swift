import AppKit
import XCTest
@testable import Nod

/// A SwiftUI frame does not reach a menu row's icon — AppKit draws
/// `NSMenuItem.image` at the image's own `size` — so `IconLabel` hands it an
/// `NSImage` already cut to size. These pin that, because the symptom (menu
/// icons half again as big as the same glyph in the window) is invisible from
/// the Swift code and only shows up on screen.
final class IconLabelSizingTests: XCTestCase {
    private func icon(_ name: String, side: CGFloat) throws -> NSImage {
        try XCTUnwrap(NSImage.nodIcon(name, side: side), "missing asset \(name)")
    }

    func testSizedIconCarriesTheRequestedPointSize() throws {
        let image = try icon("nc-trash", side: 11)
        XCTAssertEqual(image.size.width, 11, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 11, accuracy: 0.001)
    }

    /// Menus tint their own labels, including red for a destructive role, which
    /// only happens for a template image.
    func testSizedIconStaysTemplate() throws {
        XCTAssertTrue(try icon("nc-trash", side: 11).isTemplate)
    }

    /// The catalogue asset must survive being sized for one label — it is the
    /// same object every other call site draws.
    func testSizingDoesNotMutateTheSharedAsset() throws {
        let shared = try XCTUnwrap(NSImage(named: "nc-mic"))
        let before = shared.size
        _ = try icon("nc-mic", side: 40)
        XCTAssertEqual(NSImage(named: "nc-mic")?.size, before)
    }

    /// Every glyph is authored on a square canvas, so a square box can't squash
    /// one — the sized image keeps the asset's aspect.
    func testAssetsAreSquare() throws {
        for name in ["nc-trash", "nc-pen-writing", "nc-arrow-up-right", "nc-check", "nc-mic"] {
            let asset = try XCTUnwrap(NSImage(named: name), "missing asset \(name)")
            XCTAssertEqual(asset.size.width, asset.size.height, accuracy: 0.01, "\(name) is not square")
        }
    }
}
