import Foundation

/// What Nod already knows about the call that is starting.
///
/// The one thing a note-taker can say before a meeting that no note-taker says:
/// *you have had this conversation before, and this much of it is still open.*
/// The archive already holds the answer; by the time the user goes looking for
/// it the call is over, so it has to arrive on the way in.
///
/// Assembled entirely from what is already on the Mac — the meeting's name,
/// matched against the titles of sessions already recorded. Nothing about the
/// live call is stored, and nothing is sent anywhere to build it: no lookup, no
/// embedding, no model call (`privacy.md` § 3.10(c), § 3.11).
struct CallBrief: Equatable {
    /// The earlier session this call continues, under its own recorded title —
    /// not the window's. The window says "Meet – Weekly planning"; the session
    /// says what Nod actually filed it as, and that is what the user will
    /// recognise.
    let title: String
    let lastMet: Date
    let openCommitments: Int

    func line(relativeTo now: Date = Date()) -> String {
        var parts = ["Continues \(title)", Meeting.ago(lastMet, relativeTo: now)]
        if openCommitments > 0 {
            parts.append("\(openCommitments) \(openCommitments == 1 ? "item" : "items") still open")
        }
        return parts.joined(separator: " · ")
    }
}

extension CallBrief {
    /// The brief for a meeting by name, or nil when nothing certain enough can
    /// be said.
    ///
    /// Nil is the common answer and the right one. A wrong brief on the way into
    /// a meeting is worse than none: the user reads it, believes Nod recognised
    /// the call, and carries a false memory into the room. Every threshold below
    /// is set to stay quiet rather than guess.
    static func build(named name: String?, meetings: [Meeting], actionItems: [ActionItem]) -> CallBrief? {
        guard let name else { return nil }
        let subject = subjectTokens(in: name)
        guard !subject.isEmpty else { return nil }

        let matched = meetings.live().filter { meeting in
            guard let title = meeting.title else { return false }
            return matches(subject: subject, session: subjectTokens(in: title))
        }
        // `max`, not `first`: the caller's array is newest-first today, but
        // nothing about "give me the most recent match" should depend on that.
        guard let newest = matched.max(by: { $0.startedAt < $1.startedAt }), let title = newest.title
        else { return nil }

        let ids = Set(matched.map(\.id))
        let open = actionItems.filter { ids.contains($0.meetingID) && $0.isOpen }
        return CallBrief(title: title, lastMet: newest.startedAt, openCommitments: open.count)
    }

    /// What a title is *about*, once the app's own furniture is taken out.
    ///
    /// Subtractive rather than a list of patterns to strip, because the same
    /// words arrive in a different arrangement from every app — "Meeting in
    /// Design | Microsoft Teams", "Meet – Weekly planning - Google Chrome",
    /// "Zoom Meeting". Dropping the words that belong to the product leaves the
    /// words that belong to the meeting, whatever order they came in.
    private static func subjectTokens(in title: String) -> Set<String> {
        Set(
            TextTokens.words(in: title)
                .filter { $0.count >= minimumTokenLength && !furniture.contains($0) }
        )
    }

    /// Whether a recorded session is the same conversation as the live one.
    ///
    /// Containment, not Jaccard: a window title is usually shorter than the
    /// title Nod filed the session under ("Weekly planning" against "Weekly
    /// planning sync"), and Jaccard punishes exactly that difference in length —
    /// the right match scored 0.67 and the threshold that let it through let
    /// half the library through with it.
    ///
    /// Two shared words at minimum, and deliberately no exception for one
    /// distinctive-looking word. Any rule for "distinctive" is a rule about a
    /// language: session titles are written by the model in the user's
    /// `LanguagePreference`, so a list of generic English words ("sync",
    /// "standup") vetoes nothing for a Ukrainian user — "зустріч" would sail
    /// through as a *subject* word and match confidently on exactly the kind of
    /// word the list exists to reject. Counting how often a word appears in the
    /// user's own titles fails differently and worse: a topic that genuinely
    /// recurs is frequent for the same reason a generic word is, so "Onboarding"
    /// in two of eight sessions gets vetoed as commonplace — the very match this
    /// is for. Requiring two words needs no notion of distinctiveness at all.
    /// The cost is a one-word subject never matching, which is the thin case,
    /// and it fails toward silence.
    private static func matches(subject: Set<String>, session: Set<String>) -> Bool {
        let shared = subject.intersection(session)
        guard shared.count >= minimumSharedWords else { return false }
        return Double(shared.count) / Double(min(subject.count, session.count)) >= containment
    }

    private static let minimumTokenLength = 3
    private static let minimumSharedWords = 2
    private static let containment = 0.75

    /// Words that belong to the conferencing product rather than to the meeting.
    ///
    /// Both product lists are read rather than retyped — the Mac apps from
    /// `ConferencingApp`, the web products from `ConferencingHost`'s link
    /// markers. Both grow (`teamsClassic` and `brave` were added to one;
    /// `whereby` to the other), and a case added without a matching word here
    /// would silently stop stripping that product's name — which surfaces as a
    /// confident wrong match, not as a visible failure. The literals are only
    /// the words neither enum owns.
    private static let furniture: Set<String> = Set(
        ConferencingApp.allCases.flatMap { TextTokens.words(in: $0.displayName) }
            + ConferencingHost.allCases.flatMap { $0.markers.flatMap(TextTokens.words) }
    ).union([
        "meeting", "meetings", "webinar", "huddle", "call", "jitsi",
        "www", "https", "join", "room", "the", "and", "for", "with"
    ])
}

/// Looks a brief up from what the app has already loaded.
///
/// Not a store of its own and deliberately not an `ObservableObject`: it holds
/// no state, and its sources are already published. It exists so the notch takes
/// one dependency for this instead of three, and so nothing here ever waits on
/// the network — a brief that arrives after the card is gone is no brief.
@MainActor
struct CallBriefing {
    let meetings: MeetingStore
    let actionItems: ActionItemStore
    let calendar: CalendarService

    /// The calendar wins outright when it has an answer. A calendar entry names
    /// the meeting the way the people in it do, names it the same way next week,
    /// and carries none of the product's own furniture — where a window title is
    /// "Zoom Meeting" about half the time and a room code most of the rest. The
    /// window title is the fallback for a call nobody put in a calendar.
    func context(for offer: MeetingOffer) -> CallContext {
        switch offer {
        case let .scheduled(meeting):
            // The calendar already answered both halves — no second query, and
            // the proactive card gets the brief the detected one always had.
            CallContext(
                brief: CallBrief.build(
                    named: meeting.title,
                    meetings: meetings.meetings,
                    actionItems: actionItems.items
                )?.line(),
                attendees: meeting.others
            )
        case let .detected(call):
            context(forDetected: call)
        }
    }

    private func context(forDetected call: DetectedCall) -> CallContext {
        // One query, both answers: the name to match on and the people invited
        // come from the same entry, and asking twice would run the calendar
        // twice on the frame the card appears.
        let scheduled = calendar.meetingsNow(app: call.app).first
        return CallContext(
            brief: CallBrief.build(
                named: scheduled?.title ?? call.title,
                meetings: meetings.meetings,
                actionItems: actionItems.items
            )?.line(),
            // Through the same rule the finalize uses, not a second copy of it:
            // the card has no roster to fall back to today, and the day it does
            // the precedence must not be re-derived here.
            attendees: MeetingParticipants.resolve(calendar: scheduled, roster: nil).names
        )
    }
}

/// Everything the offer card can say about a call beyond naming the app.
struct CallContext: Equatable {
    /// "Continues Weekly planning · 3d ago · 2 items still open", when a past
    /// session matches this one.
    let brief: String?
    /// Who else is invited, when the calendar knows. Never the user.
    let attendees: [String]

    static let none = CallContext(brief: nil, attendees: [])

    var isEmpty: Bool {
        brief == nil && attendees.isEmpty
    }

    /// "With Leo Fischer and Anna Kovalenko", or "…and 3 others" past what fits.
    ///
    /// Three names is where a card stops being read and starts being scanned,
    /// and the count carries the rest — knowing there are six people is the part
    /// that changes how you walk in.
    var withLine: String? {
        Self.withLine(attendees)
    }

    static func withLine(_ attendees: [String]) -> String? {
        guard !attendees.isEmpty else { return nil }
        guard attendees.count > 3 else {
            return TextList.prose(attendees).map { "With \($0)" }
        }
        let shown = Array(attendees.prefix(2))
        return TextList.prose(shown + ["\(attendees.count - shown.count) others"]).map { "With \($0)" }
    }
}
