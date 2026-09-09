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

    private func welcome(daysAgo: Double = 0) -> Meeting {
        var sample = meeting(title: "Dima B <> Nod", daysAgo: daysAgo)
        sample.origin = "welcome"
        return sample
    }

    /// An account whose only session is the sample has nothing to be caught up
    /// *on*: the useful move is to go and read it. So the opener opens it, says
    /// "Open" rather than asking a question it would answer with nothing, and
    /// leads in the accent.
    func testTheSampleOpensInsteadOfAsking() {
        let sample = welcome()

        let featured = ChatHomeSuggestions.build(meetings: [sample], now: now).first { $0.isFeatured }

        XCTAssertEqual(featured?.opens, sample.id)
        XCTAssertEqual(featured?.label, "Start here — Dima B <> Nod")
    }

    /// The moment a real session exists, the sample stops leading — pointing
    /// somebody at the demo instead of their own work is the failure here.
    func testARealSessionTakesTheLeadBackFromTheSample() {
        let openers = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Pricing sync", daysAgo: 0), welcome(daysAgo: 1)],
            now: now
        )

        XCTAssertNil(openers.first { $0.isFeatured })
        XCTAssertTrue(openers.contains { $0.label == "Catch me up on Pricing sync" })
        XCTAssertTrue(openers.allSatisfy { $0.opens == nil })
    }

    /// The sample is a row in the list, not something the person said. It must
    /// not move an account out of its first run: doing so replaced the openers
    /// that explain the product with memory questions a new account answers
    /// with "I don't have anything on that yet".
    func testTheSampleDoesNotEndTheFirstRun() {
        let openers = ChatHomeSuggestions.build(meetings: [welcome()], now: now)

        XCTAssertTrue(openers.contains { AboutNod.questions.contains($0.question) })
        XCTAssertFalse(openers.contains { $0.question == "What did I promise?" })
    }

    /// And it still leads, above the explanations — reading it answers most of
    /// what they ask.
    func testTheSampleLeadsTheFirstRunOpeners() {
        let openers = ChatHomeSuggestions.build(meetings: [welcome()], now: now)

        XCTAssertEqual(openers.first?.label, "Start here — Dima B <> Nod")
        XCTAssertTrue(openers.first?.isFeatured == true)
    }

    /// A "catch me up" pointed at the sample would be answering out of a demo
    /// while a real session sits beside it.
    func testCatchMeUpNeverNamesTheSample() {
        let openers = ChatHomeSuggestions.build(
            meetings: [welcome(daysAgo: 0), meeting(title: "Pricing sync", daysAgo: 1)],
            now: now
        )

        XCTAssertTrue(openers.contains { $0.label == "Catch me up on Pricing sync" })
        XCTAssertFalse(openers.contains { $0.label.contains("Dima B <> Nod") })
    }

    /// A first run has nothing to remember, so the openers that read memory
    /// ("what did I promise?") are answered with "I don't have anything on
    /// that yet" — the worst possible first impression of a memory product.
    func testFirstRunAsksAboutNodInstead() {
        let suggestions = ChatHomeSuggestions.build(meetings: [], now: now)

        XCTAssertEqual(
            suggestions.map(\.question),
            Array(AboutNod.questions.prefix(ChatHomeSuggestions.maximum))
        )
    }

    /// Every opener a first run offers has to be one Nod answers from the
    /// prepared set. Reword either side and the pitch silently becomes an
    /// ungrounded model answer about a Mac app it has never seen.
    func testEveryFirstRunOpenerHasAPreparedAnswer() {
        for opener in ChatHomeSuggestions.build(meetings: [], now: now) {
            XCTAssertNotNil(AboutNod.answer(to: opener.question), opener.question)
        }
    }

    /// The trashed-only case is still a first run: the sessions are gone.
    func testASoleTrashedSessionStillCountsAsAFirstRun() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1, deleted: true)],
            now: now
        )

        XCTAssertEqual(suggestions.map(\.question), AboutNod.questions)
    }

    /// The debug switch forces the empty state on an account that has
    /// sessions, so the one screen nobody can see twice stays reviewable.
    func testThePreviewSwitchForcesTheFirstRunOpeners() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1)],
            now: now,
            firstRunPreview: true
        )

        XCTAssertEqual(
            suggestions.map(\.question),
            Array(AboutNod.questions.prefix(ChatHomeSuggestions.maximum))
        )
    }

    /// The switch is the only thing that can do that — a build that read it
    /// from a preference made this pure function depend on the developer's
    /// machine, and seven tests failed the moment it was flipped.
    func testWithoutTheSwitchSessionsWin() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1)],
            now: now
        )

        XCTAssertFalse(suggestions.contains { AboutNod.answer(to: $0.question) != nil })
    }

    /// One real session and the openers go back to reading memory.
    func testOneSessionBringsBackTheMemoryOpeners() {
        let suggestions = ChatHomeSuggestions.build(
            meetings: [meeting(title: "Standup", daysAgo: 1)],
            now: now
        )

        XCTAssertTrue(suggestions.contains { $0.question == "What did I promise?" })
        XCTAssertFalse(suggestions.contains { AboutNod.answer(to: $0.question) != nil })
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

    // MARK: - The day under the greeting

    /// 19 August 2026 was a Wednesday — the date the screen this was written
    /// for was showing.
    private var wednesday: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    func testTheDayReadsAsAWeekdayAndADate() {
        let line = ChatHomeSuggestions.dayLine(wednesday, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(line, "Wednesday, August 19")
    }

    /// Where the day leads the month, it leads here too. Hardcoding the
    /// American order would be wrong for most of the people this ships to.
    func testTheDayFollowsTheReadersOrder() {
        let line = ChatHomeSuggestions.dayLine(wednesday, locale: Locale(identifier: "en_GB"))

        XCTAssertEqual(line, "Wednesday 19 August")
    }

    /// A header saying what day it is has no business naming the year.
    func testTheDayOmitsTheYear() {
        for identifier in ["en_US", "en_GB", "uk_UA"] {
            let line = ChatHomeSuggestions.dayLine(wednesday, locale: Locale(identifier: identifier))
            XCTAssertFalse(line.contains("2026"), line)
        }
    }

    func testTheSubtitleCarriesBothTheDayAndTheReach() {
        let line = ChatHomeSuggestions.homeSubtitle(projects: [], now: wednesday, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(line, "Wednesday, August 19 · Ask across all memory")
    }

    /// Scoping the chat to a project must not cost the date, and naming the
    /// project is still what the second half is for.
    func testAScopedSubtitleKeepsTheDay() {
        let line = ChatHomeSuggestions.homeSubtitle(
            projects: ["Capable"],
            now: wednesday,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(line, "Wednesday, August 19 · Ask about Capable")
    }

    /// The composer's placeholder reads `scopeHeadline` directly, and a date in
    /// a text field's placeholder would be noise that never changes what you
    /// can type.
    func testTheComposerPlaceholderStaysDateless() {
        XCTAssertEqual(ChatHomeSuggestions.scopeHeadline(projects: []), "Ask across all memory")
    }
}
