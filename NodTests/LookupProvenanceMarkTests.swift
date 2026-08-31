import XCTest
@testable import Nod

final class LookupProvenanceMarkTests: XCTestCase {
    private let tools = ["gmail_search_messages", "slack_post_message"]

    func testARealSubjectIsKept() {
        XCTAssertEqual(MeetingLookup.mark("NOD-214", notNaming: tools), "NOD-214")
        XCTAssertEqual(MeetingLookup.mark("  #vc  ", notNaming: tools), "#vc")
        XCTAssertEqual(MeetingLookup.mark("Реліз Nod", notNaming: tools), "Реліз Nod")
    }

    /// The field is written by the model, and it came back as the name of the
    /// function it had called — shown to a person, beside an answer.
    func testAToolIdentifierNeverReachesTheMark() {
        XCTAssertNil(MeetingLookup.mark("gmail_search_messages", notNaming: ["gmail_search_messages"]))
        XCTAssertNil(MeetingLookup.mark("Gmail_Search_Messages", notNaming: ["gmail_search_messages"]))
    }

    /// A Slack channel is `eng_releases`. Rejecting marks by punctuation threw
    /// real subjects away; only a name actually in play disqualifies one.
    func testASubjectThatMerelyLooksLikeAnIdentifierSurvives() {
        XCTAssertEqual(MeetingLookup.mark("eng_releases", notNaming: tools), "eng_releases")
    }

    func testNothingWorthShowingIsNoMark() {
        XCTAssertNil(MeetingLookup.mark(nil, notNaming: tools))
        XCTAssertNil(MeetingLookup.mark("   ", notNaming: tools))
    }
}
