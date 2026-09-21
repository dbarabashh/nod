import Foundation

/// What a question is asking for, read as typed judgments rather than out of
/// a phrase table or a free-form JSON reply.
///
/// Every field is optional on purpose. Nil means the model was between two
/// answers, and the caller then keeps whatever it would have decided without
/// this — the query-prep model's reading, or the phrase table. Jev is trained
/// mostly on English, and the questions here arrive in whatever language the
/// person speaks, so "unsure" has to be a result and not an error.
struct QuestionReading: Equatable {
    /// In `SessionTimeRange.resolve(period:)`'s vocabulary. Empty means the
    /// question names no period.
    var period: String?
    var asksAboutOwnWork: Bool?
    var needsSessions: Bool?
    var asksAboutNod: Bool?
    var wantsCalendar: Bool?
    var wantsTasks: Bool?
    var wantsAgents: Bool?
    var wantsProjects: Bool?
    /// People and projects the question certainly refers to, in any spelling.
    var named: [Entity] = []
    /// Ones it probably refers to. Enough to look for, not enough to narrow
    /// a search to: with a question per entity, a small error rate per
    /// question is a wrong name on most turns.
    var maybeNamed: [Entity] = []
    /// Entities whose names appear in the text but are not what it means —
    /// "what will I do today" does not involve a colleague called Will.
    var notMeant: Set<String> = []
    /// The recordings the question is about: empty for the whole history, nil
    /// when that could not be told.
    var sessionIDs: [UUID]?
}

/// Builds the one request that reads a question, and turns its answers back
/// into a `QuestionReading`. One call: the state is read once and every
/// question is judged against it side by side.
enum QuestionReader {
    struct Session: Equatable {
        let id: UUID
        let title: String
        let date: String
        let kind: String
    }

    struct Inputs {
        var question: String
        /// Oldest first. Only the tail is sent: it is there to resolve "and
        /// the enterprise one?", not to be read.
        var history: [(isUser: Bool, text: String)] = []
        var today: String
        var sessions: [Session] = []
        var entities: [Entity] = []
        var agents: [String] = []
        var connectedTools: [String] = []
    }

    struct Request: JudgeRequest {
        let purpose = JudgePurpose.question
        let state: State
        let questions: [String: JudgeQuestion]
    }

    struct State: Encodable {
        struct Turn: Encodable {
            let role: String
            let text: String
        }

        struct SessionRow: Encodable {
            let title: String
            let date: String
            let kind: String
        }

        struct EntityRow: Encodable {
            let name: String
            let kind: String
        }

        let today: String
        let conversation: [Turn]
        let question: String
        let sessions: [SessionRow]
        let entities: [EntityRow]
        let agents: [String]
        let connected_tools: [String]
    }

    static let historyTurns = 6
    static let historyTurnLength = 600
    static let sessionLimit = 60
    static let entityLimit = 150
    static let questionLength = 2000
    /// What it takes for a recording nobody named to scope a search by itself.
    static let certainty = 0.9
    /// The same for a name. Measured on jev-1.13.0, 2026-09-21: a name that is
    /// meant reads 0.90–0.98 even typed by ear in Cyrillic and inflected
    /// ("лінеару"), one that is not reads 0.02–0.30 even when its letters are
    /// in the text ("what will I do"). The two bars sit in that gap.
    static let nameMeant = 0.8
    static let nameProbable = 0.6
    static let nameNotMeant = 0.4

    private static let periods: [String: String] = [
        "none": "The question names no period of time",
        "today": "Today only",
        "yesterday": "Yesterday only",
        "this_week": "The current calendar week",
        "last_week": "The previous calendar week",
        "this_month": "The current calendar month",
        "last_month": "The previous calendar month",
        "last_3_days": "Roughly the last two or three days",
        "last_7_days": "Roughly the last seven days, not a calendar week",
        "last_14_days": "Roughly the last two weeks",
        "last_30_days": "Roughly the last thirty days, not a calendar month",
        "since_last_workday": "The work done since the previous working day — what a report for today's standup, "
            + "daily or check-in covers, even though the meeting itself is today",
        "upcoming": "Days that have not happened yet: what is planned, due or coming tomorrow, next week or later",
        "other_dates": "A specific date, weekday or date range that none of the other options describes"
    ]

    static func request(for inputs: Inputs) -> Request {
        let sessions = Array(inputs.sessions.prefix(sessionLimit))
        let entities = Array(inputs.entities.prefix(entityLimit))
        var questions: [String: JudgeQuestion] = [:]
        questions["period"] = .choice(
            "Which period of time does `question` need covered? `today` is the current date. Judge what the period is a "
                + "period OF, not which date word appears. Resolve a follow-up against `conversation`.",
            options: periods
        )
        questions["own_work"] = .noul(
            "Is `question` asking about the user's own recent activity — what they did, worked on, looked at or missed?",
            yes: "A colleague would answer it by looking over the user's shoulder, including a request to sum up or report "
                + "their own work, even when it names a project or client",
            no: "It asks what was said, decided or promised in a recording, or asks for something to be done"
        )
        questions["needs_sessions"] = .noul(
            "Does answering `question` depend on what was said, decided or promised in the user's recorded sessions, "
                + "or on their own past activity?",
            yes: "The answer has to be looked up in recordings or past activity",
            no: "It is a self-contained request to do something, names one of `connected_tools` as the source of the "
                + "answer, is small talk, or asks about the app itself"
        )
        questions["about_nod"] = .noul(
            "Is `question` about Nod, the app the user is talking to — how it records, what it stores, its privacy, "
                + "settings, pricing or features?",
            yes: "It asks how the app itself works",
            no: "It asks about the user's own meetings, work, customers or anything else, even when the topic is privacy or pricing"
        )
        questions["wants_calendar"] = .noul(
            "Would the user's calendar — scheduled events, free time, who they are meeting — help answer `question`?",
            yes: "It asks about their schedule, availability or upcoming events",
            no: "It merely mentions a meeting or a call that already happened, or is about something else"
        )
        questions["wants_tasks"] = .noul(
            "Would the list of the user's open action items and commitments help answer `question`?",
            yes: "It asks what is outstanding, owed, promised, due or next for them",
            no: "It is about something else"
        )
        questions["wants_agents"] = .noul(
            "Is `question` about the scheduled agents listed in `agents` — which exist, when they run, or what one reported?",
            yes: "It asks about those agents or their reports",
            no: "It uses the word agent, brief or digest for something else, or does not mention them"
        )
        questions["wants_projects"] = .noul(
            "Is `question` asking which projects or folders the user has organised their sessions into?",
            yes: "It asks for the list of projects or folders themselves",
            no: "It asks about the content of a project, or about something else"
        )
        if !sessions.isEmpty {
            questions["targets_sessions"] = .noul(
                "Is `question` about one or a few particular recordings in `sessions`, rather than the user's whole history?",
                yes: "It points at particular recordings by title, date, topic or recency",
                no: "It is a broad question that any recording might help answer"
            )
        }
        for index in sessions.indices {
            questions[sessionKey(index)] = .noul("Is `question` specifically about the recording in `sessions[\(index)]`?")
        }
        for index in entities.indices {
            questions[entityKey(index)] = .noul(
                "Does `question` mention the \(entities[index].kind.rawValue) named in `entities[\(index)].name`? The name may be "
                    + "typed by ear in another alphabet (a Latin name in Cyrillic letters) or inflected; the same letters as an "
                    + "ordinary word do not count."
            )
        }
        // The user's own turns only. An answer quotes transcripts and can
        // carry what was on the screen, and neither is this vendor's to read.
        let turns = inputs.history.filter(\.isUser).suffix(historyTurns).map {
            State.Turn(role: "user", text: String($0.text.prefix(historyTurnLength)))
        }
        return Request(
            state: State(
                today: inputs.today,
                conversation: turns,
                question: String(inputs.question.prefix(questionLength)),
                sessions: sessions.map { State.SessionRow(title: $0.title, date: $0.date, kind: $0.kind) },
                entities: entities.map { State.EntityRow(name: $0.name, kind: $0.kind.rawValue) },
                agents: inputs.agents,
                connected_tools: inputs.connectedTools
            ),
            questions: questions
        )
    }

    static func reading(from answers: [String: JudgeAnswer], for inputs: Inputs) -> QuestionReading {
        let sessions = Array(inputs.sessions.prefix(sessionLimit))
        let entities = Array(inputs.entities.prefix(entityLimit))
        var reading = QuestionReading(
            period: answers.picked("period").flatMap(period(for:)),
            asksAboutOwnWork: answers.holds("own_work"),
            needsSessions: answers.holds("needs_sessions"),
            asksAboutNod: answers.holds("about_nod"),
            wantsCalendar: answers.holds("wants_calendar"),
            wantsTasks: answers.holds("wants_tasks"),
            wantsAgents: inputs.agents.isEmpty ? nil : answers.holds("wants_agents"),
            wantsProjects: answers.holds("wants_projects")
        )
        for index in entities.indices {
            guard let meant = answers[entityKey(index)]?.noul else { continue }
            if meant >= nameMeant {
                reading.named.append(entities[index])
            } else if meant >= nameProbable {
                reading.maybeNamed.append(entities[index])
            } else if meant < nameNotMeant {
                reading.notMeant.insert(entities[index].name)
            }
        }
        // Two entities can share a name, and one of them being meant settles it.
        reading.notMeant.subtract((reading.named + reading.maybeNamed).map(\.name))
        switch answers.holds("targets_sessions") {
        case false?:
            reading.sessionIDs = []
        case true?:
            // As sure as a name has to be: sixty questions a turn, and a wrong
            // pick is an answer from the wrong recording with no router behind it.
            let picked = sessions.indices.filter { (answers[sessionKey($0)]?.noul ?? 0) >= certainty }.map { sessions[$0].id }
            reading.sessionIDs = picked.isEmpty ? nil : picked
        case nil:
            break
        }
        return reading
    }

    /// Dates are values, and this model picks from what it is shown rather
    /// than writing one — so a specific date stays the query-prep model's job.
    private static func period(for choice: String) -> String? {
        switch choice {
        case "none": ""
        case "other_dates": nil
        default: choice
        }
    }

    private static func sessionKey(_ index: Int) -> String {
        "session_\(index)"
    }

    private static func entityKey(_ index: Int) -> String {
        "entity_\(index)"
    }
}

extension LLMProxyClient.PreparedQuery {
    /// This reading with every confident judgment laid over it.
    ///
    /// Only ever towards reading more. Query prep is told to say "needs the
    /// sessions" and "about their own work" whenever it is in doubt, because
    /// skipping retrieval wrongly is an answer from nothing; a typed no, however
    /// sure, does not get to undo that.
    func overlaid(with reading: QuestionReading?) -> Self {
        guard let reading else { return self }
        var merged = self
        // Two readings that disagree are settled in favour of the one that
        // reaches further back. A window too wide costs prompt room; one too
        // narrow is the Monday report written from Monday morning.
        if let named = reading.period {
            let theirs = SessionTimeRange.resolve(period: named)?.start
            let ours = SessionTimeRange.resolve(period: period)?.start
            if ours == nil || (theirs ?? .distantFuture) < (ours ?? .distantPast) { merged.period = named }
        }
        if reading.asksAboutOwnWork == true { merged.aboutScreen = true }
        if reading.needsSessions == true { merged.needsSessions = true }
        var known = Set((merged.names + merged.screenTerms).map { $0.lowercased() })
        merged.names += reading.named.map(\.name).filter { known.insert($0.lowercased()).inserted }
        merged.screenTerms += reading.maybeNamed.map(\.name).filter { known.insert($0.lowercased()).inserted }
        merged.sessionIDs = reading.sessionIDs
        merged.notMeant = reading.notMeant
        return merged
    }
}
