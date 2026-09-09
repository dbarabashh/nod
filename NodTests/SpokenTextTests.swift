import XCTest
@testable import Nod

final class SpokenTextTests: XCTestCase {
    func testMarksComeOffAndWordsStay() {
        let answer = """
        ## Next up
        Your **10:30** with _Ana_ is the one to prepare for — see [the brief](nod://x).
        - Pricing `v2`
        - Rollout
        """
        XCTAssertEqual(
            SpokenText.plain(answer),
            "Next up\nYour 10:30 with Ana is the one to prepare for — see the brief.\nPricing v2\nRollout"
        )
    }

    func testCodeBlocksAreNotReadOut() {
        XCTAssertEqual(SpokenText.plain("Run this:\n```sh\nls -la\n```\nthen check."), "Run this:\n \nthen check.")
    }

    func testIdentifiersAndArithmeticKeepTheirMarks() {
        XCTAssertEqual(SpokenText.plain("Look at meeting_id and app_build."), "Look at meeting_id and app_build.")
        XCTAssertEqual(SpokenText.plain("2 * 3 is 6, and 2 ** 3 is 8."), "2 * 3 is 6, and 2 ** 3 is 8.")
        XCTAssertEqual(SpokenText.plain("Call __init__ first, then `ls | grep x`."), "Call __init__ first, then ls | grep x.")
        XCTAssertEqual(SpokenText.plain("__Two words__ and **one**."), "Two words and one.")
    }

    func testAYearIsNotAListNumber() {
        XCTAssertEqual(SpokenText.plain("2024. That was the year."), "2024. That was the year.")
        XCTAssertEqual(SpokenText.plain("1. First\n12. Twelfth"), "First\nTwelfth")
    }

    func testTablesReadAsRows() {
        XCTAssertEqual(SpokenText.plain("| Who | When |\n|---|---|\n| Ana | 10:30 |"), "Who, When\n\nAna, 10:30")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(SpokenText.plain("  \n"), "")
    }
}
