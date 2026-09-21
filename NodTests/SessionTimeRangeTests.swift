import XCTest
@testable import Nod

final class SessionTimeRangeTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Thursday, 16 July 2026, midday.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)) ?? .distantPast
    }

    private func day(_ day: Int, _ month: Int = 7, _ year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    private func resolve(_ period: String) -> DateInterval? {
        SessionTimeRange.resolve(period: period, now: now, calendar: calendar)
    }

    func testLastWeekIsTheWholeMondayToSundayBefore() throws {
        let window = try XCTUnwrap(resolve("last_week"))
        XCTAssertTrue(window.contains(day(6)), "Mon 6 Jul should be in last week")
        XCTAssertTrue(window.contains(day(12)), "Sun 12 Jul should be in last week")
        XCTAssertFalse(window.contains(day(13)), "Mon 13 Jul is this week")
        XCTAssertFalse(window.contains(day(5)), "Sun 5 Jul is the week before")
    }

    func testThisWeekExcludesLastWeek() throws {
        let window = try XCTUnwrap(resolve("this_week"))
        XCTAssertTrue(window.contains(day(13)))
        XCTAssertFalse(window.contains(day(12)))
    }

    func testYesterdayAndTodayAreSingleDays() throws {
        let yesterday = try XCTUnwrap(resolve("yesterday"))
        XCTAssertTrue(yesterday.contains(day(15)))
        XCTAssertFalse(yesterday.contains(day(16)))

        let today = try XCTUnwrap(resolve(" Today "))
        XCTAssertTrue(today.contains(day(16)))
    }

    func testMonthWindows() throws {
        let lastMonth = try XCTUnwrap(resolve("last_month"))
        XCTAssertTrue(lastMonth.contains(day(3, 6)))
        XCTAssertFalse(lastMonth.contains(day(1)))

        let thisMonth = try XCTUnwrap(resolve("this_month"))
        XCTAssertTrue(thisMonth.contains(day(2)))
    }

    func testTrailingWindows() throws {
        let days = try XCTUnwrap(resolve("last_3_days"))
        XCTAssertTrue(days.contains(day(14)))
        XCTAssertFalse(days.contains(day(12)))
        XCTAssertEqual(days.end, now)

        XCTAssertNil(resolve("last_0_days"))
        XCTAssertNil(resolve("last_many_days"))
    }

    func testExplicitDatesCoverBothEnds() throws {
        let window = try XCTUnwrap(resolve("2026-07-06..2026-07-08"))
        XCTAssertTrue(window.contains(day(6)))
        XCTAssertTrue(window.contains(day(8)))
        XCTAssertFalse(window.contains(day(9)))

        XCTAssertEqual(resolve(" 2026-07-06 .. 2026-07-08 "), window)
        XCTAssertNil(resolve("2026-07-08..2026-07-06"))
    }

    func testOneDateIsThatDay() throws {
        let window = try XCTUnwrap(resolve("2026-07-08"))
        XCTAssertTrue(window.contains(day(8)))
        XCTAssertFalse(window.contains(day(9)))
    }

    func testADateThatDoesNotExistIsNoPeriod() {
        XCTAssertNil(resolve("2026-13-45"))
        XCTAssertNil(resolve("2026-02-30..2026-03-02"))
        XCTAssertNil(resolve("2026-07-06..soon"))
        XCTAssertNil(resolve("26-07-06"))
        XCTAssertNil(resolve("2026--07-06"))
        XCTAssertNil(resolve("2026-07-06..2026-07-07..2026-07-08"))
    }

    func testAnOpenRangeEndsNow() throws {
        let window = try XCTUnwrap(resolve("2026-07-06.."))
        XCTAssertTrue(window.contains(day(6)))
        XCTAssertEqual(window.end, now)
        XCTAssertNil(resolve("2026-08-01.."), "a range that has not started names no past")
    }

    /// "A report on project X" reads to the model as a question about a
    /// topic, and the flag alone then denied the period instead of recapping it.
    func testAStandupReportIsAboutOwnWorkWhateverTheFlagSays() {
        let report = LLMProxyClient.PreparedQuery(standalone: "report", period: SessionTimeRange.sinceLastWorkdayKey)
        XCTAssertTrue(report.asksAboutOwnWork)
        XCTAssertFalse(LLMProxyClient.PreparedQuery(standalone: "what did Leo say last week", period: "last_week").asksAboutOwnWork)
    }

    /// The report for Monday's standup is about Friday, not about the hour
    /// between waking up and asking for it.
    func testAStandupReportReachesBackOverTheWeekend() throws {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 9)) ?? .distantPast
        let window = try XCTUnwrap(SessionTimeRange.resolve(period: "since_last_workday", now: monday, calendar: calendar))
        XCTAssertTrue(window.contains(day(17)), "Fri 17 Jul is the previous working day")
        XCTAssertFalse(window.contains(day(16)))
        XCTAssertEqual(window.end, monday)

        let midweek = try XCTUnwrap(resolve("since_last_workday"))
        XCTAssertTrue(midweek.contains(day(15)))
        XCTAssertFalse(midweek.contains(day(14)))
    }

    func testAnUpcomingPeriodLooksBackAtRecentSessionsInstead() {
        // There are no sessions in the future — the plans for it were stated in
        // the days before, so that's what has to be searched.
        let lookback = resolve(SessionTimeRange.upcoming)
        XCTAssertEqual(lookback?.contains(day(10)), true, "three weeks back is in scope")
        XCTAssertEqual(lookback?.contains(day(20, 6)), false, "a month back is not")
    }

    func testFuturePhrasesAreRecognised() {
        XCTAssertTrue(SessionTimeRange.mentionsFuture(in: "що заплановано на наступний тиждень?"))
        XCTAssertTrue(SessionTimeRange.mentionsFuture(in: "what's due tomorrow?"))
        XCTAssertFalse(SessionTimeRange.mentionsFuture(in: "what happened last week?"))
    }

    func testNoPeriodStaysUnscoped() {
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("sometime"))
    }
}

final class TextSnippetTests: XCTestCase {
    private let summary = "The team agreed to keep pricing at nineteen euros until launch. Sam will redo the onboarding copy, and Dima takes the analytics platform through to prod by Tuesday."

    func testSnippetIsCentredOnTheMatch() throws {
        let snippet = try XCTUnwrap(TextSnippet.around("analytics", in: summary))
        XCTAssertTrue(snippet.lowercased().contains("analytics"), snippet)
        XCTAssertTrue(snippet.hasPrefix("…"), "context before the match is trimmed away: \(snippet)")
        XCTAssertLessThan(snippet.count, summary.count)
    }

    func testMatchAtTheStartHasNoLeadingEllipsis() throws {
        let snippet = try XCTUnwrap(TextSnippet.around("The team", in: summary))
        XCTAssertFalse(snippet.hasPrefix("…"), snippet)
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertNotNil(TextSnippet.around("PRICING", in: summary))
        XCTAssertNotNil(TextSnippet.around("ONBOARDING copy", in: summary))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(TextSnippet.around("kubernetes", in: summary))
        XCTAssertNil(TextSnippet.around("", in: summary))
        XCTAssertNil(TextSnippet.around("anything", in: ""))
    }
}

final class QuestionIntentTests: XCTestCase {
    func testQuestionMarkAtTheEndCounts() {
        XCTAssertTrue(QuestionIntent.isQuestion("як пройшов ван-он-ван з Людвігом?"))
        XCTAssertTrue(QuestionIntent.isQuestion("what did we ship?"))
    }

    func testInterrogativeOpenersCountWithoutAQuestionMark() {
        XCTAssertTrue(QuestionIntent.isQuestion("що вирішили по прайсингу"))
        XCTAssertTrue(QuestionIntent.isQuestion("what did we decide"))
        XCTAssertTrue(QuestionIntent.isQuestion("расскажи про аналитику"))
    }

    func testPlainLookupsStaySearches() {
        XCTAssertFalse(QuestionIntent.isQuestion("analytics platform"))
        XCTAssertFalse(QuestionIntent.isQuestion("Ludwig"))
        XCTAssertFalse(QuestionIntent.isQuestion(""))
    }

    func testBareInterrogativeIsStillASearch() {
        // One word in, the user is typing a name as often as a question.
        XCTAssertFalse(QuestionIntent.isQuestion("how"))
        XCTAssertFalse(QuestionIntent.isQuestion("що"))
    }
}

@MainActor
final class GroundingBudgetTests: XCTestCase {
    func testKeepsWholeExcerptsUntilTheBudgetIsSpent() {
        let excerpts = [String(repeating: "a", count: 400), String(repeating: "b", count: 400), String(repeating: "c", count: 400)]
        let kept = KnowledgeChatStore.withinBudget(excerpts, limit: 900)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.map(\.count), [400, 400], "excerpts are kept whole, never half-truncated")
    }

    func testRetrievalOrderIsPreserved() {
        let kept = KnowledgeChatStore.withinBudget(["first", "second", "third"], limit: 12)
        XCTAssertEqual(kept, ["first", "second"])
    }

    func testOneOversizedExcerptIsTruncatedRatherThanDropped() {
        let kept = KnowledgeChatStore.withinBudget([String(repeating: "x", count: 5000)], limit: 100)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.count, 100, "something to answer from beats nothing")
    }

    func testEverythingFitsUnderBudget() {
        XCTAssertEqual(KnowledgeChatStore.withinBudget(["a", "b"], limit: 1000), ["a", "b"])
    }
}

@MainActor
final class EvidenceTests: XCTestCase {
    private func excerpt(_ meeting: UUID, _ text: String, _ similarity: Double) -> KnowledgeChatStore.Excerpt {
        KnowledgeChatStore.Excerpt(meetingID: meeting, title: "Session", date: "16 Jul", text: text, similarity: similarity)
    }

    func testOnlyTheStrongestPassagePerSessionSurvives() {
        let a = UUID(), b = UUID()
        let kept = KnowledgeChatStore.strongestPerSession([
            excerpt(a, "weak", 0.3),
            excerpt(a, "strong", 0.9),
            excerpt(b, "other", 0.5)
        ])
        XCTAssertEqual(kept.count, 2, "four chunks from one meeting are one piece of evidence")
        XCTAssertEqual(kept.first?.text, "strong")
    }

    func testRetrievalOrderOfSessionsIsKept() {
        let a = UUID(), b = UUID()
        let kept = KnowledgeChatStore.strongestPerSession([excerpt(a, "first", 0.4), excerpt(b, "second", 0.9)])
        XCTAssertEqual(kept.map(\.text), ["first", "second"])
    }

    func testSpeakerTagsAreStripped() {
        XCTAssertEqual(KnowledgeChatStore.readable("[Them]: Okay, good.\n[Me]: Thanks."), "Okay, good. Thanks.")
        XCTAssertEqual(KnowledgeChatStore.readable("  plain text  "), "plain text")
    }
}

final class EntityMatcherTests: XCTestCase {
    private let names = ["Ludwig", "Leo", "Anna Kovalenko", "Anna", "CocoaBot", "AI"]

    func testFindsANamedPerson() {
        XCTAssertEqual(EntityMatcher.matched(names: names, in: "як пройшов ван-он-ван з Людвігом?"), [])
        XCTAssertEqual(EntityMatcher.matched(names: names, in: "what did Ludwig say about pricing?"), ["Ludwig"])
    }

    func testLongestNameWinsSoTheScopeIsTheNarrowest() {
        XCTAssertEqual(
            EntityMatcher.matched(names: names, in: "what did Anna Kovalenko decide"),
            ["Anna Kovalenko", "Anna"],
            "both match, but the more specific one is offered first"
        )
    }

    func testALaterWholeWordCountsWhenTheFirstHitIsInsideAnotherWord() {
        XCTAssertEqual(EntityMatcher.matched(names: ["Leo"], in: "Leonid opened the PR and Leo approved it"), ["Leo"])
        XCTAssertTrue(EntityMatcher.matched(names: ["Leo"], in: "Leonid opened the PR, Leonid merged it").isEmpty)
    }

    func testAMatchStartingInsideAFailedOneIsStillFound() {
        XCTAssertEqual(EntityMatcher.matched(names: ["jo jo"], in: "banjo jo jo"), ["jo jo"])
    }

    func testWholeWordsOnly() {
        // "Leo" inside "Leonid" would scope the answer to the wrong person.
        XCTAssertTrue(EntityMatcher.matched(names: names, in: "what did Leonid think?").isEmpty)
        XCTAssertEqual(EntityMatcher.matched(names: names, in: "Leo's take on the demo"), ["Leo"])
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertEqual(EntityMatcher.matched(names: names, in: "notes about COCOABOT"), ["CocoaBot"])
    }

    func testTooShortToBeAName() {
        // Two-letter entities match inside ordinary words and would scope
        // half the corpus.
        XCTAssertTrue(EntityMatcher.matched(names: names, in: "what about AI?").isEmpty)
    }

    func testNoNamesInAPlainQuestion() {
        XCTAssertTrue(EntityMatcher.matched(names: names, in: "what did we decide about pricing?").isEmpty)
    }
}
