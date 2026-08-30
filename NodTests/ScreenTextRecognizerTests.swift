import CoreGraphics
import XCTest
@testable import Nod

final class ScreenTextRecognizerTests: XCTestCase {
    /// A window smaller than the ceiling is captured at its full backing size —
    /// the Retina pixels are the point of reading it off the screen at all.
    func testAWindowUnderTheCeilingKeepsEveryPixel() {
        let retina = CGSize(width: 1_440 * 2, height: 900 * 2)

        XCTAssertEqual(ScreenTextRecognizer.downscaledToLongSideLimit(retina), retina)
    }

    func testAnOversizeWindowIsFittedToTheLongSideAndKeepsItsAspect() {
        let huge = CGSize(width: 6_016, height: 3_384)
        let fitted = ScreenTextRecognizer.downscaledToLongSideLimit(huge)

        XCTAssertEqual(fitted.width, 4_096)
        XCTAssertEqual(fitted.height, (3_384 * (4_096 / 6_016)).rounded())
        XCTAssertLessThanOrEqual(max(fitted.width, fitted.height), 4_096)
    }

    func testATallWindowIsFittedOnItsHeight() {
        let tall = CGSize(width: 2_000, height: 8_000)
        let fitted = ScreenTextRecognizer.downscaledToLongSideLimit(tall)

        XCTAssertEqual(fitted.height, 4_096)
        XCTAssertEqual(fitted.width, 1_024)
    }

    func testAnEmptySizeIsLeftAlone() {
        XCTAssertEqual(ScreenTextRecognizer.downscaledToLongSideLimit(.zero), .zero)
    }

    /// The web-area search is a bounded walk that finds nothing in a document
    /// or file-manager window, so it must not run there at all.
    func testOnlyBrowsersAreSearchedForAPageURL() {
        XCTAssertTrue(AccessibilityReader.exposesPageURL(bundleID: "com.google.Chrome"))
        XCTAssertTrue(AccessibilityReader.exposesPageURL(bundleID: "com.apple.Safari"))
        XCTAssertFalse(AccessibilityReader.exposesPageURL(bundleID: "com.microsoft.Word"))
        XCTAssertFalse(AccessibilityReader.exposesPageURL(bundleID: "com.apple.finder"))
        XCTAssertFalse(AccessibilityReader.exposesPageURL(bundleID: ""))
    }
}
