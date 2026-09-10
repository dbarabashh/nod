import XCTest
@testable import Nod

/// A model writes `~` for "approximately". Two of them in one line used to
/// strike out everything between, which read as a rendering fault in an answer
/// nobody could correct.
final class RecapMarkdownTests: XCTestCase {
    func testLoneTildesAreEscaped() {
        XCTAssertEqual(escapingLoneTildes("~600 users"), "\\~600 users")
        XCTAssertEqual(
            escapingLoneTildes("costs (~$4k?) against Teams (~$30k?)"),
            "costs (\\~$4k?) against Teams (\\~$30k?)"
        )
    }

    func testDoubledTildesStayStrikethrough() {
        XCTAssertEqual(escapingLoneTildes("~~dropped~~ entirely"), "~~dropped~~ entirely")
    }

    func testTextWithoutTildesIsUntouched() {
        XCTAssertEqual(escapingLoneTildes("nothing to escape"), "nothing to escape")
    }

    func testApproximationSurvivesRendering() {
        let rendered = renderRecapMarkdown("costs (~$4k?) against Teams (~$30k?)")

        XCTAssertEqual(String(rendered.characters), "costs (~$4k?) against Teams (~$30k?)")
        XCTAssertNil(rendered.runs.first { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }

    func testDeliberateStrikethroughStillRenders() {
        let rendered = renderRecapMarkdown("~~dropped~~ entirely")

        XCTAssertEqual(String(rendered.characters), "dropped entirely")
        XCTAssertNotNil(rendered.runs.first { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }
}
