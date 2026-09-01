import XCTest
@testable import Nod

final class TodayViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(
        title: String?,
        daysAgo: Double,
        speakers: [String: String]? = nil,
        icalUID: String? = nil,
        deleted: Bool = false
    ) -> Meeting {
        var sample = Meeting(
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
            speakerNames: speakers,
            deletedAt: deleted ? now : nil
        )
        sample.icalUID = icalUID
        return sample
    }

    private func occurrence(
        _ title: String,
        startsIn minutes: Double,
        attendees: [CalendarAttendee] = [],
        externalID: String? = nil
    ) -> CalendarOccurrence {
        let startsAt = now.addingTimeInterval(minutes * 60)
        var sample = CalendarOccurrence(
            title: title,
            startsAt: startsAt,
            endsAt: startsAt.addingTimeInterval(30 * 60),
            host: nil,
            attendees: attendees
        )
        sample.externalID = externalID
        return sample
    }

    func testGreetingFollowsTheClockAndTheName() throws {
        var noon = DateComponents(); noon.year = 2026; noon.month = 9; noon.day = 1; noon.hour = 9
        let morning = try XCTUnwrap(Calendar.current.date(from: noon))
        XCTAssertEqual(TodayBrief.greeting(for: "Dima Barabash", at: morning), "Good morning, Dima")
        noon.hour = 15
        XCTAssertEqual(
            try TodayBrief.greeting(for: nil, at: XCTUnwrap(Calendar.current.date(from: noon))),
            "Good afternoon"
        )
    }

    func testStartLineNamesTheMinutes() {
        XCTAssertEqual(TodayBrief.startLine(for: occurrence("Sync", startsIn: 24), now: now), "Starts in 24 min")
        XCTAssertEqual(TodayBrief.startLine(for: occurrence("Sync", startsIn: -5), now: now), "Started 5 min ago")
    }

    /// A 12-hour window crosses midnight; a morning meeting shown at 8pm must
    /// not be called "Today".
    func testStartLineKnowsTomorrowFromToday() throws {
        let tonight = try XCTUnwrap(Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: now))
        let start = tonight.addingTimeInterval(11 * 3600)
        let overnight = CalendarOccurrence(
            title: "Early sync", startsAt: start, endsAt: start.addingTimeInterval(1800),
            host: nil, attendees: []
        )
        XCTAssertFalse(Calendar.current.isDate(start, inSameDayAs: tonight))
        XCTAssertTrue(TodayBrief.startLine(for: overnight, now: tonight).hasPrefix("Tomorrow at"))

        let sameDay = try XCTUnwrap(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now))
        let evening = CalendarOccurrence(
            title: "Review", startsAt: sameDay.addingTimeInterval(10 * 3600),
            endsAt: sameDay.addingTimeInterval(10 * 3600 + 1800), host: nil, attendees: []
        )
        XCTAssertTrue(TodayBrief.startLine(for: evening, now: sameDay).hasPrefix("Today at"))
    }

    /// "Ed" is not Edward, and an email display matches only on its own first
    /// token — substring matching once made every short name everyone.
    func testNameTokensMatchWholeFirstWordsOnly() {
        XCTAssertEqual(TodayBrief.nameToken("Sasha K"), "sasha")
        XCTAssertEqual(TodayBrief.nameToken("john.smith@acme.com"), "john")
        XCTAssertNil(TodayBrief.nameToken("Ed"))
        XCTAssertNil(TodayBrief.nameToken("  "))
        let edward = meeting(title: "1:1", daysAgo: 1, speakers: ["1": "Edward Kim"])
        let ed = occurrence(
            "Sync",
            startsIn: 10,
            attendees: [CalendarAttendee(display: "Eddy", isSelf: false, email: nil)]
        )
        XCTAssertNil(TodayBrief.lastSession(before: ed, in: [edward]))
    }

    func testCaptureLabelNamesTheMeeting() {
        XCTAssertEqual(TodayBrief.captureLabel(for: occurrence("Перегляд кв", startsIn: 10)), "Start “Перегляд кв”")
        let long = occurrence(String(repeating: "a", count: 40), startsIn: 10)
        XCTAssertTrue(TodayBrief.captureLabel(for: long).hasSuffix("…”"))
    }

    /// The invitation id outranks name matching — two people can share a first
    /// name, but never an iCalendar UID.
    func testLastSessionPrefersTheInvitationItself() {
        let byName = meeting(title: "Old sync", daysAgo: 3, speakers: ["1": "Sasha"])
        let byInvite = meeting(title: "Same series", daysAgo: 7, icalUID: "abc-123")
        let next = occurrence(
            "Team Context",
            startsIn: 10,
            attendees: [CalendarAttendee(display: "Sasha", isSelf: false, email: nil)],
            externalID: "abc-123"
        )
        XCTAssertEqual(
            TodayBrief.lastSession(before: next, in: [byName, byInvite])?.id,
            byInvite.id
        )
    }

    /// The list is newest-first, as the store keeps it; the first match is the
    /// most recent by construction, not by sorting here.
    func testLastSessionFallsBackToTheSamePeople() {
        let withSasha = meeting(title: "Sync", daysAgo: 2, speakers: ["1": "Sasha K"])
        let unrelated = meeting(title: "1:1", daysAgo: 1, speakers: ["1": "Vlad"])
        let trashed = meeting(title: "Old", daysAgo: 0.5, speakers: ["1": "Sasha K"], deleted: true)
        let next = occurrence(
            "Team Context",
            startsIn: 10,
            attendees: [CalendarAttendee(display: "Sasha", isSelf: false, email: nil)]
        )
        XCTAssertEqual(
            TodayBrief.lastSession(before: next, in: [trashed, unrelated, withSasha])?.id,
            withSasha.id
        )
        XCTAssertNil(TodayBrief.lastSession(before: next, in: [unrelated]))
    }

    func testReportPreviewSkipsHeadingsAndBlankLines() {
        XCTAssertEqual(
            TodayBrief.firstLine(of: "# Who's waiting\n\nNobody is blocked on you today.\nMore detail."),
            "Nobody is blocked on you today."
        )
        XCTAssertEqual(TodayBrief.firstLine(of: ""), "")
    }

    /// A run is new until its row was opened, and opening it retires exactly
    /// that run — not the one the next morning brings.
    func testSeenWatermarkRetiresOnlyWhatWasOpened() {
        let beat = Beat(
            id: UUID(), userID: UUID(), title: "Who's waiting on me?", prompt: "who waits",
            cadence: .daily, hour: 8, minute: 30, weekday: 2, dayOfMonth: 1,
            timezone: "Europe/Kyiv", enabled: true, nextRunAt: nil, createdAt: now
        )
        let run = BeatRun(id: UUID(), beatID: beat.id, userID: beat.userID, scheduledFor: now, statusRaw: "done", threadID: nil, error: nil)
        defer { UserDefaults.standard.removeObject(forKey: "today.beatSeen.\(beat.id.uuidString)") }

        XCTAssertTrue(TodayBrief.isUnseen(run, of: beat))
        TodayBrief.markSeen(run, of: beat)
        XCTAssertFalse(TodayBrief.isUnseen(run, of: beat))

        let tomorrow = BeatRun(
            id: UUID(), beatID: beat.id, userID: beat.userID,
            scheduledFor: now.addingTimeInterval(86_400), statusRaw: "done", threadID: nil, error: nil
        )
        XCTAssertTrue(TodayBrief.isUnseen(tomorrow, of: beat))
    }
}

/// The action drawer's words, pinned because they are what a colleague
/// receives and what the person believes happened.
final class ActionDelegationTests: XCTestCase {
    private func item(_ text: String) -> ActionItem {
        ActionItem(
            id: UUID(), meetingID: UUID(), userID: UUID(), text: text,
            deadline: nil, kind: .action, status: .confirmed, source: .recap,
            revisionOf: nil, evidenceIdx: nil, evidenceQuote: nil, position: 0,
            done: false, doneAt: nil, loopState: .open,
            externalProvider: nil, externalKey: nil, externalURL: nil, externalCreatedAt: nil,
            createdAt: nil, updatedAt: nil, deletedAt: nil
        )
    }

    func testDraftAsksAndNamesTheSource() {
        let draft = ActionDelegation.draft(for: item("Записати демо"), source: "Team Context · Aug 31")
        XCTAssertEqual(draft, "Can you pick this up: Записати демо? Context: from \"Team Context · Aug 31\" in Nod.")
        XCTAssertEqual(ActionDelegation.draft(for: item("Можеш глянути?"), source: nil), "Можеш глянути?")
    }

    func testRecordNamesRecipientAndProduct() {
        XCTAssertEqual(ActionDelegation.record(recipient: "Vlad", via: .slack), "Delegated to Vlad via Slack")
        // A picked person goes by the address the picker resolved, never by a
        // first name two colleagues could share.
        XCTAssertEqual(
            ActionDelegation.sendArguments(target: .person(name: "Vlad K", email: "vlad@x.com"), typed: "Vlad K", message: "hi"),
            ["to": "vlad@x.com", "text": "hi"]
        )
        XCTAssertEqual(ActionDelegation.record(recipient: "#product", via: .slack), "Delegated to #product via Slack")
    }

    /// The picker reads the same payloads the chat's tools return, envelope
    /// included, and shrugs off an error body instead of crashing the form.
    func testDirectoryDecodesToolResults() {
        let people = #"{"result":{"users":[{"id":"U1","name":"Vlad K","email":"vlad@x.com"}]}}"#
        let channels = #"{"result":{"channels":[{"id":"C1","name":"product","purpose":"Roadmap","joined":true}]}}"#
        let directory = ActionDelegation.directory(people: people, channels: channels)
        XCTAssertEqual(directory.people, [.person(name: "Vlad K", email: "vlad@x.com")])
        XCTAssertEqual(directory.channels, [.channel(id: "C1", name: "product", purpose: "Roadmap")])

        let broken = ActionDelegation.directory(
            people: #"{"error":{"code":"reauthorize","message":"no"}}"#,
            channels: "not json"
        )
        XCTAssertEqual(broken, ActionDelegation.Directory())
    }

    func testMatchesOfferPeopleFirstAndChannelsOnHash() {
        let directory = ActionDelegation.Directory(
            people: [.person(name: "Vlad K", email: "vlad@x.com")],
            channels: [.channel(id: "C1", name: "vlad-updates", purpose: "")]
        )
        XCTAssertEqual(
            ActionDelegation.matches(for: "vla", in: directory).map(\.display),
            ["Vlad K", "#vlad-updates"]
        )
        XCTAssertEqual(
            ActionDelegation.matches(for: "#vla", in: directory).map(\.display),
            ["#vlad-updates"]
        )
        XCTAssertEqual(ActionDelegation.matches(for: "  ", in: directory), [])
    }

    /// A channel posts by the id Slack requires; a person — picked or merely
    /// typed — goes by name.
    func testSendArgumentsMatchTheTargetKind() {
        XCTAssertEqual(
            ActionDelegation.sendArguments(
                target: .channel(id: "C1", name: "product", purpose: ""),
                typed: "#product",
                message: "hi"
            ),
            ["channel_id": "C1", "text": "hi"]
        )
        XCTAssertEqual(
            ActionDelegation.sendArguments(target: nil, typed: "Vlad", message: "hi"),
            ["to": "Vlad", "text": "hi"]
        )
    }

    func testArgumentsEncodeAsPlainJSON() {
        XCTAssertEqual(
            ActionDelegation.encode(["text": "hi", "to": "Vlad"]),
            "{\"text\":\"hi\",\"to\":\"Vlad\"}"
        )
    }
}

/// The ambient scopes' pure pieces: when a hint was seen, the sentence a hint
/// may add to a draft, and the toggle that keeps checkbox and editor agreeing.
final class AmbientScopesTests: XCTestCase {
    func testWhenSpeaksInDays() throws {
        // Local midday, not a raw epoch: 1_800_000_000 is exactly midnight in
        // Pacific time, where "an hour ago" is yesterday.
        let now = try XCTUnwrap(
            Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))
        )
        XCTAssertTrue(AmbientScopes.when(now.addingTimeInterval(-3600), now: now).hasPrefix("Today "))
        XCTAssertTrue(AmbientScopes.when(now.addingTimeInterval(-86_400), now: now).hasPrefix("Yesterday "))
        XCTAssertFalse(AmbientScopes.when(now.addingTimeInterval(-5 * 86_400), now: now).contains(":"))
    }

    func testTogglingIsItsOwnUndo() {
        let base = "Can you pick this up?"
        let addition = "Related: I've been working in Figma — Severus demo flow."
        let added = ActionDelegation.toggling(message: base, addition: addition)
        XCTAssertEqual(added, base + "\n" + addition)
        XCTAssertEqual(ActionDelegation.toggling(message: added, addition: addition), base)
        XCTAssertEqual(ActionDelegation.toggling(message: "", addition: addition), addition)
    }
}

/// The intent table is the seam between "what should happen" and "which tool":
/// an intent shows only when something connected can carry it, and no intent
/// ever names a product in its title.
final class ActionIntentTests: XCTestCase {
    func testIntentsFollowWhatIsConnected() {
        XCTAssertEqual(ActionIntent.available(usable: { _ in false }), [])
        XCTAssertEqual(
            ActionIntent.available(usable: { $0 == .slack }),
            [.sendMessage]
        )
        XCTAssertEqual(
            ActionIntent.available(usable: { $0 == .jira || $0 == .googleCalendar }),
            [.createTask, .scheduleMeeting, .addReminder]
        )
    }

    func testSuggestionsNameOutcomesNotTools() {
        let item = ActionItem(
            id: UUID(), meetingID: UUID(), userID: UUID(), text: "Send Sasha the revised pricing model",
            deadline: nil, kind: .action, status: .confirmed, source: .recap,
            revisionOf: nil, evidenceIdx: nil, evidenceQuote: nil, position: 0,
            done: false, doneAt: nil, loopState: .open,
            externalProvider: nil, externalKey: nil, externalURL: nil, externalCreatedAt: nil,
            createdAt: nil, updatedAt: nil, deletedAt: nil
        )
        for intent in ActionIntent.allCases {
            let title = intent.contextTitle(for: item)
            for provider in IntegrationProvider.allCases {
                XCTAssertFalse(title.localizedCaseInsensitiveContains(provider.displayName), "\(title) names a product")
            }
        }
        XCTAssertEqual(ActionIntent.createTask.contextTitle(for: item), "Create “Send Sasha the revised pricing…” as a task")
    }
}

/// The calendar form's wire format and defaults, and the plan field's
/// @-mention mechanics.
final class CalendarPlanTests: XCTestCase {
    func testArgumentsCarryLocalOffsetTimes() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let arguments = CalendarPlan.arguments(title: " Follow-up ", startsAt: start, durationMinutes: 30, attendees: "")
        XCTAssertEqual(arguments["title"], "Follow-up")
        XCTAssertNil(arguments["attendees"])
        let starts = try XCTUnwrap(arguments["starts_at"])
        let rfc3339 = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#)
        XCTAssertNotNil(rfc3339.firstMatch(in: starts, range: NSRange(starts.startIndex..., in: starts)), starts)
        XCTAssertEqual(ServerTimestamp.date(from: starts), start)
        XCTAssertEqual(try ServerTimestamp.date(from: XCTUnwrap(arguments["ends_at"])), start.addingTimeInterval(1800))
    }

    func testReminderDefaultsToTomorrowMorning() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = CalendarPlan.defaultStart(for: .reminder, now: now)
        XCTAssertEqual(Calendar.current.component(.hour, from: start), 9)
        XCTAssertTrue(start > now)
    }

    func testMentionFragmentOpensOnlyAtWordStart() {
        XCTAssertEqual(ActionDelegation.mentionFragment(in: "ask @Sl"), "Sl")
        XCTAssertEqual(ActionDelegation.mentionFragment(in: "@"), "")
        XCTAssertNil(ActionDelegation.mentionFragment(in: "vlad@x.com"))
        XCTAssertNil(ActionDelegation.mentionFragment(in: "ask @Slack about it"))
    }

    func testInsertingMentionWritesTheChatToken() {
        XCTAssertEqual(
            ActionDelegation.inserting(mention: .slack, into: "ask @Sl"),
            "ask @Slack "
        )
    }
}

/// The assignable-people decode reads the exact `{result:{users:[…]}}` shape
/// the trackers' `list_users` answers with, and drops rows it cannot name.
final class AssigneeDecodeTests: XCTestCase {
    func testPeopleDecodeAndSkipNameless() {
        let result = #"{"result":{"users":[{"id":"u1","name":"Vlad K","email":"v@x.com"},{"id":"u2","email":"ghost@x.com"}]}}"#
        XCTAssertEqual(
            ActionDelegation.people(in: result),
            [ActionDelegation.Person(id: "u1", name: "Vlad K")]
        )
        XCTAssertEqual(ActionDelegation.people(in: #"{"error":{"code":"x","message":"no"}}"#), [])
    }
}

/// The availability math the meeting form schedules by: decode, conflict
/// detection, and the next slot everyone can actually accept.
final class AvailabilityTests: XCTestCase {
    private let noon = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000)
    ) ?? Date(timeIntervalSince1970: 1_800_000_000)

    func testAvailabilityDecodesBusyBlocksAndUnreadables() {
        let result = #"{"result":{"people":[{"email":"a@x.com","readable":true,"busy":[{"starts_at":"2026-09-01T18:00:00Z","ends_at":"2026-09-01T19:00:00Z"}]},{"email":"b@x.com","readable":false,"busy":[]}]}}"#
        let people = CalendarPlan.availability(in: result)
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(people[0].busy.count, 1)
        XCTAssertFalse(people[1].readable)
        XCTAssertEqual(CalendarPlan.availability(in: #"{"error":{"code":"x","message":"no"}}"#), [])
    }

    func testUnreadableIsNeitherFreeNorAConflict() {
        let slot = DateInterval(start: noon, duration: 1800)
        let ghost = CalendarPlan.BusyPerson(email: "g@x.com", readable: false, busy: [])
        let clashing = CalendarPlan.BusyPerson(
            email: "c@x.com", readable: true,
            busy: [DateInterval(start: noon.addingTimeInterval(-600), duration: 1200)]
        )
        XCTAssertEqual(CalendarPlan.conflicted(slot: slot, people: [ghost, clashing]).map(\.email), ["c@x.com"])
    }

    func testNextFreeStartSkipsPastTheBusyBlock() throws {
        let start = try XCTUnwrap(Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: noon))
        let busy = CalendarPlan.BusyPerson(
            email: "a@x.com", readable: true,
            busy: [DateInterval(start: start, duration: 3600)]
        )
        let free = try XCTUnwrap(CalendarPlan.nextFreeStart(near: start, duration: 1800, people: [busy]))
        XCTAssertEqual(free, start.addingTimeInterval(3600))

        let allDay = CalendarPlan.BusyPerson(
            email: "b@x.com", readable: true,
            busy: [DateInterval(start: Calendar.current.startOfDay(for: start), duration: 24 * 3600)]
        )
        XCTAssertNil(CalendarPlan.nextFreeStart(near: start, duration: 1800, people: [allDay]))
    }

    /// Half-typed addresses are not guests yet, and one address twice is one
    /// guest — both used to reach the server, one as a rejection, one as a
    /// duplicated row.
    func testEmailsIgnoreNoiseAndDuplicates() {
        XCTAssertEqual(
            CalendarPlan.emails(in: " a@x.com, Vlad, b@x.com , a@x, A@X.COM, c@x."),
            ["a@x.com", "b@x.com"]
        )
    }

    func testUnresolvedNamesAreNamedNotDropped() {
        XCTAssertEqual(CalendarPlan.unresolvedNames(in: "a@x.com, Vlad, b@x"), "Vlad, b@x")
        XCTAssertNil(CalendarPlan.unresolvedNames(in: "a@x.com, "))
    }

    func testMeetingDefaultNeverLandsInThePast() throws {
        let late = try XCTUnwrap(Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: noon))
        XCTAssertGreaterThan(CalendarPlan.defaultStart(for: .meeting, now: late), late)
    }
}

/// The invite field's contact pool: directory plus calendar attendees, and the
/// typing mechanics that turn a name into an address.
final class InviteContactsTests: XCTestCase {
    private let pool = CalendarPlan.contacts(
        people: [("Vlad Kampov", "vlad@x.com"), (nil, "no-name@x.com"), ("Ghost", nil)],
        attendees: [("Sasha", "sasha@x.com"), ("vlad k", "VLAD@x.com"), ("Room 4", nil)]
    )

    func testDirectoryNameOutranksCalendarSpelling() {
        XCTAssertEqual(pool.first { $0.email == "vlad@x.com" }?.name, "Vlad Kampov")
        XCTAssertTrue(pool.contains(CalendarPlan.Contact(name: "Sasha", email: "sasha@x.com")))
        XCTAssertTrue(pool.contains { $0.email == "no-name@x.com" && $0.name == "no-name@x.com" })
        XCTAssertFalse(pool.contains { $0.name == "Ghost" })
    }

    func testMatchesFollowTheOpenFragment() {
        XCTAssertEqual(
            CalendarPlan.matches(for: "sasha@x.com, vl", in: pool, excluding: ["sasha@x.com"]).map(\.email),
            ["vlad@x.com"]
        )
        XCTAssertEqual(CalendarPlan.matches(for: "sasha@x.com, ", in: pool, excluding: []), [])
        XCTAssertEqual(CalendarPlan.matches(for: "vlad@x.com", in: pool, excluding: []), [])
    }

    func testCompletingReplacesTheFragmentAndKeepsTheList() {
        XCTAssertEqual(
            CalendarPlan.completing("sasha@x.com, vl", with: "vlad@x.com"),
            "sasha@x.com, vlad@x.com, "
        )
        XCTAssertEqual(CalendarPlan.completing("vl", with: "vlad@x.com"), "vlad@x.com, ")
    }
}
