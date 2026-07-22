import XCTest
@testable import Nod

final class ChatHomeSuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(title: String?, daysAgo: Double, deleted: Bool = false) -> Meeting {
        Meeting(
            id: UUID(),
            userID: UUID(),
            createdAt: nil,
            startedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60 + 1800),
            title: title,
            kind: .meeting,
            summary: "",
            recap: nil,
            language: "en",
            deletedAt: deleted ? now : nil
        )
    }

    func testFirstRunFallsBackToGenericOpeners() {
        let suggestions = ChatHomeSuggestions.build(meetings: [], now: now)

        XCTAssertEqual(suggestions, [
            "What did I say I'd follow up on?",
            "What have I been thinking about lately?"
        ])
    }

    func testRecentMeetingIsNamedInAnOpener() {
        let suggestions = ChatHomeSuggestions.build(meetings: [meeting(title: "Pricing review", daysAgo: 1)], now: now)

        XCTAssertTrue(suggestions.contains("Catch me up on Pricing review"))
    }

    func testWeeklyOpenerNeedsMoreThanOneMeeting() {
        let one = ChatHomeSuggestions.build(meetings: [meeting(title: "Standup", daysAgo: 1)], now: now)
        let two = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1), meeting(title: "Retro", daysAgo: 2)],
            now: now
        )

        XCTAssertFalse(one.contains("What did we decide this week?"))
        XCTAssertTrue(two.contains("What did we decide this week?"))
    }

    func testStaleMeetingsAreNotCalledThisWeek() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Old one", daysAgo: 30), meeting(title: "Older", daysAgo: 40)],
            now: now
        )

        XCTAssertFalse(suggestions.contains("What did we decide this week?"))
        XCTAssertFalse(suggestions.contains { $0.hasPrefix("Catch me up") })
    }

    func testDeletedMeetingsAreNeverSuggested() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Deleted one", daysAgo: 1, deleted: true)],
            now: now
        )

        XCTAssertFalse(suggestions.contains { $0.contains("Deleted one") })
    }

    func testUntitledMeetingsDoNotProduceAnOpener() {
        let suggestions = ChatHomeSuggestions.build(meetings: [meeting(title: "   ", daysAgo: 1)], now: now)

        XCTAssertFalse(suggestions.contains { $0.hasPrefix("Catch me up") })
    }

    func testSuggestionsAreCapped() {
        let many = (1 ... 10).map { meeting(title: "Session \($0)", daysAgo: Double($0) * 0.1) }

        XCTAssertLessThanOrEqual(ChatHomeSuggestions.build(meetings: many, now: now).count, ChatHomeSuggestions.maximum)
    }

    func testLongTitlesAreCutOnAWord() {
        let cut = ChatHomeSuggestions.truncated("Quarterly planning session with the whole platform team", to: 30)

        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.contains("  "))
        XCTAssertLessThanOrEqual(cut.count, 31)
    }

    func testGreetingUsesTheFirstNameOnly() {
        XCTAssertEqual(ChatHomeSuggestions.greeting(for: "Dima Barabash"), "What's on your mind, Dima?")
    }

    func testGreetingWithoutANameDropsTheComma() {
        XCTAssertEqual(ChatHomeSuggestions.greeting(for: nil), "What's on your mind?")
        XCTAssertEqual(ChatHomeSuggestions.greeting(for: "   "), "What's on your mind?")
    }
}
