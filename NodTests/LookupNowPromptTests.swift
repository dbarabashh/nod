import XCTest
@testable import Nod

/// The routing model fills `starts_at`/`ends_at` on the calendar tool. Asked
/// "what meetings did I have today" on 26 August it wrote 16 May, then 26
/// January, then 7 September — three windows nobody asked about, each coming
/// back empty and each read out as "there were no meetings in the calendar".
/// Nothing in the prompt had ever told it what day it was.
final class LookupNowPromptTests: XCTestCase {
    /// 26 August 2026 — the day the wrong months were written. Any instant
    /// inside it does; what the tests pin is that the prompt names this day and
    /// not one the model remembered.
    private let now = Date(timeIntervalSince1970: 1_787_773_380)

    private var calendarReads: [ChatTool] {
        ChatTools.definitions(for: [.googleCalendar]).filter { !$0.mutating }
    }

    private var today: String {
        PromptLibrary.sessionDateString(now)
    }

    func testRoutingIsToldTheDateItMustBuildArgumentsFrom() {
        let prompt = PromptLibrary.buildLookupRouting(
            request: "what meetings did I have today",
            tools: calendarReads,
            now: now
        )

        XCTAssertTrue(prompt.system.contains("[NOW]"))
        XCTAssertTrue(prompt.system.contains(today))
        XCTAssertTrue(prompt.system.contains(PromptLibrary.rfc3339String(now)))
    }

    /// The window for "today" is spelled out rather than left to be derived,
    /// because deriving it is the step that went wrong.
    func testTodaysWindowIsGivenAsBothEnds() {
        let midnight = Calendar.current.startOfDay(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: midnight)

        let block = PromptLibrary.nowBlock(now)

        XCTAssertTrue(block.contains(PromptLibrary.rfc3339String(midnight)))
        XCTAssertTrue(block.contains(PromptLibrary.rfc3339String(tomorrow ?? midnight)))
    }

    /// The offset has to be in the argument: the same wall-clock day is a
    /// different window in a different zone, and the calendar tool's own schema
    /// shows an offset in its example.
    func testTheInstantCarriesTheUsersOffset() {
        let stamp = PromptLibrary.rfc3339String(now)

        let expectedLength = stamp.hasSuffix("Z") ? 20 : 25
        XCTAssertEqual(stamp.count, expectedLength, stamp)
        XCTAssertTrue(stamp.hasSuffix("Z") || stamp.contains("+") || stamp.dropFirst(19).contains("-"), stamp)
    }

    /// "Never invent a date" was already in the routing rules and was not
    /// enough — with no clock, every date is invented. The rule now points at
    /// where a real one comes from.
    func testRoutingSendsDatesToTheClockRatherThanForbiddingThem() {
        let prompt = PromptLibrary.buildLookupRouting(request: "anything today", tools: calendarReads, now: now)

        XCTAssertTrue(prompt.system.contains("Dates are the exception and come from [NOW]"))
    }

    /// The answering pass reads back what the tool returned and decides whether
    /// an event is over. Same clock, or it contradicts the call that fetched it.
    func testTheAnsweringPassGetsTheSameClock() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "what meetings did I have today",
            results: [(tool: "google-calendar_list_events", body: "{\"events\":[]}")],
            memory: [],
            now: now
        )

        XCTAssertTrue(prompt.system.contains("[NOW]"))
        XCTAssertTrue(prompt.system.contains(today))
    }

    /// An empty window is what a wrong date looks like, and reporting it as
    /// "you had nothing" is what made the wrong date invisible.
    func testAnEmptyResultIsNotAStatementAboutTheUsersCalendar() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "what meetings did I have today",
            results: [(tool: "google-calendar_list_events", body: "{\"events\":[]}")],
            memory: [],
            now: now
        )

        XCTAssertTrue(prompt.system.contains("not that the user has nothing"))
    }

    func testTheTypedBoxResolvesTodayAgainstTheSameClock() {
        let prompt = PromptLibrary.buildAsk(
            question: "what did we agree today",
            transcript: "something was said",
            known: [],
            now: now
        )

        XCTAssertTrue(prompt.system.contains("[NOW]"))
        XCTAssertTrue(prompt.system.contains(today))
    }
}

/// A created calendar event came back as "running from
/// 2026-09-10T09:00:00+01:00 to 2026-09-10T10:00:00+01:00, with id
/// qe5s6cgkkv914stkm8q4jc8tu4" — the tool's own fields, read out in a sentence
/// meant for a person glancing at a card mid-meeting.
final class MachineValuePromptTests: XCTestCase {
    func testEveryProseSurfaceForbidsMachineValues() {
        let lookup = PromptLibrary.buildLookupAnswer(
            request: "make a meeting for tomorrow",
            results: [("google-calendar.create_event", "{}")],
            memory: []
        ).system
        for prompt in [lookup, PromptLibrary.humanProseStyle] {
            XCTAssertTrue(prompt.contains("Never put a machine value in a sentence"))
            XCTAssertTrue(prompt.contains("no ISO timestamps"))
        }
    }
}
