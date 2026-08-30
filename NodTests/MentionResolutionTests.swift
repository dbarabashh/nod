import AppKit
import XCTest
@testable import Nod

/// The pills a person can see, the scope a question carries, and the sessions
/// it pins are three answers to one question: which names does this sentence
/// name? They have to agree, so they all come from here.
final class MentionResolutionTests: XCTestCase {
    private func mark(_ name: String) -> MentionMark {
        MentionMark(name: name, glyph: .icon("nc-layers-3"))
    }

    func testNamesNothingWithoutAnAt() {
        let candidates = [mark("Pricing")]

        XCTAssertTrue(MentionMark.named(in: "what did we say about pricing", from: candidates).isEmpty)
    }

    /// The longer name wins the text it spells. Resolved per-mark, a project
    /// called "API" was scoped in by a question that only said "@API v2".
    func testTheLongerNameClaimsTheTextItSpells() {
        let short = mark("API")
        let long = mark("API v2")

        let named = MentionMark.named(in: "how did @API v2 land?", from: [short, long])

        XCTAssertEqual(named.map(\.name), ["API v2"])
    }

    /// Both, when the sentence really does name both.
    func testBothWhenBothAreNamed() {
        let named = MentionMark.named(in: "@API and @API v2", from: [mark("API"), mark("API v2")])

        XCTAssertEqual(named.map(\.name), ["API", "API v2"])
    }

    func testMatchesRegardlessOfCase() {
        XCTAssertEqual(MentionMark.named(in: "ping @linear please", from: [mark("Linear")]).map(\.name), ["Linear"])
    }

    /// An "@" inside a word is not a mention. The composer only opens the
    /// picker at a word boundary, and the reading side has to agree — otherwise
    /// an address in the sentence names a product, and a question aimed at
    /// nothing gets answered "Linear isn't connected".
    func testAnAddressDoesNotNameAProduct() {
        XCTAssertTrue(MentionMark.named(in: "mail dima@linear.app about it", from: [mark("Linear")]).isEmpty)
    }

    /// The same sentence naming it properly still resolves — the boundary rule
    /// narrows what counts, it does not stop counting.
    func testTheSameNameStillResolvesWhenItStandsAlone() {
        let named = MentionMark.named(in: "mail dima@linear.app, then check @Linear", from: [mark("Linear")])

        XCTAssertEqual(named.map(\.name), ["Linear"])
    }

    func testANewlineIsAWordBoundaryToo() {
        XCTAssertEqual(MentionMark.named(in: "status?\n@Linear", from: [mark("Linear")]).map(\.name), ["Linear"])
    }

    /// Writing a mention in and taking it out are one rule, so a row of marks
    /// and a picker cannot disagree about what a draft says.
    func testAMentionGoesInWithItsSpacingAndComesBackOut() {
        var draft = "what's the status"
        mark("Linear").insert(into: &draft)

        XCTAssertEqual(draft, "what's the status @Linear ")

        mark("Linear").remove(from: &draft)

        XCTAssertEqual(draft, "what's the status ")
    }

    /// Removal reads the sentence by the rule that drew it. Cutting the first
    /// raw match instead took a word out of the address.
    func testRemovingLeavesAnAddressAlone() {
        var draft = "mail dima@linear.app about @Linear"
        mark("Linear").remove(from: &draft)

        XCTAssertEqual(draft, "mail dima@linear.app about ")
    }

    /// The caller's order survives, whatever order the search had to walk.
    func testKeepsTheCallersOrder() {
        let candidates = [mark("Zebra"), mark("Alphabetical"), mark("Mid")]

        let named = MentionMark.named(in: "@Zebra @Alphabetical @Mid", from: candidates)

        XCTAssertEqual(named.map(\.name), ["Zebra", "Alphabetical", "Mid"])
    }

    /// The resolver takes the items, not just their marks, so a caller gets
    /// back the projects or sessions it asked about.
    func testResolvesTheItemsBehindTheMarks() {
        let providers = IntegrationProvider.allCases
        guard let first = providers.first else { return XCTFail("no providers") }

        let named = MentionMark.named(in: "check @\(first.displayName)", from: providers, mark: MentionMark.init(tool:))

        XCTAssertEqual(named, [first])
    }

    /// The one definition every surface asks: the notch's marks, the composer's
    /// pills and the tools a live question is allowed to reach.
    func testNamedToolsReadsTheSentence() {
        XCTAssertEqual(MentionMark.namedTools(in: "@Slack what did they say"), [.slack])
        XCTAssertTrue(MentionMark.namedTools(in: "what did they say").isEmpty)
    }

    /// The longer product name claims the text it spells, so a question aimed at
    /// the calendar is not routed into Drive.
    func testTheLongerProductNameWins() {
        XCTAssertEqual(MentionMark.namedTools(in: "anything on @Google Calendar today"), [.googleCalendar])
    }
}
