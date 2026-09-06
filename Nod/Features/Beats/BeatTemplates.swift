import Foundation

/// The library: beats worth having before anyone has written one.
///
/// Two rules hold this list together.
///
/// **A beat is named as a question**, because that is literally what it is — a
/// saved question Nod re-asks. The library people compare us to names them as
/// jobs ("Action Item Sync"), which reads as a workflow product; ours reads as
/// the thing you would have typed.
///
/// **Nothing here can lie about what Nod holds.** No beat needs the open web,
/// nothing sends anything anywhere, and a beat that needs a connected product
/// says which one on its card and cannot be set up until it is linked — an
/// empty report is a worse answer than a card that says what to connect.
enum BeatTemplates {
    enum Category: String, CaseIterable, Identifiable {
        case day = "Your day"
        case people = "Promises & people"
        case decisions = "What was decided"
        case work = "Work in flight"
        case channels = "Inbox & channels"
        case review = "Week & month"

        var id: String {
            rawValue
        }
    }

    struct Template: Identifiable, Equatable {
        var id: String {
            title
        }

        let title: String
        /// What the card says. The prompt is instructions written to a model; a
        /// card is read by a person deciding whether they want this in their
        /// morning, so it gets its own sentence.
        let summary: String
        let prompt: String
        let category: Category
        let cadence: Beat.Cadence
        let hour: Int
        let minute: Int
        /// ISO weekday, read only when `cadence` is `.weekly`.
        var weekday: Int = 1
        /// Read only when `cadence` is `.monthly`.
        var dayOfMonth: Int = 1
        /// The product this beat reads. Nil when it answers from Nod's own
        /// record — sessions, the screen record, the calendar.
        var requires: IntegrationProvider?
        /// Read when connected, done without when not.
        var uses: [IntegrationProvider] = []

        var products: [IntegrationProvider] {
            ([requires].compactMap { $0 } + uses).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    /// Every template in the category, the ones whose product is not linked
    /// included: those are the reason to connect it, and hiding them made the
    /// library shrink without saying why.
    static func inCategory(_ category: Category) -> [Template] {
        every.filter { $0.category == category }
    }

    /// The template a saved beat was set up from, when its question is still
    /// the template's.
    static func template(of beat: Beat) -> Template? {
        every.first { $0.prompt == beat.prompt }
    }

    static let every: [Template] = [
        Template(
            title: "What's on me today?",
            summary: "The calendar, the promises and yesterday's loose ends, before the day starts moving.",
            prompt: """
            What does my day look like? Cover what is on my calendar, what I \
            said I would do and haven't, and anything from yesterday that is \
            still open.
            """,
            category: .day,
            cadence: .weekdays,
            hour: 9,
            minute: 0,
            uses: [.googleCalendar]
        ),
        Template(
            title: "What did I get done today?",
            summary: "An honest end-of-day read: what moved, what didn't, and what you left mid-sentence.",
            prompt: """
            What did I actually work on today, what moved forward, and what did \
            I leave unfinished?
            """,
            category: .day,
            cadence: .weekdays,
            hour: 18,
            minute: 0,
            uses: [.linear, .github]
        ),
        Template(
            title: "What did I leave open yesterday?",
            summary: "Yesterday's unfinished work, named before it turns into next week's.",
            prompt: "What did I work on yesterday, and what did I leave unfinished?",
            category: .day,
            cadence: .weekdays,
            hour: 9,
            minute: 30
        ),
        Template(
            title: "What should I prepare for tomorrow?",
            summary: "Tomorrow's meetings and what each one will expect you to have ready.",
            prompt: """
            What is on my calendar tomorrow, and what should I have ready for \
            each of it? Use what my recent sessions say about each meeting.
            """,
            category: .day,
            cadence: .weekdays,
            hour: 17,
            minute: 30,
            uses: [.googleCalendar]
        ),

        Template(
            title: "Who's waiting on me?",
            summary: "The people whose work stops until you do something, and what that something is.",
            prompt: """
            Who is waiting on something from me right now? Name the person, \
            what they are waiting for, and where it came from.
            """,
            category: .people,
            cadence: .weekdays,
            hour: 9,
            minute: 15,
            uses: [.gmail, .slack]
        ),
        Template(
            title: "What did I promise out loud?",
            summary: "The commitments you made in conversation that nothing has followed up on.",
            prompt: """
            What did I commit to in my recent sessions that has had no \
            follow-up since? Name the person and the session each came from.
            """,
            category: .people,
            cadence: .weekly,
            hour: 10,
            minute: 0,
            weekday: 1
        ),
        Template(
            title: "What should I raise at my next one-to-one?",
            summary: "What you last discussed with them, and what has happened since.",
            prompt: """
            What should I raise at my next one-to-one? Pull from what we last \
            discussed and what has happened since then.
            """,
            category: .people,
            cadence: .weekly,
            hour: 8,
            minute: 30,
            weekday: 1
        ),
        Template(
            title: "Who have I gone quiet on?",
            summary: "The people who were in your week and then weren't.",
            prompt: """
            Which people came up regularly in my sessions and then stopped? \
            Say when we last spoke and what was open at the time.
            """,
            category: .people,
            cadence: .weekly,
            hour: 16,
            minute: 0,
            weekday: 5,
            uses: [.gmail, .slack]
        ),

        Template(
            title: "What did we decide this week?",
            summary: "The week's decisions in one place, with what each one settled.",
            prompt: """
            What was decided in my sessions this week? For each decision say \
            what it settled and who was part of it.
            """,
            category: .decisions,
            cadence: .weekly,
            hour: 17,
            minute: 0,
            weekday: 5
        ),
        Template(
            title: "What questions were left open?",
            summary: "The things a room raised and never came back to.",
            prompt: """
            Which questions came up in my recent sessions and were never \
            answered? Say where each was raised and what it is blocking.
            """,
            category: .decisions,
            cadence: .weekly,
            hour: 10,
            minute: 30,
            weekday: 3
        ),
        Template(
            title: "What keeps coming back?",
            summary: "The subject your meetings re-open every week without closing.",
            prompt: """
            Which topics keep recurring across my sessions without being \
            resolved? Say how long each has been going and what is holding it.
            """,
            category: .decisions,
            cadence: .weekly,
            hour: 11,
            minute: 0,
            weekday: 1
        ),

        Template(
            title: "What's waiting on my review?",
            summary: "Your review queue, ordered by who is blocked behind it.",
            prompt: """
            What is waiting on my review right now? Order it by who is blocked \
            behind each one.
            """,
            category: .work,
            cadence: .weekdays,
            hour: 9,
            minute: 45,
            requires: .github
        ),
        Template(
            title: "Which issues have stalled?",
            summary: "Assigned work that hasn't moved, and what it is waiting on.",
            prompt: """
            Which of my issues have not moved recently? For each, say how long \
            it has been still and what it seems to be waiting on.
            """,
            category: .work,
            cadence: .weekly,
            hour: 10,
            minute: 0,
            weekday: 3,
            requires: .linear
        ),
        Template(
            title: "What did I do that isn't tracked anywhere?",
            summary: "Real work from your sessions and screen that never became a ticket.",
            prompt: """
            What did I work on this week that has no matching issue? Check what \
            is tracked before you say something is missing.
            """,
            category: .work,
            cadence: .weekly,
            hour: 16,
            minute: 30,
            weekday: 5,
            requires: .linear
        ),
        Template(
            title: "What shipped this week?",
            summary: "What actually went out, separated from what was merely discussed.",
            prompt: """
            What shipped this week? Separate what actually went out from what \
            was only planned or discussed.
            """,
            category: .work,
            cadence: .weekly,
            hour: 17,
            minute: 30,
            weekday: 5,
            requires: .github,
            uses: [.linear]
        ),

        Template(
            title: "Which threads are waiting on my reply?",
            summary: "Mail addressed to you that nobody else can answer.",
            prompt: """
            Which email threads are waiting on a reply from me? Say who is \
            waiting and how long it has been.
            """,
            category: .channels,
            cadence: .weekdays,
            hour: 9,
            minute: 30,
            requires: .gmail
        ),
        Template(
            title: "Where was I mentioned?",
            summary: "The messages that named you, without the channels that didn't.",
            prompt: """
            Where was I mentioned in Slack since yesterday, and which of those \
            still need an answer from me?
            """,
            category: .channels,
            cadence: .weekdays,
            hour: 9,
            minute: 15,
            requires: .slack
        ),
        Template(
            title: "What happened while I was away?",
            summary: "The channels you follow, condensed to what changed.",
            prompt: """
            What happened in my Slack channels since yesterday that I should \
            know about? Skip the noise; keep what changes a decision.
            """,
            category: .channels,
            cadence: .weekdays,
            hour: 8,
            minute: 45,
            requires: .slack
        ),

        Template(
            title: "How did the week go?",
            summary: "What was decided, what shipped, and what is still owed to someone.",
            prompt: """
            Summarise my week: what was decided, what shipped, and what I \
            promised someone that is still outstanding.
            """,
            category: .review,
            cadence: .weekly,
            hour: 17,
            minute: 0,
            weekday: 5,
            uses: [.googleCalendar, .linear]
        ),
        Template(
            title: "Where did the week actually go?",
            summary: "The gap between what you planned to work on and what took the hours.",
            prompt: """
            Where did my time actually go this week, against what I said I \
            would work on? Use my sessions and what I had open on screen.
            """,
            category: .review,
            cadence: .weekly,
            hour: 17,
            minute: 30,
            weekday: 5
        ),
        Template(
            title: "How much of my week is meetings?",
            summary: "The recorded hours, and which recurring ones keep taking them.",
            prompt: """
            How much of my week went to meetings, and which recurring ones took \
            the most? Base it on the sessions I actually recorded and say so.
            """,
            category: .review,
            cadence: .weekly,
            hour: 16,
            minute: 0,
            weekday: 5,
            uses: [.googleCalendar]
        ),
        Template(
            title: "What changed this month?",
            summary: "A month's decisions and direction, read in one sitting.",
            prompt: """
            What changed over the past month — decisions taken, work finished, \
            and what is still open going into the next one?
            """,
            category: .review,
            cadence: .monthly,
            hour: 10,
            minute: 0,
            dayOfMonth: 1
        )
    ]
}
