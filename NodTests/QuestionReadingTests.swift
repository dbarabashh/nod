import XCTest
@testable import Nod

final class QuestionReadingTests: XCTestCase {
    private let acme = Entity(id: UUID(), userID: UUID(), kind: .project, name: "Acme")
    private let will = Entity(id: UUID(), userID: UUID(), kind: .person, name: "Will")
    private let sync = QuestionReader.Session(id: UUID(), title: "Acme sync", date: "Fri 18 Sep", kind: "meeting")
    private let retro = QuestionReader.Session(id: UUID(), title: "Retro", date: "Thu 17 Sep", kind: "meeting")

    private var inputs: QuestionReader.Inputs {
        QuestionReader.Inputs(
            question: "what will I do today on Acme",
            today: "Monday, 2026-09-21",
            sessions: [sync, retro],
            entities: [acme, will],
            agents: ["Morning brief"]
        )
    }

    private func noul(_ value: Double) -> JudgeAnswer {
        JudgeAnswer(noul: value)
    }

    func testEveryEntityAndSessionGetsItsOwnQuestion() {
        let request = QuestionReader.request(for: inputs)

        XCTAssertNotNil(request.questions["entity_0"])
        XCTAssertNotNil(request.questions["entity_1"])
        XCTAssertNotNil(request.questions["session_1"])
        XCTAssertNotNil(request.questions["targets_sessions"])
        XCTAssertEqual(request.state.entities.map(\.name), ["Acme", "Will"])
    }

    func testWithoutSessionsNothingAsksAboutThem() {
        var bare = inputs
        bare.sessions = []

        XCTAssertNil(QuestionReader.request(for: bare).questions["targets_sessions"])
    }

    func testOnlyTheTailOfAConversationIsSent() {
        var long = inputs
        long.history = (0 ..< 20).map { (isUser: $0.isMultiple(of: 2), text: String(repeating: "x", count: 5000)) }
        let state = QuestionReader.request(for: long).state

        XCTAssertEqual(state.conversation.count, QuestionReader.historyTurns)
        XCTAssertEqual(state.conversation.first?.text.count, QuestionReader.historyTurnLength)
        XCTAssertTrue(state.conversation.allSatisfy { $0.role == "user" }, "an answer quotes transcripts; it is not sent")
    }

    func testAnAnswerBetweenYesAndNoDecidesNothing() {
        let reading = QuestionReader.reading(
            from: ["own_work": noul(0.55), "wants_calendar": noul(0.9), "wants_tasks": noul(0.1), "wants_projects": noul(0.25)],
            for: inputs
        )

        XCTAssertNil(reading.asksAboutOwnWork)
        XCTAssertEqual(reading.wantsCalendar, true)
        XCTAssertEqual(reading.wantsTasks, false)
        XCTAssertNil(reading.wantsProjects, "taking a block away needs more certainty than adding one")
        XCTAssertNil(reading.needsSessions, "an answer that never came is not a no")
    }

    func testAFlatChoiceDecidesNothingAndNoneMeansNoPeriod() {
        let flat = ["period": JudgeAnswer(choice: "today", confidence: 0.3)]
        let none = ["period": JudgeAnswer(choice: "none", confidence: 0.9)]
        let dates = ["period": JudgeAnswer(choice: "other_dates", confidence: 0.9)]
        let standup = ["period": JudgeAnswer(choice: "since_last_workday", confidence: 0.8)]

        XCTAssertNil(QuestionReader.reading(from: flat, for: inputs).period)
        XCTAssertEqual(QuestionReader.reading(from: none, for: inputs).period, "")
        XCTAssertNil(QuestionReader.reading(from: dates, for: inputs).period, "a date is a value; query prep writes it")
        XCTAssertEqual(QuestionReader.reading(from: standup, for: inputs).period, SessionTimeRange.sinceLastWorkdayKey)
    }

    func testANameThatIsOnlyAWordIsSetAside() {
        let reading = QuestionReader.reading(from: ["entity_0": noul(0.95), "entity_1": noul(0.04)], for: inputs)

        XCTAssertEqual(reading.named, [acme])
        XCTAssertEqual(reading.notMeant, ["Will"])
    }

    func testAProbableNameIsLookedForButDoesNotScopeTheSearch() {
        let reading = QuestionReader.reading(from: ["entity_0": noul(0.7), "entity_1": noul(0.5)], for: inputs)
        let merged = LLMProxyClient.PreparedQuery(standalone: "q").overlaid(with: reading)

        XCTAssertTrue(reading.named.isEmpty)
        XCTAssertEqual(reading.maybeNamed, [acme])
        XCTAssertTrue(merged.names.isEmpty)
        XCTAssertEqual(merged.screenTerms, ["Acme"])
    }

    func testSessionsAreRoutedOnlyWhenTheQuestionPointsAtSome() {
        let broad = QuestionReader.reading(from: ["targets_sessions": noul(0.05), "session_0": noul(0.9)], for: inputs)
        let pointed = QuestionReader.reading(
            from: ["targets_sessions": noul(0.9), "session_0": noul(0.9), "session_1": noul(0.2)],
            for: inputs
        )
        let pointedAtNothing = QuestionReader.reading(from: ["targets_sessions": noul(0.9)], for: inputs)

        XCTAssertEqual(broad.sessionIDs, [])
        XCTAssertEqual(pointed.sessionIDs, [sync.id])
        XCTAssertNil(pointedAtNothing.sessionIDs, "the router decides what the reading could not")
    }

    func testAgentsAreNotAskedAboutWhenThereAreNone() {
        var none = inputs
        none.agents = []

        XCTAssertNil(QuestionReader.reading(from: ["wants_agents": noul(0.9)], for: none).wantsAgents)
    }

    func testAReadingOverridesQueryPrepOnlyWhereItIsSure() {
        let prepared = LLMProxyClient.PreparedQuery(standalone: "q", aboutScreen: false, names: ["acme"], period: "today")
        var reading = QuestionReading(period: SessionTimeRange.sinceLastWorkdayKey, asksAboutOwnWork: true)
        reading.named = [acme, will]
        let merged = prepared.overlaid(with: reading)

        XCTAssertEqual(merged.period, SessionTimeRange.sinceLastWorkdayKey)
        XCTAssertTrue(merged.aboutScreen)
        XCTAssertTrue(merged.needsSessions, "unsure leaves query prep's answer standing")
        XCTAssertEqual(merged.names, ["acme", "Will"])
        XCTAssertEqual(prepared.overlaid(with: nil).period, "today")
    }

    func testAReadingNeverTalksRetrievalOutOfWhatQueryPrepFound() {
        let prepared = LLMProxyClient.PreparedQuery(
            standalone: "q",
            aboutScreen: true,
            needsSessions: true,
            period: "2026-09-10..2026-09-12"
        )
        let sureOfNothing = QuestionReading(period: "", asksAboutOwnWork: false, needsSessions: false)
        let merged = prepared.overlaid(with: sureOfNothing)

        XCTAssertTrue(merged.aboutScreen)
        XCTAssertTrue(merged.needsSessions)
        XCTAssertEqual(merged.period, "2026-09-10..2026-09-12", "\"no period\" does not erase dates query prep wrote")
        XCTAssertEqual(LLMProxyClient.PreparedQuery(standalone: "q", period: "whenever").overlaid(with: sureOfNothing).period, "")
    }

    func testOfTwoPeriodsTheOneReachingFurtherBackWins() {
        let narrow = QuestionReading(period: "today")
        let wide = QuestionReading(period: "last_month")

        XCTAssertEqual(LLMProxyClient.PreparedQuery(standalone: "q", period: "last_week").overlaid(with: narrow).period, "last_week")
        XCTAssertEqual(LLMProxyClient.PreparedQuery(standalone: "q", period: "last_week").overlaid(with: wide).period, "last_month")
    }

    func testQuestionsEncodeInTheWireShape() throws {
        let question = JudgeQuestion.noul("Is it?", yes: "It is", no: "It is not")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(question)) as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "noul")
        XCTAssertEqual((object?["criteria"] as? [String: String])?["true"], "It is")
    }
}

/// Runs the real suite against the real model, on the questions that started
/// all this. Skipped unless a key is supplied, which only ever happens by
/// hand: `TEST_RUNNER_TYPESAFE_API_KEY=… xcodebuild test -only-testing:NodTests/QuestionReadingLiveTests`.
final class QuestionReadingLiveTests: XCTestCase {
    private struct Reply: Decodable {
        let answers: [String: JudgeAnswer]
    }

    private struct Body: Encodable {
        let state: QuestionReader.State
        let model: String
        let questions: [String: JudgeQuestion]
    }

    private static let firstNames = ["Anna", "Leo", "Marta", "Oleh", "Sofia", "Ivan", "Nina", "Pavlo", "Ira", "Taras"]
    private static let surnames = ["Kovalenko", "Schmidt", "Rossi", "Tanaka", "Novak", "Silva", "Bondar", "Weber", "Costa", "Melnyk"]
    private static let products = ["Atlas", "Beacon", "Harbor", "Lumen", "Orbit", "Quarry", "Summit", "Tundra", "Vertex", "Willow"]

    private func read(_ question: String, entities: Int = 0, sessions: Int = 0) async throws -> QuestionReading {
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("no TYPESAFE_API_KEY")
        }
        let inputs = QuestionReader.Inputs(
            question: question,
            today: "Monday, 2026-09-21",
            sessions: [
                QuestionReader.Session(id: UUID(), title: "Acme analytics sync", date: "Thu 17 Sep", kind: "meeting"),
                QuestionReader.Session(id: UUID(), title: "Router installation call", date: "Fri 18 Sep", kind: "meeting")
            ] + (0 ..< max(0, sessions - 2)).map {
                QuestionReader.Session(id: UUID(), title: "\(Self.products[$0 % 10]) weekly \($0)", date: "Mon 7 Sep", kind: "meeting")
            },
            entities: [
                Entity(id: UUID(), userID: UUID(), kind: .project, name: "CourtCorrect"),
                Entity(id: UUID(), userID: UUID(), kind: .person, name: "Will")
            ] + (0 ..< max(0, entities - 2)).map { index in
                let person = index.isMultiple(of: 2)
                let name = person
                    ? "\(Self.firstNames[index % 10]) \(Self.surnames[(index / 10) % 10])"
                    : "\(Self.products[index % 10]) \(index)"
                return Entity(id: UUID(), userID: UUID(), kind: person ? .person : .project, name: name)
            },
            agents: ["What's on me today?"]
        )
        let built = QuestionReader.request(for: inputs)
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.typesafe.ai/v1/systemone")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(state: built.state, model: "jev-1.13.0", questions: built.questions))
        let (data, _) = try await URLSession.shared.data(for: request)
        return try QuestionReader.reading(from: JSONDecoder().decode(Reply.self, from: data).answers, for: inputs)
    }

    func testTheStandupReportInUkrainian() async throws {
        let reading = try await read(
            "збери всі мої роботи по корткоррект і напиши репорт на сьогоднішній дейлік, що я робив та які плани далі"
        )

        XCTAssertEqual(reading.period, SessionTimeRange.sinceLastWorkdayKey)
        XCTAssertEqual(reading.asksAboutOwnWork, true)
        XCTAssertEqual(reading.named.map(\.name), ["CourtCorrect"])
    }

    func testAMeetingMentionedIsNotACalendarQuestion() async throws {
        let reading = try await read("What did we decide in the pricing meeting?")

        XCTAssertNotEqual(reading.wantsCalendar, true)
        XCTAssertNotEqual(reading.asksAboutOwnWork, true)
    }

    func testTheAgentsOwnQuestionWantsTheCalendarAndTasks() async throws {
        let reading = try await read("What's on me today?")

        XCTAssertEqual(reading.wantsCalendar, true)
        XCTAssertNotEqual(reading.wantsTasks, false)
    }

    func testAnOrdinaryWordIsNotAColleague() async throws {
        let reading = try await read("what will I do tomorrow?")

        XCTAssertFalse(reading.named.contains { $0.name == "Will" })
        XCTAssertTrue(reading.notMeant.contains("Will"), "typed, and still not who the question is about")
        XCTAssertEqual(reading.period, SessionTimeRange.upcoming)
    }

    /// A question per entity means a small error per question is a wrong name
    /// on most turns, and the model's accuracy moves as the state grows.
    func testAQuestionNamingNobodyNamesNobodyAtFullScale() async throws {
        for question in ["що ми вирішили щодо ціноутворення?", "what did we decide about pricing?"] {
            let reading = try await read(question, entities: 150, sessions: 60)

            XCTAssertTrue(reading.named.isEmpty, "\(question): \(reading.named.map(\.name))")
            XCTAssertLessThanOrEqual(reading.maybeNamed.count, 1, "\(question): \(reading.maybeNamed.map(\.name))")
        }
    }

    /// The gate's wrong no is invisible, so it is measured where it is likeliest:
    /// a Ukrainian room against notes written in either language.
    func testTheRecallGateKeepsWhatAUkrainianRoomIsStandingOn() async throws {
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("no TYPESAFE_API_KEY")
        }
        let window = """
        [Them] Добре, а що з експортом для аналітики? Ми ж обіцяли клієнту до кінця місяця.
        [Me] Так, я казав що надішлю їм CSV-експорт у п'ятницю, але ще не встиг.
        [Them] Тоді давай зафіксуємо новий термін.
        """
        let candidates = [
            "Send the analytics CSV export to the client by Friday",
            "Надіслати клієнту CSV-експорт аналітики",
            "Book a dentist appointment",
            "Renew the office lease before March"
        ]
        let built = RecallGate.request(window: window, candidates: candidates)
        var request = try URLRequest(url: XCTUnwrap(URL(string: "https://api.typesafe.ai/v1/systemone")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GateBody(state: built.state, model: "jev-1.13.0", questions: built.questions))
        let (data, _) = try await URLSession.shared.data(for: request)
        let kept = try RecallGate.kept(candidates.count, given: JSONDecoder().decode(Reply.self, from: data).answers)

        XCTAssertTrue(kept.contains(0) && kept.contains(1), "kept \(kept)")
    }

    private struct GateBody: Encodable {
        let state: RecallGate.Request.State
        let model: String
        let questions: [String: JudgeQuestion]
    }

    func testOtherLanguagesReadTheSame() async throws {
        let german = try await read("Was steht heute in meinem Kalender?")
        let spanish = try await read("¿Qué tengo pendiente?")

        XCTAssertEqual(german.wantsCalendar, true)
        XCTAssertEqual(spanish.wantsTasks, true)
    }
}
