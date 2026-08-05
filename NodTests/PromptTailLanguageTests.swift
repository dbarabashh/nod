import XCTest
@testable import Nod

final class PromptTailLanguageTests: XCTestCase {
    private var pending: String?
    private var run = 0

    private func action(_ detected: String?, tail: String?) -> WhisperTranscriber.PromptTailAction {
        WhisperTranscriber.promptTailAction(
            detected: detected,
            tailLanguage: tail,
            pending: &pending,
            pendingRun: &run
        )
    }

    func testFirstChunkStartsTheTail() {
        XCTAssertEqual(action("uk", tail: nil), .append)
    }

    func testSameLanguageAppends() {
        XCTAssertEqual(action("uk", tail: "uk"), .append)
    }

    func testLanguageComparisonIsCaseInsensitive() {
        XCTAssertEqual(action("UK", tail: "uk"), .append)
    }

    func testUnknownLanguageAppends() {
        XCTAssertEqual(action(nil, tail: "uk"), .append)
    }

    /// The bug this exists for: one loanword-dense chunk comes back as English
    /// and must not become the tail that prompts the rest of the meeting.
    func testSingleForeignChunkIsIgnored() {
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
    }

    func testTwoForeignChunksAreStillIgnored() {
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
    }

    func testThirdConsecutiveForeignChunkConfirmsTheSwitch() {
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .replace)
    }

    func testReturningToTheTailLanguageCancelsAPendingSwitch() {
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("uk", tail: "uk"), .append)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .replace)
    }

    /// Two different foreign languages alternating never add up to a switch —
    /// each one restarts the count.
    func testAlternatingForeignLanguagesNeverConfirm() {
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("ru", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("ru", tail: "uk"), .ignore)
    }

    func testConfirmedSwitchResetsSoTheNextOneNeedsItsOwnRun() {
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .ignore)
        XCTAssertEqual(action("en", tail: "uk"), .replace)
        XCTAssertEqual(action("uk", tail: "en"), .ignore)
        XCTAssertEqual(action("uk", tail: "en"), .ignore)
        XCTAssertEqual(action("uk", tail: "en"), .replace)
    }
}
