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
            speakerNames: nil,
            deletedAt: deleted ? now : nil
        )
    }

    func testFirstRunFallsBackToGenericOpeners() {
        let suggestions = ChatHomeSuggestions.build(meetings: [], now: now)

        XCTAssertEqual(suggestions.map(\.question), [
            "What did I promise?",
            "What decisions are still unresolved?"
        ])
    }

    func testProjectScopeNamesTheProjectInEveryOpener() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1)],
            projects: ["Hiring"],
            now: now
        )

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.label.contains("Hiring") })
        XCTAssertFalse(suggestions.contains { $0.label.contains("Standup") })
    }

    func testSeveralProjectsAreNamedInEveryOpener() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1)],
            projects: ["Hiring", "Pricing"],
            now: now
        )

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.question.contains("Hiring and Pricing") })
        XCTAssertFalse(suggestions.contains { $0.label.contains("Standup") })
    }

    func testScopeHeadlineNamesTheReach() {
        XCTAssertEqual(ChatHomeSuggestions.scopeHeadline(projects: []), "Ask across all memory")
        XCTAssertEqual(ChatHomeSuggestions.scopeHeadline(projects: ["   "]), "Ask across all memory")
        XCTAssertEqual(ChatHomeSuggestions.scopeHeadline(projects: ["Hiring"]), "Ask about Hiring")
        XCTAssertEqual(
            ChatHomeSuggestions.scopeHeadline(projects: ["Hiring", "Pricing"]),
            "Ask about Hiring and Pricing"
        )
        XCTAssertEqual(
            ChatHomeSuggestions.scopeHeadline(projects: ["Hiring", "  ", "Pricing", "Roadmap"]),
            "Ask about Hiring, Pricing and Roadmap"
        )
    }

    func testRecentMeetingIsNamedInAnOpener() {
        let suggestions = ChatHomeSuggestions.build(meetings: [meeting(title: "Pricing review", daysAgo: 1)], now: now)

        XCTAssertTrue(suggestions.map(\.question).contains("Catch me up on Pricing review"))
    }

    func testWeeklyOpenerNeedsMoreThanOneMeeting() {
        let one = ChatHomeSuggestions.build(meetings: [meeting(title: "Standup", daysAgo: 1)], now: now)
        let two = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1), meeting(title: "Retro", daysAgo: 2)],
            now: now
        )

        XCTAssertFalse(one.map(\.question).contains("What did we decide this week?"))
        XCTAssertTrue(two.map(\.question).contains("What did we decide this week?"))
    }

    func testStaleMeetingsAreNotCalledThisWeek() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Old one", daysAgo: 30), meeting(title: "Older", daysAgo: 40)],
            now: now
        )

        XCTAssertFalse(suggestions.map(\.question).contains("What did we decide this week?"))
        XCTAssertFalse(suggestions.contains { $0.question.hasPrefix("Catch me up") })
    }

    func testDeletedMeetingsAreNeverSuggested() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Deleted one", daysAgo: 1, deleted: true)],
            now: now
        )

        XCTAssertFalse(suggestions.contains { $0.question.contains("Deleted one") })
    }

    func testUntitledMeetingsDoNotProduceAnOpener() {
        let suggestions = ChatHomeSuggestions.build(meetings: [meeting(title: "   ", daysAgo: 1)], now: now)

        XCTAssertFalse(suggestions.contains { $0.question.hasPrefix("Catch me up") })
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

    /// The chip is cut to fit; the question must not be. Asking about a title
    /// that ends in an ellipsis matches no session — the retrieval is looking
    /// for a name nothing has.
    func testLongTitleIsCutOnTheChipButNotInTheQuestion() {
        let title = "Деплой LiveKit агента та усунення проблем із підключенням"
        let suggestions = ChatHomeSuggestions.build(meetings: [meeting(title: title, daysAgo: 1)], now: now)
        let opener = suggestions.first { $0.question.hasPrefix("Catch me up") }

        XCTAssertEqual(opener?.question, "Catch me up on \(title)")
        XCTAssertFalse(opener?.question.contains("…") ?? true)
        XCTAssertTrue(opener?.label.hasSuffix("…") ?? false, "the chip should still be cut")
    }

    /// Long project names go through the same template, so the same trap is one
    /// scope away.
    func testProjectQuestionsCarryTheWholeName() {
        let project = "Платформа рекомендацій та персоналізації стрічки"
        let suggestions = ChatHomeSuggestions.build(meetings: [], projects: [project], now: now)

        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.question.contains(project) })
        XCTAssertTrue(suggestions.allSatisfy { !$0.question.contains("…") })
        XCTAssertTrue(suggestions.allSatisfy { $0.label.contains("…") })
    }

    func testGreetingUsesTheFirstNameOnly() {
        XCTAssertEqual(ChatHomeSuggestions.greeting(for: "Dima Barabash"), "What's on your mind, Dima?")
    }

    func testGreetingWithoutANameDropsTheComma() {
        XCTAssertEqual(ChatHomeSuggestions.greeting(for: nil), "What's on your mind?")
        XCTAssertEqual(ChatHomeSuggestions.greeting(for: "   "), "What's on your mind?")
    }
}
