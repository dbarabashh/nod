import XCTest
@testable import Nod

/// The recap model writes section titles in the user's output language, so the
/// classification has to key on the signal word rather than on a heading we
/// chose. These pin the two failures that matter: a settled section read as
/// open, and an interview's answered "Questions" read as open questions.
final class TodayDigestTests: XCTestCase {
    func testOpenSectionsAreRecognisedInEitherLanguage() {
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Open questions"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Unresolved decisions"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Risks"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Відкриті питання"))
        XCTAssertTrue(TodayDigest.leavesSomethingOpen("Ризики"))
    }

    func testSettledAndAnsweredSectionsAreNotOpen() {
        XCTAssertFalse(TodayDigest.leavesSomethingOpen("Decisions made"))
        XCTAssertFalse(TodayDigest.leavesSomethingOpen("Topics covered"))
        // An interview recap's "Questions" are asked and answered, not open.
        XCTAssertFalse(TodayDigest.leavesSomethingOpen("Questions asked"))
    }

    func testSettledSectionsAreRecognisedInEitherLanguage() {
        XCTAssertTrue(TodayDigest.settlesSomething("Decisions"))
        XCTAssertTrue(TodayDigest.settlesSomething("What we agreed"))
        XCTAssertTrue(TodayDigest.settlesSomething("Рішення"))
        XCTAssertTrue(TodayDigest.settlesSomething("Про що домовились"))
    }

    func testOpenSectionsDoNotAlsoCountAsSettled() {
        XCTAssertFalse(TodayDigest.settlesSomething("Open questions"))
        XCTAssertFalse(TodayDigest.settlesSomething("Risks"))
        XCTAssertFalse(TodayDigest.settlesSomething("Відкриті питання"))
    }
}
