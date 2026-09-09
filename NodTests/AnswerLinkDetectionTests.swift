import XCTest
@testable import Nod

final class AnswerLinkDetectionTests: XCTestCase {
    func testPlainSentenceHasNoLink() {
        XCTAssertFalse(AnswerLinkDetection.containsLink("You're meeting Vlad at 2pm today."))
    }

    func testBareURLIsDetected() {
        XCTAssertTrue(AnswerLinkDetection.containsLink("It's https://meet.google.com/abc-defg-hij"))
    }

    func testMarkdownLinkIsDetected() {
        XCTAssertTrue(AnswerLinkDetection.containsLink("Here's the doc: [Q3 plan](https://docs.google.com/x)"))
    }

    /// `NSDataDetector`'s `.link` type flags a bare email address too — which
    /// is the right call here: an address is exactly as easy to mishear as a
    /// URL, and just as worth showing rather than only saying.
    func testEmailAddressCountsAsALink() {
        XCTAssertTrue(AnswerLinkDetection.containsLink("Reply to dima@hellonod.app about it."))
    }
}
