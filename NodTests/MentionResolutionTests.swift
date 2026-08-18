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
}
