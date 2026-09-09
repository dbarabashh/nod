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
    func testOnlyBrowsersAreReadThroughTheirWebArea() {
        XCTAssertTrue(AccessibilityReader.isBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(AccessibilityReader.isBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(AccessibilityReader.isBrowser(bundleID: "com.microsoft.Word"))
        XCTAssertFalse(AccessibilityReader.isBrowser(bundleID: "com.apple.finder"))
        XCTAssertFalse(AccessibilityReader.isBrowser(bundleID: ""))
    }

    /// The arrangement from the report: a 1512pt built-in display to the LEFT
    /// of the main one, so its windows carry negative x. `desktopIndependentWindow`
    /// fails its own display lookup there, and the fallback has to name the
    /// display instead.
    func testAWindowOnADisplayLeftOfTheMainOneFindsItsHost() {
        let main = CGRect(x: 0, y: 0, width: 3_440, height: 1_440)
        let builtIn = CGRect(x: -1_536, y: 0, width: 1_512, height: 982)
        let window = CGRect(x: -1_524, y: 33, width: 1_512, height: 949)

        XCTAssertEqual(ScreenTextRecognizer.indexOfHost(forWindow: window, among: [main, builtIn]), 1)
    }

    func testAWindowAcrossASeamGoesToTheDisplayHoldingMoreOfIt() {
        let left = CGRect(x: -1_000, y: 0, width: 1_000, height: 1_000)
        let right = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let mostlyRight = CGRect(x: -100, y: 0, width: 400, height: 500)

        XCTAssertEqual(ScreenTextRecognizer.indexOfHost(forWindow: mostlyRight, among: [left, right]), 1)
    }

    func testAWindowOnNoDisplayHasNoHost() {
        let main = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let orphan = CGRect(x: 5_000, y: 5_000, width: 300, height: 300)

        XCTAssertNil(ScreenTextRecognizer.indexOfHost(forWindow: orphan, among: [main]))
        XCTAssertNil(ScreenTextRecognizer.indexOfHost(forWindow: main, among: []))
    }

    /// `sourceRect` is measured from the display's own origin, so a window at a
    /// negative global x becomes a positive offset inside its display.
    func testTheCropIsMeasuredFromTheDisplayOrigin() {
        let builtIn = CGRect(x: -1_536, y: 0, width: 1_512, height: 982)
        let window = CGRect(x: -1_524, y: 33, width: 1_512, height: 949)

        XCTAssertEqual(
            ScreenTextRecognizer.rect(ofWindow: window, within: builtIn),
            CGRect(x: 12, y: 33, width: 1_512, height: 949)
        )
    }
}
