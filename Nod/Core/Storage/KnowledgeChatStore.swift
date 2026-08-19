import Combine
import Foundation

/// The "Ask Nod" conversation — one question against everything the user has
/// recorded. Owns the whole pipeline (query prep → routing → retrieval →
/// grounded answer) so more than one surface can hold the same thread: the
/// Library's chat dock and the launcher panel are two windows onto this store,
/// not two implementations of it.
///
/// Threads are persisted through `KnowledgeThreadStore` — `chat_messages` is
/// keyed to one meeting, so these live in their own tables and can be reopened
/// from the Ask Nod list.
@MainActor
final class KnowledgeChatStore: ObservableObject {
    /// A session reference — either a source an answer drew on or a session the
    /// user pinned via @-mention. Both are just an id + display title.
    struct SessionRef: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        /// Set when the source is an app the answer read off the screen rather
        /// than a session. It rides in the same `sources` jsonb column, so a
        /// reopened thread shows the same chips without a schema change; rows
        /// written before this existed decode with nil.
        var bundleID: String?

        var isApp: Bool {
            bundleID != nil
        }
    }

    /// A passage the answer was built on: the words from the meeting, plus
    /// where they came from. The answer is a synthesis, so the evidence is what
    /// makes it checkable — and each one opens its session.
    struct Excerpt: Identifiable, Equatable {
        let id = UUID()
        let meetingID: UUID
        let title: String
        let date: String
        let text: String
        /// Retrieval score, used to pick the one passage worth showing per
        /// session. Zero for a recap standing in for a passage.
        var similarity: Double = 0
    }

    enum MessageRole { case user, assistant }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: MessageRole
        /// Mutable so a streamed answer grows in place. Replacing the whole
        /// value per token minted a new `id`, which tore down and rebuilt the
        /// bubble — re-parsing the entire answer as markdown — on every delta.
        var content: String
        var sources: [SessionRef] = []
        var mentions: [SessionRef] = []
        var evidence: [Excerpt] = []
        /// What the turn did on the way to this answer. Empty for an answer
        /// that came straight from the recordings.
        var steps: [ChatTurnStep] = []
    }

    /// Projects the next question is scoped to. Held here rather than in the
    /// chat view because it is now set from outside it — "Ask about Capable"
    /// opens the chat already narrowed, which is what makes a project a scope
    /// over memory instead of a filter on a list.
    /// Which projects the next question is narrowed to.
    ///
    /// Derived from the tokens in the composer rather than set directly: the
    /// scope pill that used to own this wrote the same set with a different
    /// lifetime, so deleting "@Capable" from the sentence left the question
    /// still scoped to Capable with nothing on screen saying so.
    @Published var scopeLabelIDs: Set<UUID> = []
    /// A question seeded from elsewhere — "Ask about this project" hands the
    /// composer its opening token rather than a hidden filter.
    @Published var pendingDraft: String?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isSending = false
    /// True from the first token until the answer completes — the UI shows the
    /// text growing instead of a spinner.
    @Published private(set) var isStreaming = false
    /// Narration for the wait: the lines the current stage may show, in order.
    /// `ThinkingIndicator` walks them — the store says what is happening, the
    /// view paces it.
    @Published private(set) var thinkingScript: [String] = []
    /// Why the last turn produced no answer, and what to offer for it. Typed
    /// rather than a string so the row under the thread can carry the right
    /// button — see `ChatFailure`.
    @Published private(set) var failure: ChatFailure?
    /// Answers the person stopped part-way. Held here rather than on the
    /// `Message` because the marker is about this session's act of stopping,
    /// not about the text — a reopened thread shows a short answer, which is
    /// what it is, with no schema change to say so.
    @Published private(set) var stoppedMessageIDs: Set<Message.ID> = []
    /// Turns that are on screen but not in the thread. `persist` is
    /// best-effort by design, and a turn the user can read but that will be
    /// gone tomorrow has to say so.
    @Published private(set) var unsavedMessageIDs: Set<Message.ID> = []
    /// Asking before anything leaves Nod, and the running that follows. Shared
    /// with the per-session chat, which reaches the same products and owes the
    /// same question.
    let toolGate = ChatToolGate()

    /// The tool calls the model wants to make, waiting on the user. Nothing
    /// leaves Nod while this is set.
    var pendingApproval: ChatToolGate.Pending? {
        toolGate.pending
    }

    /// Which product the chat is talking to right now, so the loader can say so.
    var callingProvider: IntegrationProvider? {
        toolGate.callingProvider
    }

    private let integrations: IntegrationService?
    /// The visible half of the tool exchange: what to show under the answer once it
    /// lands. Cleared with them, at the start of every question.
    private var turnSteps: [ChatTurnStep] = []
    /// The tools offered this question. Built once so the decision, the request
    /// and the match in `runTools` can't be given different catalogues — and so
    /// the cached prompt prefix sees the same bytes every round.
    private var turnTools: [ChatTool] = []

    private let llm: LLMProxyClient
    private let knowledge: KnowledgeStore
    /// Ambient screen context, when the user has switched it on. Optional so
    /// every existing construction site (and every preview) keeps working, and
    /// so a nil here degrades to transcript-only grounding rather than failing.
    private let screenContext: ScreenContextService?
    private let calendar: CalendarService?
    private let organizations: OrganizationService?
    private let meetings: MeetingStore
    private let labels: LabelStore
    private let profile: ProfileStore
    private let language: LanguagePreference
    private let entities: EntityStore
    private let actionItems: ActionItemStore
    private let threads: KnowledgeThreadStore
    private let feedback: RetrievalFeedbackStore
    /// The turn in flight, so `cancel()` can stop it. Unstructured on purpose:
    /// an unstructured task does not inherit the caller's cancellation, so the
    /// only thing that can stop a question is somebody asking for it to stop.
    private var inFlight: Task<Void, Never>?

    /// The saved thread these messages belong to. Nil until the first question
    /// creates one — an empty thread in the list would be noise.
    @Published private(set) var threadID: UUID?
    /// People per session, resolved once per session per app run — the same
    /// handful of sessions come back across a conversation's turns.
    private var peopleCache: [UUID: [String]] = [:]
    /// Projects per session, filled by the same lookup as `peopleCache` and
    /// read only to seed the screen crossing.
    private var projectCache: [UUID: [String]] = [:]

    /// Cached for the app run: entities are people and projects, not chunks —
    /// a handful of rows that don't change between questions.
    private var entityNames: [(String, UUID)] = []
    private var entityCacheStamp = -1

    /// The label the model reads. A bare "16 Jul" can't answer "what happened
    /// on Friday?" — it needs the weekday and how long ago that was.
    private static let groundingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()

    private func groundingLabel(for meeting: Meeting, now: Date = Date()) -> String {
        let title = meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
        let when = Self.groundingDateFormatter.string(from: meeting.startedAt)
        let age = switch PromptLibrary.daysBack(to: meeting.startedAt, from: now) {
        case ..<1: "today"
        case 1: "yesterday"
        case let days: "\(days) days ago"
        }
        var label = "\(title) — \(when) (\(age))"
        // Whose microphone this was. This prompt mixes the user's own sessions
        // with ones colleagues shared, so ownership cannot be stated once at
        // the top the way the per-session chat states it — it has to travel
        // with each session, and `PromptLibrary.sharedSessionRule` is the half
        // that tells the model to read it here. Nil for your own sessions, so
        // the common case reads exactly as it did.
        if let host = organizations?.nameOfOwner(meeting.userID) {
            label += " — " + PromptLibrary.sharedSessionLabelNote(host: host)
        }
        // "Mentions", not "people": these names come from entity extraction over
        // what was SAID, and the transcript records no speaker identity at all
        // ([Me]/[Them]). Labelling them as the session's people made the model
        // state who attended — naming two colleagues who were only talked about,
        // and omitting the actual counterpart, who was never named aloud.
        if let people = peopleCache[meeting.id], !people.isEmpty {
            label += " — mentions: \(people.joined(separator: ", "))"
        }
        return label
    }

    /// Resolves who each retrieved session involves and what it is about,
    /// concurrently and only for the sessions actually being grounded on.
    /// People label the grounding; projects seed the screen crossing.
    private func loadPeople(for ids: [UUID]) async {
        let missing = Array(Set(ids).filter { peopleCache[$0] == nil })
        guard !missing.isEmpty else { return }
        // One batched query rather than a fan-out: `entities(forMeeting:)` is
        // itself two round trips, so eight sessions used to mean sixteen
        // requests on the critical path before grounding could be assembled.
        let resolved = await entities.names(forMeetings: missing)
        for id in missing {
            peopleCache[id] = resolved.people[id] ?? []
            projectCache[id] = resolved.projects[id] ?? []
        }
    }

    init(
        llm: LLMProxyClient,
        knowledge: KnowledgeStore,
        meetings: MeetingStore,
        labels: LabelStore,
        profile: ProfileStore,
        language: LanguagePreference,
        entities: EntityStore,
        actionItems: ActionItemStore,
        threads: KnowledgeThreadStore,
        feedback: RetrievalFeedbackStore,
        integrations: IntegrationService? = nil,
        screenContext: ScreenContextService? = nil,
        calendar: CalendarService? = nil,
        organizations: OrganizationService? = nil
    ) {
        self.integrations = integrations
        self.llm = llm
        self.knowledge = knowledge
        self.meetings = meetings
        self.labels = labels
        self.profile = profile
        self.language = language
        self.entities = entities
        self.actionItems = actionItems
        self.threads = threads
        self.feedback = feedback
        self.screenContext = screenContext
        self.calendar = calendar
        self.organizations = organizations
        // The gate holds state this store publishes as its own, and a nested
        // object's changes don't reach a view observing the owner.
        gateChanges = toolGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var gateChanges: AnyCancellable?

    /// The user opened a session from an answer's sources. Attributed to the
    /// question that produced them, which is the last thing they asked.
    func noteOpenedSource(meetingID: UUID, rank: Int, in answerID: Message.ID) {
        // The question that produced these sources is the user turn before that
        // answer — not the newest one. Clicking a source under an older answer
        // used to be logged against whatever was asked last, teaching a future
        // reranker the wrong pairing.
        guard let answerIndex = messages.firstIndex(where: { $0.id == answerID }),
              let question = messages[..<answerIndex].last(where: { $0.role == .user })?.content
        else { return }
        feedback.logOpened(meetingID: meetingID, question: question, rank: rank)
    }

    // MARK: - Threads

    /// Starts a fresh conversation. The thread row is created lazily on the
    /// first question, so opening "New chat" and walking away leaves nothing
    /// behind.
    func startNewThread() {
        // Already in one: the sidebar's Ask row starts a chat every time it is
        // clicked, and clicking it while looking at an empty one would throw
        // away the draft being typed into it for no gain.
        guard threadID != nil || !messages.isEmpty else { return }
        cancel()
        messages = []
        threadID = nil
        thinkingScript = []
        clearTurnMarkers()
    }

    /// Reopens a saved conversation, with the sources and passages its answers
    /// were built on.
    func open(threadID: UUID) async {
        guard self.threadID != threadID else { return }
        cancel()
        self.threadID = threadID
        thinkingScript = []
        clearTurnMarkers()
        messages = await threads.messages(in: threadID).map { stored in
            Message(
                role: stored.role == "user" ? .user : .assistant,
                content: stored.content,
                sources: stored.sources,
                evidence: stored.evidence.map {
                    Excerpt(meetingID: $0.meetingID, title: $0.title, date: $0.date, text: $0.text)
                }
            )
        }
    }

    private func persist(_ message: Message, into existingThread: UUID? = nil) async {
        let threadID: UUID
        if let existing = existingThread ?? self.threadID {
            threadID = existing
        } else {
            // Named after the question that started it — the cheapest title
            // that's always exactly what was asked.
            guard let created = await threads.create(title: message.content) else {
                unsavedMessageIDs.insert(message.id)
                return
            }
            threadID = created.id
            self.threadID = created.id
        }
        let saved = await threads.append(
            threadID: threadID,
            id: message.id,
            role: message.role == .user ? "user" : "assistant",
            content: message.content,
            sources: message.sources,
            evidence: message.evidence.map {
                .init(meetingID: $0.meetingID, title: $0.title, date: $0.date, text: $0.text)
            }
        )
        // Best-effort persistence used to be silent, which meant a turn the
        // user could read and a turn that would still be there tomorrow looked
        // identical. It now says which one it is.
        if saved {
            unsavedMessageIDs.remove(message.id)
        } else {
            unsavedMessageIDs.insert(message.id)
        }
    }

    /// Re-saves a turn whose insert failed. The row carries its own id, so a
    /// retry that lands after a first attempt secretly succeeded is a
    /// duplicate-key error, not a duplicate turn.
    func retrySaving(_ id: Message.ID) async {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        await persist(message)
    }

    /// The assistant turn that arrived after `baseline` messages, if any. A
    /// surface showing only its own question (the launcher) asks with the count
    /// it opened on, so an older answer in the shared thread stays hidden.
    func answer(after baseline: Int) -> Message? {
        guard messages.count > baseline, let last = messages.last, last.role == .assistant else { return nil }
        return last
    }
}

// MARK: - Ask

extension KnowledgeChatStore {
    /// Answers `text` across the user's sessions. `pinned` are @-mentioned
    /// sessions (most specific intent, wins over everything); `scope` narrows to
    /// the union of one or more folders when no mention was made.
    ///
    /// The work runs in a task this store owns rather than the caller's, so
    /// `cancel()` has something to stop. Awaiting it here keeps every existing
    /// call site — which reads the answer once this returns — working unchanged.
    func ask(_ text: String, pinned: [SessionRef] = [], scope: [SessionLabel] = []) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claimed BEFORE the task exists. `run` starts on the next suspension,
        // and a second ask arriving in that window would otherwise pass this
        // guard and run a whole parallel pipeline on the same store.
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        failure = nil
        let task = Task { await run(text, pinned: pinned, scope: scope) }
        inFlight = task
        await task.value
        inFlight = nil
        isSending = false
        isStreaming = false
        thinkingScript = []
    }

    /// Stops the turn in flight. What has already been written stays — a
    /// stopped answer the reader was half-way through is worth more than the
    /// blank the abort would otherwise leave.
    func cancel() {
        guard inFlight != nil else { return }
        Log.ui.info("chat turn cancelled")
        // Ahead of the cancel: a turn parked on the approval card is suspended
        // on a continuation, and a cancelled task never reaches the resume.
        toolGate.cancelPending()
        inFlight?.cancel()
        inFlight = nil
    }

    /// Re-asks the last question, replacing the answer that is there.
    ///
    /// Scoped to the last turn on purpose: regenerating an older answer would
    /// orphan every turn after it, which read the answer being replaced.
    func regenerateLast() async {
        guard !isSending, let questionIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[questionIndex]
        let replaced = Array(messages[questionIndex...])
        messages.removeSubrange(questionIndex...)
        // The replaced turns leave the saved thread too — `ask` writes the
        // question again, and a thread that kept both shows it asked twice.
        // Not awaited: `ask` writes new rows with new ids, so the delete cannot
        // collide with it, and making the answer wait on a round trip that
        // changes nothing it reads is latency for nothing.
        if let thread = threadID {
            let ids = replaced.map(\.id)
            Task { await threads.deleteMessages(ids, in: thread) }
        }
        for message in replaced {
            stoppedMessageIDs.remove(message.id)
            unsavedMessageIDs.remove(message.id)
        }
        await ask(question.content, pinned: question.mentions, scope: currentScope)
    }

    /// The folders the composer's tokens currently name. Regeneration asks the
    /// same question with the same reach; reading it from the live scope rather
    /// than storing it on the turn keeps one owner for what a question sees.
    private var currentScope: [SessionLabel] {
        labels.labels.filter { scopeLabelIDs.contains($0.id) }
    }

    private func clearTurnMarkers() {
        failure = nil
        stoppedMessageIDs = []
        unsavedMessageIDs = []
    }

    private func run(_ text: String, pinned: [SessionRef], scope: [SessionLabel]) async {
        // Captured before the new turn is appended — this is the context the
        // query-prep step resolves follow-ups against.
        let priorHistory = chatHistory
        let question = Message(role: .user, content: text, mentions: pinned)
        messages.append(question)
        // Before query prep, routing and retrieval alike. A question about Nod
        // has no session to ground on, and with a tool connected it would take
        // the acting path and never reach the router — answered from whatever
        // the model believes about a Mac app it has never seen, in the one
        // conversation that decides whether somebody records anything.
        if let prepared = AboutNod.answer(to: text) {
            let answer = Message(role: .assistant, content: prepared)
            messages.append(answer)
            await persist(question)
            await persist(answer)
            return
        }
        #if DEBUG
            if DemoMode.isEnabled {
                await answerFromDemo(question: text, scope: scope)
                return
            }
        #endif
        // Saved alongside the work, not before it: nothing downstream needs the
        // row, and awaiting it here put a full eu-west round trip (three, on a
        // thread's first question) in front of every answer.
        async let saved: Void = persist(question)
        thinkingScript = ChatThinking.preparing
        toolGate.beginQuestion()
        turnSteps = []

        // Answer in the language the user typed, not the app default — the
        // retrieved excerpts (often Ukrainian) otherwise drag the reply away
        // from an English question. Resolved up front so query prep writes the
        // HyDE passage in the same language too.
        let replyLanguage = AppLanguage.detect(from: text) ?? language.current
        // A question about how Nod works is answered from facts or not at all,
        // and retrieval has nothing to say about it. Resolved once: `run`
        // builds a prompt in two places, and only one of them had this.
        let aboutNod = AboutNod.grounding(for: text)
        // HyDE + conversational rewrite: a self-contained query (drives routing
        // + entity matching) and a hypothetical transcript-style answer
        // (embedded for the vector match).
        //
        // On a follow-up this has to finish first — routing "and the enterprise
        // one?" needs the resolved question. On the FIRST turn there is no
        // pronoun to resolve, so the raw text already is the standalone query
        // and the two calls are independent: run them together and pay one
        // round trip instead of two.
        // Overlaps query prep instead of standing in front of it: the first
        // question of a run otherwise paid a Supabase round trip before any work
        // started, including for everyone with nothing connected.
        async let tools = integrations?.chatTools() ?? []
        async let roster: Void = organizations?.refreshDirectoryIfNeeded() ?? ()
        async let preparing = llm.prepareSearchQuery(
            history: priorHistory,
            query: text,
            language: replyLanguage,
            personalContext: profile.promptContext
        )

        await roster
        turnTools = await tools

        let prepared: (standalone: String, hyde: String?, aboutScreen: Bool, needsSessions: Bool)
        let routing: Routing
        if priorHistory.isEmpty {
            async let routed = route(pinned: pinned, scope: scope, standalone: text)
            (prepared, routing) = await (preparing, routed)
        } else {
            prepared = await preparing
            routing = await route(pinned: pinned, scope: scope, standalone: prepared.standalone)
        }
        // Query prep and routing are two model round trips before a single
        // token is written — the longest stretch of a turn with nothing on
        // screen, and so the one people actually stop.
        if Task.isCancelled { await saved; return }
        // A self-contained action — "file this in Linear", "put a meeting in my
        // calendar at 13:30" — cannot be answered better by anything in the
        // recordings, so retrieval is skipped whole: no vector search, no screen
        // record, and a system prompt of a couple of thousand characters instead
        // of the ~28k a grounded answer carries. It also stops the reply citing
        // sessions it never used.
        //
        // Ahead of the routing below, and that order is the point. The router's
        // own replies describe what the recordings hold — "nothing from that
        // period involves them" — which is no answer at all to a request to *do*
        // something. Asking to book a meeting today with someone the entity
        // graph knows matches both a name and a date window, so the request was
        // being answered with an empty search result instead of being carried out.
        if !prepared.needsSessions, !turnTools.isEmpty {
            Log.ui.info("chat: acting without retrieval")
            thinkingScript = ChatThinking.acting
            let system = PromptLibrary.buildKnowledgeSystem(
                excerpts: [aboutNod, teammatesBlock(), calendarBlock(for: prepared.standalone)].compactMap { $0 },
                language: replyLanguage,
                personalContext: profile.promptContext,
                connectedTools: turnTools
            )
            let history = chatHistory
            await saved
            await streamReply(ReplyContext(system: system, history: history, sources: [], evidence: []))
            return
        }

        let scope: Scope
        switch routing {
        case let .answered(reply):
            thinkingScript = []
            let answer = Message(role: .assistant, content: reply)
            messages.append(answer)
            await persist(answer)
            return
        case let .search(routed):
            scope = routed
        }

        // Said only now, with routing decided: until this line nothing is known
        // to be searchable, and claiming otherwise is what let a request to file
        // a ticket read as a search of every session the user has.
        thinkingScript = ChatThinking.searching
        // Independent of retrieval — it only needs the resolved question — so
        // it overlaps the search instead of adding a round trip after it.
        async let tasks = outstandingTasksBlock(for: prepared.standalone)
        let grounding = await gather(
            for: scope,
            query: prepared.standalone,
            embedText: prepared.hyde,
            aboutScreen: prepared.aboutScreen
        )
        if Task.isCancelled { await saved; return }
        let sources = grounding.sources
        thinkingScript = [ChatThinking.reading(
            sessions: grounding.readSessions,
            apps: sources.filter(\.isApp).count
        )]
        let taskBlock = await tasks
        // Ahead of the excerpts and the tasks alike: a question about the day
        // ahead is answered by the calendar, and a retrieval budget that trimmed
        // it would leave the model guessing from last week's transcripts.
        let ahead = [
            aboutNod,
            QuestionIntent.asksAboutSchedule(prepared.standalone) ? teammatesBlock() : nil,
            calendarBlock(for: prepared.standalone),
            taskBlock
        ].compactMap { $0 }
        let system = PromptLibrary.buildKnowledgeSystem(
            excerpts: Self.withinBudget(ahead + grounding.excerpts),
            language: replyLanguage,
            personalContext: profile.promptContext,
            observations: Self.sharingScreenBudget(
                question: grounding.observations,
                crossed: grounding.crossedObservations,
                isRecap: grounding.isRecap
            ),
            connectedTools: turnTools
        )
        let history = chatHistory
        thinkingScript = ChatThinking.writing
        // Joined before the answer is saved, so the thread exists to save into.
        await saved
        // Low temperature — cross-session answers must stay grounded in the
        // retrieved excerpts, not improvise.
        await streamReply(ReplyContext(system: system, history: history, sources: sources, evidence: grounding.evidence))
    }

    /// Appends the assistant turn and fills it in as tokens arrive, so the
    /// answer starts reading in about a second instead of appearing whole after
    /// five. Falls back to the one-shot call if the stream dies before
    /// producing anything — streamed bytes can't be replayed, so a mid-answer
    /// failure keeps what arrived rather than pretending it didn't.
    /// The half of an answer that doesn't change between tool rounds.
    private struct ReplyContext {
        let system: String
        let history: [LLMProxyClient.ChatTurn]
        let sources: [SessionRef]
        let evidence: [Excerpt]
    }

    private func streamReply(_ context: ReplyContext, round: Int = 0) async {
        let (system, history, sources, evidence) = (context.system, context.history, context.sources, context.evidence)
        // With tools on the table the first round is a decision, not a draft.
        // Later rounds have their results already and really are composing.
        if !turnTools.isEmpty {
            thinkingScript = round == 0 ? ChatThinking.deciding : ChatThinking.writing
        }
        // Both captured up front. The user can open another saved chat or start
        // a new one while this streams: the array it was appended to is then a
        // different thread's, so the turn is tracked by identity rather than by
        // position, and saved to the thread it was actually asked in.
        let thread = threadID
        // Sources are a claim about where the answer came from, so they follow
        // the answer rather than the retrieval. Once tool results are in the
        // history they are what the model actually read; the sessions the
        // vector search happened to fetch contributed nothing, and listing them
        // turns a citation into decoration.
        let citedSources = toolGate.turns.isEmpty ? sources : []
        let citedEvidence = toolGate.turns.isEmpty ? evidence : []
        var answer = Message(
            role: .assistant,
            content: "",
            sources: citedSources,
            evidence: citedEvidence,
            steps: turnSteps
        )
        var appended = false
        var streamed = ""
        var lastFlush = ContinuousClock.now
        var streamError: Error?
        var requested: [ChatToolCall] = []

        /// Writes the text into the on-screen turn, if it's still on screen.
        func show(_ text: String) {
            guard let index = messages.firstIndex(where: { $0.id == answer.id }) else { return }
            messages[index].content = text
        }

        do {
            // Caching off: this system prompt ends in excerpts retrieved for
            // *this* question, so no two calls share a prefix — the cache would
            // be written every time and read never, at 1.25× the token cost.
            for try await event in llm.streamChat(
                system: system,
                history: history + toolGate.turns,
                tools: turnTools,
                temperature: 0.2,
                cachePrompt: false
            ) {
                // Checked per event rather than per stage: this is the one
                // place a stop can land while text is arriving, and the loop
                // holds the connection open until it breaks.
                if Task.isCancelled { break }
                guard case let .delta(delta) = event else {
                    if case let .toolCalls(calls) = event { requested = calls }
                    continue
                }
                streamed += delta
                if !appended {
                    answer.content = streamed
                    messages.append(answer)
                    appended = true
                    // The first token is the moment the wait ends.
                    isStreaming = true
                    thinkingScript = []
                    lastFlush = .now
                    continue
                }
                // Publishing per delta means a body pass, a markdown re-parse
                // and a panel resize per token — 30–80 of them a second, each
                // re-parsing a longer string. 20 Hz already reads as streaming.
                guard ContinuousClock.now - lastFlush >= Self.streamFlushInterval else { continue }
                show(streamed)
                lastFlush = .now
            }
        } catch {
            streamError = error
        }

        // The model asked for tools instead of answering. Nothing has been sent
        // anywhere yet: the calls go to the user first, and only an approval
        // runs them.
        Log.ui.info("chat turn ended requested=\(requested.count) streamed=\(streamed.count) round=\(round)")
        if !requested.isEmpty, streamed.isEmpty, streamError == nil, !Task.isCancelled, round < ChatToolGate.maxRounds {
            await runTools(requested, context: context, round: round)
            return
        }

        if !streamed.isEmpty {
            show(streamed)
            answer.content = streamed
            await keep(answer, into: thread, brokenBy: streamError)
            isStreaming = false
            return
        }

        // Stopped before a word arrived: there is nothing to keep and nothing
        // went wrong, so the turn just ends. The question stays in the thread —
        // it was asked, and `regenerateLast` is how it gets asked again.
        if !Task.isCancelled {
            await answerWithoutStreaming(context, into: thread)
        }
        isStreaming = false
        thinkingScript = []
    }

    /// Saves what actually arrived, whatever ended the stream.
    ///
    /// A partial answer the user is already reading has to be saved too, or
    /// reopening the thread shows the question with no reply at all — worse
    /// than a truncated one. A stopped answer is the same case: they asked for
    /// it to end there, which is a note on the turn rather than an apology.
    private func keep(_ answer: Message, into thread: UUID?, brokenBy streamError: Error?) async {
        await persist(answer, into: thread)
        if Task.isCancelled {
            stoppedMessageIDs.insert(answer.id)
        } else if let streamError {
            Log.ui.error("KnowledgeChatStore stream broke mid-answer: \(streamError.localizedDescription)")
            failure = .cutShort(steps: turnSteps)
        }
    }

    /// Nothing arrived at all — the stream can't be replayed, so retry the
    /// one-shot call, which can.
    private func answerWithoutStreaming(_ context: ReplyContext, into thread: UUID?) async {
        Log.ui.info("KnowledgeChatStore stream produced nothing, falling back to one-shot")
        do {
            // Transient failures are already absorbed a layer down: `chat`
            // reaches the proxy through `postToProxyWithRetry`, which classifies
            // with `isTransient` and backs off with `retryDelayMillis`. Retrying
            // again here would multiply attempts, not add resilience.
            let reply = try await llm.chat(
                system: context.system,
                history: context.history + toolGate.turns,
                temperature: 0.2,
                cachePrompt: false
            )
            let oneShot = Message(
                role: .assistant,
                content: reply,
                sources: toolGate.turns.isEmpty ? context.sources : [],
                evidence: toolGate.turns.isEmpty ? context.evidence : [],
                steps: turnSteps
            )
            messages.append(oneShot)
            await persist(oneShot, into: thread)
        } catch is CancellationError {
            Log.ui.info("KnowledgeChatStore one-shot cancelled")
        } catch {
            Log.ui.error("KnowledgeChatStore.ask failed: \(error.localizedDescription)")
            // The steps ride along: a tool that ran before the answer broke is
            // the difference between "nothing happened" and "the ticket exists".
            failure = ChatFailure(error, steps: turnSteps)
        }
    }

    /// Presents the calls, waits for the answer, runs the approved ones, and
    /// goes back to the model with the results.
    private func runTools(_ calls: [ChatToolCall], context: ReplyContext, round: Int) async {
        guard let matched = ChatToolGate.match(calls, in: turnTools), let integrations else {
            Log.ui.error("KnowledgeChatStore: model asked for an unknown tool")
            failure = .unknownTool(steps: turnSteps)
            thinkingScript = []
            return
        }

        thinkingScript = []
        let outcome = await toolGate.run(
            calls,
            tools: matched.tools,
            provider: matched.provider,
            using: integrations,
            onApproved: { [weak self] in self?.thinkingScript = ChatThinking.calling(matched.provider) }
        )
        turnSteps += outcome.steps
        // A stop while the approval card was up resumes the gate as a denial;
        // going back to the model with that would spend a round answering a
        // question nobody is waiting for any more.
        guard !Task.isCancelled else {
            thinkingScript = []
            return
        }

        await streamReply(context, round: round + 1)
    }

    func approvePendingTools() {
        toolGate.approve()
    }

    func denyPendingTools() {
        toolGate.deny()
    }

    private static let streamFlushInterval: Duration = .milliseconds(50)

    #if DEBUG
        /// Demo-mode stand-in for the whole ask pipeline. Grounds on the demo
        /// transcripts exactly like the real path — `gather` reads
        /// `KnowledgeStore.search`, which serves `DemoData.knowledgeChunks`, so
        /// the evidence rows are real passages from the sample sessions — then
        /// fake-streams a canned cross-session answer instead of calling the
        /// proxy. The launcher's headline feature works on camera with no login
        /// and no network, and nothing is persisted to the thread tables.
        private func answerFromDemo(question: String, scope: [SessionLabel]) async {
            thinkingScript = ChatThinking.searching
            let demoScope: Scope = scope.isEmpty ? .all : .scoped(scopedMeetingIDs(in: scope))
            let grounding = await gather(for: demoScope, query: question, embedText: nil)
            thinkingScript = ChatThinking.writing
            await streamDemoReply(
                DemoData.knowledgeAnswer(for: question),
                sources: grounding.sources,
                evidence: grounding.evidence
            )
        }

        /// Types the canned answer out in word-sized deltas so the launcher's
        /// answer pane behaves exactly like a real stream on camera.
        private func streamDemoReply(_ text: String, sources: [SessionRef], evidence: [Excerpt]) async {
            try? await Task.sleep(nanoseconds: 450_000_000)
            let answer = Message(role: .assistant, content: "", sources: sources, evidence: evidence)
            let id = answer.id
            messages.append(answer)
            isStreaming = true
            thinkingScript = []
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            var accumulated = ""
            for (idx, word) in words.enumerated() {
                accumulated += idx == 0 ? String(word) : " \(word)"
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].content = accumulated
                }
                try? await Task.sleep(nanoseconds: 22_000_000)
            }
            isStreaming = false
        }
    #endif

    /// Grounding is billed per token on every turn, and a `.specific` route over
    /// eight sessions can hand the model eight recaps plus their excerpts. Keep
    /// whole excerpts, in retrieval order (most relevant first), until the
    /// budget is spent — truncating mid-excerpt would ground the answer on half
    /// a sentence.
    /// Skips a block that doesn't fit rather than ending the list.
    ///
    /// It used to `break`, and on a day recap that quietly cost most of the
    /// day: one fat app block filled the allowance and every app after it —
    /// already fetched, already folded — was dropped without a word. Order
    /// still decides who gets the room first; it no longer decides who gets
    /// considered at all.
    static func withinBudget(_ excerpts: [String], limit: Int = groundingBudget) -> [String] {
        var kept: [String] = []
        var used = 0
        for excerpt in excerpts where used + excerpt.count <= limit {
            kept.append(excerpt)
            used += excerpt.count
        }
        // A single excerpt longer than the whole allowance would otherwise
        // leave nothing to answer from.
        if kept.isEmpty, let first = excerpts.first {
            kept.append(String(first.prefix(limit)))
        }
        return kept
    }

    /// ~3k tokens of grounding — enough for eight excerpts or three recaps,
    /// well inside any model's window, and a predictable ceiling on spend.
    static let groundingBudget = 12_000
    /// Screen context gets its own allowance rather than competing with session
    /// excerpts: a day of captures would otherwise crowd out the transcripts on
    /// every question, and a recap needs several apps to be worth reading.
    /// A day of real work is five or six apps, and each now carries a few full
    /// windows plus a glance at the rest. At 9k — of which only 6k was
    /// reachable — two apps filled the section and the rest of the day never
    /// left the device. This is the one place where spending tokens buys the
    /// answer its specifics, so it is sized for a whole day rather than to
    /// look thrifty.
    ///
    /// It is the *recap's* allowance, not every turn's. `recentContext` returns
    /// a handful of keyword-matched windows on ordinary questions, and giving
    /// those a day's room would make a question about a ticket carry as much
    /// screen text as a question about the whole day.
    /// Sized to hold `ScreenActivityDigest.maximumApps` app blocks at full
    /// depth — `ScreenBudgetTests.testTheSectionCanHoldAFullDayOfApps` is what
    /// keeps the two files agreeing. Raising it is only affordable because the
    /// keyword-matched path below no longer shares it.
    static let screenBudget = 32_000

    /// What the keyword-matched windows get on an ordinary turn — the size the
    /// section was before a recap needed more.
    static let matchedScreenBudget = 9_000

    /// The crossing's guaranteed share of `screenBudget`.
    ///
    /// Not a matter of ordering: `withinBudget` stops at the first block that
    /// doesn't fit rather than skipping it, and a single window can run to
    /// `maximumCharacters`. Two fat question-driven blocks would therefore
    /// swallow the whole allowance and drop every crossed window — after its
    /// query and its latency had already been paid — in exactly the sessions
    /// where the screen record is richest.
    static let crossingBudget = 3_000

    /// Both halves of the screen section, each held to its own share so neither
    /// can starve the other. Their sum is `screenBudget`, so the budget applied
    /// at the call site cannot cut this further.
    ///
    /// The reservation is only made when there is something to reserve for. A
    /// recap of a period never crosses — `crossed` short-circuits on
    /// `coversAWindow`, which that path always sets — so a third of the screen
    /// allowance was being held back for a half that could not exist, on the
    /// one question where breadth is the whole answer.
    static func sharingScreenBudget(question: [String], crossed: [String], isRecap: Bool = false) -> [String] {
        // A recap is the whole period, app by app, and breadth is the answer.
        // Every other question gets the windows its keywords matched — at most
        // a handful, often stale — and paying a day's allowance for those would
        // inflate ordinary turns for nothing.
        let allowance = isRecap ? screenBudget : matchedScreenBudget
        guard !crossed.isEmpty else { return withinBudget(question, limit: allowance) }
        return withinBudget(question, limit: allowance - crossingBudget)
            + withinBudget(crossed, limit: crossingBudget)
    }

    // MARK: - Action items

    /// Open action items with their deadlines resolved to real dates — the
    /// stored phrase ("end of week") is meaningless without the day it was said
    /// on, which is exactly the mistake the pill in the UI used to make.
    private func outstandingTasksBlock(for question: String) async -> String? {
        guard QuestionIntent.asksAboutTasks(question) else { return nil }
        let open: [ActionItem]
        do {
            open = try await actionItems.openItems(limit: Self.taskLimit)
        } catch {
            Log.ui.error("KnowledgeChatStore tasks fetch failed: \(error.localizedDescription)")
            return nil
        }
        guard !open.isEmpty else { return nil }
        let byID = meetingsByID

        // A missing meeting means the list hasn't loaded yet or the session is
        // older than the 500 it holds — not that the task is stale, so the task
        // still counts. Trashed sessions are excluded by `openItems` itself.
        let lines = open.map { item -> String in
            let meeting = byID[item.meetingID]
            let source = meeting?.displayTitle(dateFormatter: Meeting.shortDateFormatter) ?? "a past session"
            let due = item.deadline.flatMap { phrase -> String? in
                guard let spokenAt = meeting?.startedAt else { return nil }
                return ActionItemDeadline.exportLabel(phrase: phrase, spokenAt: spokenAt)
            }
            // A shared meeting's action items are readable here — RLS grants
            // them along with the recording ("members read action items shared
            // directly") — and they were extracted for whoever recorded it. So
            // the source has to say whose they are, or a colleague's follow-ups
            // are read back as the user's own to-do list.
            let owner = meeting.flatMap { organizations?.nameOfOwner($0.userID) }
            let from = owner.map { "\(source) — " + PromptLibrary.sharedSessionLabelNote(host: $0) } ?? source
            return "- \(item.text)\(due.map { " (\($0))" } ?? "") [from: \(from)]"
        }
        let header = "[OPEN ACTION ITEMS — outstanding tasks from the sessions the user can see, with dates resolved]"
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// Enough to answer "what's on my plate" without turning the prompt into a
    /// task dump.
    private static let taskLimit = 25

    /// The user's own calendar as this Mac already holds it — EventKit plus
    /// whatever the connected accounts synced.
    ///
    /// In the prompt rather than behind the read tool, for the days it covers: a
    /// round trip to Google to answer "anything today" is a slower answer to a
    /// question already sitting in memory, and one that can disagree with what
    /// the notch is showing at the same moment. The tool takes over past this
    /// horizon, which the block states so the model knows where its view ends.
    ///
    /// Returns nil only when no calendar is connected at all — an empty window
    /// still emits a block, because a missing block reads to the model as "no
    /// calendar", which is how it came to tell a user with a connected account
    /// that it could not see one.
    private func calendarBlock(for question: String) -> String? {
        guard QuestionIntent.asksAboutSchedule(question), hasCalendarSource, let calendar else { return nil }
        let now = Date()
        let horizon = now.addingTimeInterval(Self.calendarHorizon)
        let span = DateInterval(start: Foundation.Calendar.current.startOfDay(for: now), end: horizon)
        let upcoming = calendar.meetings(overlapping: span).prefix(Self.calendarLimit)
        // Only promise the tool when one was actually handed over. A user whose
        // calendar comes from macOS alone has no read tool, and pointing the
        // model at one is how it ends up hedging about a calendar it can see.
        let beyond = hasCalendarReadTool
            ? " Beyond that, use the calendar tool."
            : " That is as far ahead as Nod can see."
        // The window opens at the start of today, not at `now`, so "what was my
        // day" can be answered from it. That makes past events ordinary
        // contents of this block rather than a mistake — but an event that
        // ended hours ago used to be listed identically to one tomorrow, and
        // came back as "you have one meeting this week" at nine in the evening.
        // The status is computed here because it is a comparison against the
        // clock, which is the one thing a model should never be asked to do.
        let horizonDay = Self.calendarDayFormatter.string(from: horizon)
        let header = """
        [YOUR CALENDAR — the user's own events, from the start of today through \(horizonDay).\(beyond)]
        The window starts this morning, so it contains events that have already happened.
        """
        guard !upcoming.isEmpty else {
            // Not "the user is free": a connected account whose first sync has
            // not landed yet looks exactly like an empty week from here, and
            // telling someone they have nothing on is worse than one round trip.
            let check = hasCalendarReadTool
                ? " Before telling the user they have nothing scheduled, confirm with the calendar tool."
                : ""
            return header + "\n(No events on this device for that window.\(check))"
        }
        return header + "\n" + upcoming.map { Self.calendarLine($0, now: now) }.joined(separator: "\n")
    }

    /// The colleagues this account can invite, by name.
    ///
    /// In the prompt rather than behind a lookup tool, because the matching is
    /// the hard part and a model does it better than a query: "Діма" has to
    /// reach "Dmytro Barabash", which no substring or trigram search will do.
    /// Given the roster, the model resolves the name, and asks which one when a
    /// name fits more than one person.
    ///
    /// Only for the turns that could need it — the acting path, and a scheduling
    /// question. Every other question is answered without a list of colleagues
    /// in its prefix.
    private func teammatesBlock() -> String? {
        guard let people = organizations?.directory, people.count > 1 else { return nil }
        let lines = people.prefix(Self.directoryLimit).map { person in
            "- \(person.displayName ?? person.email) <\(person.email)>"
        }
        return "[YOUR ORGANIZATION — colleagues you can invite. Match the name the user used against these; "
            + "if it fits more than one person, ask which. Never invent an address that is not listed here.]\n"
            + lines.joined(separator: "\n")
    }

    /// Enough for a company; past it the roster stops being prompt material and
    /// the model should be asking who is meant.
    private static let directoryLimit = 60

    /// Whether there is a calendar to report on. Without this an empty block
    /// would tell someone who never connected one that their week is free.
    ///
    /// `isReadable`, not `status`: the grant is only half of it. Someone who
    /// switched calendar access off in Nod still holds the macOS grant, and
    /// must not be told about a calendar they asked Nod to stop reading.
    private var hasCalendarSource: Bool {
        calendar?.isReadable == true || hasCalendarReadTool
    }

    private var hasCalendarReadTool: Bool {
        integrations?.linked.contains(.googleCalendar) == true
    }

    private static func calendarLine(_ event: CalendarOccurrence, now: Date) -> String {
        let others = event.others.map(\.display)
        let people = others.isEmpty ? "" : " (with \(others.joined(separator: ", ")))"
        let title = event.title.isEmpty ? "(no title)" : event.title
        let when = calendarDayFormatter.string(from: event.startsAt)
        let times = "\(calendarTimeFormatter.string(from: event.startsAt))–\(calendarTimeFormatter.string(from: event.endsAt))"
        return "- \(when) \(times)\(calendarStatus(of: event, now: now)) — \(title)\(people)"
    }

    /// Where an event sits relative to the clock, in the words the block's
    /// header tells the model to read. Empty for anything still ahead, which is
    /// most of the list and the case that needs no explaining.
    nonisolated static func calendarStatus(of event: CalendarOccurrence, now: Date) -> String {
        if event.endsAt <= now { return " " + PromptLibrary.endedMarker }
        if event.startsAt <= now { return " " + PromptLibrary.inProgressMarker }
        return ""
    }

    /// One week, matching what `calendar-sync` actually pulls down — promising
    /// more than the sync holds would make the block quietly wrong at the edge.
    private static let calendarHorizon: TimeInterval = 7 * 24 * 60 * 60
    private static let calendarLimit = 25

    private static let calendarDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static let calendarTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var chatHistory: [LLMProxyClient.ChatTurn] {
        messages.map {
            LLMProxyClient.ChatTurn(role: $0.role == .user ? .user : .assistant, content: $0.content)
        }
    }
}

// MARK: - Routing

extension KnowledgeChatStore {
    /// What routing decided: either the question is already answered without
    /// asking the model (an empty folder, a period with nothing in it), or
    /// there's a scope to retrieve from. Split so `gather` takes only the half
    /// it can act on, instead of carrying a case it must return empty for.
    private enum Routing {
        case answered(String)
        case search(Scope)
    }

    private enum Scope {
        case all
        case specific([UUID])
        case scoped([UUID])
    }

    private struct Grounding {
        let excerpts: [String]
        let sources: [SessionRef]
        let evidence: [Excerpt]
        /// Sessions the prompt was built from — what the wait narrates. Screen
        /// context is counted separately, through `sources`.
        var readSessions: Int = 0
        /// Screen context, kept apart from session excerpts: the two are
        /// grounded differently and the prompt says so.
        var observations: [String] = []
        /// Whether the screen half is a whole period, app by app, rather than
        /// the handful of windows a question's keywords matched. Only the
        /// first needs room for a day.
        var isRecap = false
        /// Windows reached through the sessions rather than through the
        /// question. Kept apart only until the budget is applied — the prompt
        /// sees one section.
        var crossedObservations: [String] = []
    }

    /// Screen context for this question: a per-app recap when it asks what the
    /// user was doing, keyword matches otherwise. The apps come back alongside
    /// the text so the answer can be attributed to them.
    ///
    /// `aboutScreen` is the query-prep model's read of the question, and it is
    /// the primary trigger. The phrase list beside it is a fast path for the
    /// unmistakable cases, kept so an off day from the model can't take the
    /// feature out entirely — but it is no longer what the feature rests on.
    /// Phrase matching alone missed real questions twice ("які останні новини",
    /// "що було за останні 20 хвилин"): the ways people ask what they were
    /// doing don't enumerate.
    private func observed(for query: String, aboutScreen: Bool) async -> Observed {
        guard let screenContext else { return Observed() }
        let recap = ScreenRecall.window(for: query) ?? (aboutScreen ? ScreenRecall.defaultWindow() : nil)
        if let window = recap {
            let digest = await screenContext.activity(in: window)
            let blocks = digest.apps.map { app in
                app.promptBlock(appName: AppDirectory.identity(forBundleID: app.bundleID).name)
            }
            return Observed(
                blocks: blocks,
                apps: digest.apps.map { Self.appSource(bundleID: $0.bundleID) },
                coversAWindow: true
            )
        }
        let matched = await screenContext.recentContext(matching: query)
        return Observed(blocks: matched.map(Self.labeledObservation), apps: Self.appSources(of: matched), ids: Set(matched.map(\.id)))
    }

    /// What the screen record contributed to one answer.
    private struct Observed {
        var blocks: [String] = []
        var apps: [SessionRef] = []
        /// Observations already included, so the crossing pass can't repeat one.
        var ids: Set<UUID> = []
        /// The whole period is already in `blocks`, app by app. A crossing pass
        /// can only find what is in there, so it is skipped rather than run to
        /// produce duplicates.
        var coversAWindow = false
    }

    /// The crossing: what the user had open that touches the sessions this
    /// answer is grounded on. Seeded by the projects those sessions are about,
    /// because the question's own words rarely appear in the window where the
    /// work happened — "чи зробив я те, що обіцяв" shares no vocabulary with a
    /// pull request.
    ///
    /// The blocks are appended unmarked, exactly like the question-driven ones.
    /// Retrieving an observation because it names a project is evidence that
    /// both sides are present, and nothing more; whether they actually connect
    /// is what `[CONNECT]` makes the model decide from the material itself.
    private func crossed(sessions ids: [UUID], with observed: Observed) async -> (blocks: [String], apps: [SessionRef]) {
        guard let screenContext, !observed.coversAWindow else { return ([], []) }
        let linked = await screenContext.linkedContext(
            aboutProjects: ids.map { projectCache[$0] ?? [] },
            excluding: observed.ids
        )
        // An app the question path already sourced is the same chip, and
        // `appSource` mints an id per call — so drop it before minting rather
        // than render Slack twice.
        let known = Set(observed.apps.compactMap(\.bundleID))
        return (
            linked.map(Self.labeledObservation),
            Self.appSources(of: linked.filter { !known.contains($0.sourceApp) })
        )
    }

    private static func appSources(of observations: [ScreenObservation]) -> [SessionRef] {
        var seen = Set<String>()
        return observations
            .map(\.sourceApp)
            .filter { seen.insert($0).inserted }
            .map(Self.appSource(bundleID:))
    }

    private static func appSource(bundleID: String) -> SessionRef {
        SessionRef(id: UUID(), title: AppDirectory.identity(forBundleID: bundleID).name, bundleID: bundleID)
    }

    /// An observation carries no session to open, so it is labelled with where
    /// and when it was seen — enough for the model to attribute it, and for the
    /// user to recognise it in an answer.
    private static func labeledObservation(_ observation: ScreenObservation) -> String {
        ScreenPromptBlock.single(
            source: observation.sourceTitle.isEmpty ? observation.sourceApp : observation.sourceTitle,
            when: PromptLibrary.observationStamp(observation.observedAt),
            content: observation.content
        )
    }

    private struct SessionRoute: Decodable {
        let scope: String
        let indices: [Int]?
    }

    /// Precedence: an explicit @mention is the most specific intent and wins;
    /// then an active label scope; then an explicit time window ("last week"),
    /// which a calendar answers exactly and neither embeddings nor the router
    /// can; otherwise the router decides ("the pricing one" resolves to
    /// specific rows, broad questions stay corpus-wide).
    ///
    private func route(pinned: [SessionRef], scope: [SessionLabel], standalone: String) async -> Routing {
        if !pinned.isEmpty {
            return .search(.specific(pinned.map(\.id)))
        }
        guard !scope.isEmpty else {
            let timed = timeRoute(for: standalone)
            if case .answered = timed, let timed { return timed }
            let window: [UUID]? = if case let .search(scope) = timed {
                switch scope {
                case let .specific(ids), let .scoped(ids): ids
                case .all: nil
                }
            } else {
                nil
            }
            // A named person or project is as concrete as a date, and just as
            // invisible to vector search — the transcript says [Them], not
            // "Ludwig". Both can appear at once ("what did I discuss with
            // Ludwig last week"), so they intersect rather than compete.
            if let named = await entityRoute(for: standalone, within: window) { return named }
            if let timed { return timed }
            return await routeQuery(standalone)
        }
        let ids = scopedMeetingIDs(in: scope)
        guard !ids.isEmpty else {
            let named = scope.map { "“\($0.name)”" }.joined(separator: ", ")
            return .answered(
                "No sessions are in \(named) yet. Add one from a session's detail view, then ask again."
            )
        }
        return .search(.scoped(ids))
    }

    /// Every session carrying any of the scoped labels. Sorted so the same
    /// selection produces the same retrieval cache key across turns.
    private func scopedMeetingIDs(in scope: [SessionLabel]) -> [UUID] {
        Set(scope.flatMap { labels.meetingIDs(withLabel: $0.id) })
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Sessions inside a window the question named. Nil when it named none.
    ///
    /// A short window is answered as `.specific`, which grounds on each
    /// session's recap — "what happened last week" is asking for a round-up, and
    /// a top-k similarity search would silently drop whole meetings. A long one
    /// falls back to similarity *within* the window, because 30 recaps don't fit
    /// a prompt.
    private func timeRoute(for question: String) -> Routing? {
        // "What's planned for next week?" names a window with no sessions in it
        // — the answer lives in what was said recently. Searching the future
        // returns nothing and the model then reports it has no information,
        // which is the wrong answer to a question it could answer.
        let isFuture = SessionTimeRange.mentionsFuture(in: question)
        guard let window = isFuture ? SessionTimeRange.planningLookback() : SessionTimeRange.detect(in: question) else {
            return nil
        }
        let inWindow = meetings.meetings
            .filter { window.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
        guard !inWindow.isEmpty else {
            guard !isFuture else { return nil }
            // The prompt tells the model to name the closest session rather
            // than deny the period exists — a canned denial here would have
            // made that rule unreachable in exactly the case it was written
            // for. Hand it the nearest sessions and let it say so.
            let nearest = meetings.meetings
                .sorted { abs($0.startedAt.timeIntervalSince(window.start)) < abs($1.startedAt.timeIntervalSince(window.start)) }
                .prefix(Self.nearestFallbackCount)
            guard !nearest.isEmpty else {
                return .answered("There are no sessions recorded in that period.")
            }
            return Self.searchRoute(nearest.map(\.id))
        }
        return Self.searchRoute(inWindow.map(\.id))
    }

    /// How many sessions still fit a recap-per-session round-up prompt.
    private static let roundupLimit = 8
    /// Enough context to answer "nothing that week — the closest was…" without
    /// drifting into a period the user didn't ask about.
    private static let nearestFallbackCount = 3

    /// Sessions belonging to the people or projects the question names,
    /// intersected with a time window when the question carried one.
    private func entityRoute(for question: String, within window: [UUID]?) async -> Routing? {
        // Reloaded when the corpus grows: a person first mentioned in a meeting
        // recorded since launch would otherwise stay unmatchable until the app
        // restarts — exactly the case this route exists for.
        if entityNames.isEmpty || entityCacheStamp != meetings.meetings.count {
            entityCacheStamp = meetings.meetings.count
            let entities = await entities.allEntities()
            entityNames = entities.filter { $0.kind != .topic }.map { ($0.name, $0.id) }
        }
        let names = EntityMatcher.matched(names: entityNames.map(\.0), in: question)
        guard !names.isEmpty else { return nil }
        let ids = entityNames.filter { names.contains($0.0) }.map(\.1)
        var meetingIDs = await Set(entities.meetingIDs(forEntities: ids))
        guard !meetingIDs.isEmpty else { return nil }

        if let window, !window.isEmpty {
            meetingIDs.formIntersection(window)
            // The person exists and the period exists, but they never met in it
            // — narrowing to nothing would answer from the whole corpus
            // instead, which is worse than saying so.
            guard !meetingIDs.isEmpty else {
                return .answered("Nothing from that period involves them.")
            }
        }

        let ordered = meetings.meetings.filter { meetingIDs.contains($0.id) }.map(\.id)
        guard !ordered.isEmpty else { return nil }
        return Self.searchRoute(ordered)
    }

    /// A handful of sessions are answered from their recaps; more than that has
    /// to fall back to similarity within them, because the recaps don't fit.
    private static func searchRoute(_ ids: [UUID]) -> Routing {
        .search(ids.count <= roundupLimit ? .specific(ids) : .scoped(ids))
    }

    /// Asks the model which session(s) the question targets. Falls back to a
    /// corpus-wide search on any failure or ambiguity.
    private func routeQuery(_ text: String) async -> Routing {
        // Cap the routable list so the prompt stays small; broad questions that
        // reference an older session still resolve via the "all" path.
        let routable = Array(meetings.meetings.prefix(60))
        guard !routable.isEmpty else { return .search(.all) }
        let list = routable.enumerated().map { idx, meeting in
            "\(idx) | \(Meeting.shortDateFormatter.string(from: meeting.startedAt)) | \(meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)) | \(meeting.kind.rawValue)"
        }.joined(separator: "\n")

        let (system, user) = PromptLibrary.buildSessionRouter(sessionList: list, query: text)
        do {
            let route = try await llm.completeJSON(
                system: system,
                user: user,
                as: SessionRoute.self,
                primaryModel: llm.utilityModel
            )
            guard route.scope == "specific" else { return .search(.all) }
            let ids = (route.indices ?? []).compactMap { routable.indices.contains($0) ? routable[$0].id : nil }
            return .search(ids.isEmpty ? .all : .specific(ids))
        } catch {
            Log.ui.error("KnowledgeChatStore router failed (using all): \(error.localizedDescription)")
            return .search(.all)
        }
    }
}

// MARK: - Retrieval

extension KnowledgeChatStore {
    /// Builds the grounding excerpts + sources for the routed scope. Specific
    /// sessions are answered from their recap (+ relevant transcript parts if
    /// indexed) so sources show only what the question is actually about.
    private func gather(
        for scope: Scope,
        query: String,
        embedText: String?,
        aboutScreen: Bool = false
    ) async -> Grounding {
        switch scope {
        case .all, .scoped:
            // Corpus-style search (similarity + entity boost). A label scope is
            // the same path, constrained server-side to the label's sessions.
            let scopedIDs: [UUID]? = if case let .scoped(ids) = scope { ids } else { nil }
            // Screen observations answer the half of "what was I working on"
            // that was never said out loud. Empty unless ambient context is on.
            // Its own round trip, independent of the corpus search — so it runs
            // alongside rather than after it, as in the `.specific` branch.
            async let screening = observed(for: query, aboutScreen: aboutScreen)
            let chunks = await knowledge.search(query: query, meetingIDs: scopedIDs, embedText: embedText)
            let relevant = Self.worthGrounding(chunks)
            let grounded = Array(Set(relevant.map(\.meetingID)))
            // Started before the screen leg is joined: it depends on `chunks`
            // alone, and its two round trips would otherwise queue behind a
            // full-text query they have nothing to do with.
            async let peopled: Void = loadPeople(for: grounded)
            let screen = await screening
            await peopled
            // The crossing needs the projects that lookup resolves, so it can
            // only start once the sessions are known: one text search, serial
            // after the entity read, that the answer waits on.
            let linked = await crossed(sessions: grounded, with: screen)
            let byID = meetingsByID
            return Grounding(
                excerpts: relevant.map { labeledExcerpt($0, in: byID) },
                sources: resolveSources(relevant, in: byID) + screen.apps + linked.apps,
                evidence:
                // A row we can't name can't be opened either, so it isn't shown.
                Self.strongestPerSession(relevant.compactMap { chunk in
                    byID[chunk.meetingID].map {
                        excerpt(for: $0, text: chunk.content, similarity: chunk.similarity)
                    }
                }),
                readSessions: grounded.count,
                observations: screen.blocks,
                isRecap: screen.coversAWindow,
                crossedObservations: linked.blocks
            )
        case let .specific(ids):
            // Resolve each session's static metadata up front (main-actor
            // state), then run the per-session transcript searches concurrently
            // — they're independent, so a 5-session ask shouldn't pay five
            // serial round-trips.
            // People come from EntityStore, chunks from KnowledgeStore — two
            // independent round trips that shouldn't queue behind each other.
            // Screen context belongs here too. Routing to a session says which
            // *recordings* the question is about; it says nothing about whether
            // the user was also asking what they'd been doing. Leaving it out of
            // this branch meant "шо нового?" — which the router sends to a
            // single session — could never see the screen record.
            async let screening = observed(for: query, aboutScreen: aboutScreen)
            async let people: Void = loadPeople(for: ids)
            let byID = meetingsByID
            let inScope = ids.compactMap { byID[$0] }
            let store = knowledge
            let chunksByIndex = await withTaskGroup(of: (Int, [RetrievedChunk]).self) { group in
                for (index, meeting) in inScope.enumerated() {
                    group.addTask { await (index, store.search(query: query, meetingID: meeting.id, embedText: embedText)) }
                }
                var collected = [[RetrievedChunk]](repeating: [], count: inScope.count)
                for await (index, chunks) in group {
                    collected[index] = chunks
                }
                return collected
            }

            // Joined before the labels are built — `groundingLabel` reads the
            // people cache, so building them earlier would silently drop the
            // participant names the whole lookup exists for.
            await people
            var excerpts: [String] = []
            var sources: [SessionRef] = []
            var evidence: [Excerpt] = []
            for (index, meeting) in inScope.enumerated() {
                let title = meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
                var block = "[From: \(groundingLabel(for: meeting))]\nRecap:\n\(meeting.summary.isEmpty ? "(no recap)" : meeting.summary)"
                let chunks = chunksByIndex[index]
                if !chunks.isEmpty {
                    block += "\n\nRelevant excerpts:\n" + chunks.map(\.content).joined(separator: "\n…\n")
                }
                excerpts.append(block)
                sources.append(SessionRef(id: meeting.id, title: title))
                // A session routed to explicitly is evidence in its own right,
                // so it still gets a row when nothing in its transcript matched
                // — its recap stands in for the passage.
                let best = chunks.max { $0.similarity < $1.similarity }?.content ?? meeting.summary
                let passage = Self.readable(best)
                if !passage.isEmpty {
                    evidence.append(Excerpt(
                        meetingID: meeting.id,
                        title: title,
                        date: Meeting.shortDateFormatter.string(from: meeting.startedAt),
                        text: passage,
                        similarity: chunks.map(\.similarity).max() ?? 0
                    ))
                }
            }
            let screen = await screening
            let linked = await crossed(sessions: ids, with: screen)
            return Grounding(
                excerpts: excerpts,
                sources: sources + screen.apps + linked.apps,
                evidence: evidence,
                readSessions: inScope.count,
                observations: screen.blocks,
                isRecap: screen.coversAWindow,
                crossedObservations: linked.blocks
            )
        }
    }

    private var meetingsByID: [UUID: Meeting] {
        meetings.byID
    }

    /// The chunks the answer is allowed to be built from.
    ///
    /// Retrieval always returns its top-k, so a question the corpus has nothing
    /// on ("what about the tickets?", answered from the screen) still comes back
    /// with the least-bad sessions. Feeding those to the model and then hiding
    /// them from the chips is the worst of both: the answer can quote a therapy
    /// session while the UI shows a Chrome window. The prompt and the chips read
    /// from this one list, so what the answer used is exactly what it names.
    ///
    /// Two gates, because weakness is both absolute and relative: a match near
    /// the retrieval floor (the raw cosine runs ~0.3–0.8) is noise on its own,
    /// and a match far below the best one didn't contribute next to it.
    static func worthGrounding(_ chunks: [RetrievedChunk]) -> [RetrievedChunk] {
        guard let best = chunks.map(\.similarity).max() else { return [] }
        let floor = max(relevanceFloor, best * relevanceBand)
        let kept = chunks.filter { $0.similarity >= floor }
        if kept.count < chunks.count {
            Log.ui.debug("Grounding: kept \(kept.count)/\(chunks.count) chunks above \(floor) (best \(best))")
        }
        return kept
    }

    private static let relevanceFloor: Double = 0.45
    private static let relevanceBand: Double = 0.75

    /// Distinct sessions behind the retrieved chunks, in retrieval order, so the
    /// answer can show what it drew on.
    ///
    /// Once the list has loaded, a session it doesn't hold is one the user
    /// trashed — the list is `deleted_at is null`. It used to be chipped as
    /// "A past session", which names nothing and opens nothing, so it's dropped.
    /// Before the list loads, absence means nothing at all: keep the chip and
    /// let the title fill in rather than hiding a source the answer really used.
    private func resolveSources(_ chunks: [RetrievedChunk], in byID: [UUID: Meeting]) -> [SessionRef] {
        let listed = meetings.loadState == .loaded
        var seen = Set<UUID>()
        var refs: [SessionRef] = []
        for chunk in chunks where seen.insert(chunk.meetingID).inserted {
            guard let meeting = byID[chunk.meetingID] else {
                if listed {
                    Log.ui.debug("Sources: dropping unnamed session \(chunk.meetingID)")
                    continue
                }
                refs.append(SessionRef(id: chunk.meetingID, title: "A past session"))
                continue
            }
            refs.append(SessionRef(id: chunk.meetingID, title: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)))
        }
        return refs
    }

    private func excerpt(for meeting: Meeting, text: String, similarity: Double) -> Excerpt {
        Excerpt(
            meetingID: meeting.id,
            title: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
            date: Meeting.shortDateFormatter.string(from: meeting.startedAt),
            text: Self.readable(text),
            similarity: similarity
        )
    }

    /// One passage per session — the strongest — instead of every chunk.
    /// Retrieval routinely returns several chunks from the same meeting, and a
    /// list of four identical titles is a dump, not evidence: it buries the
    /// answer and says nothing the first row didn't.
    static func strongestPerSession(_ excerpts: [Excerpt]) -> [Excerpt] {
        var best: [UUID: Excerpt] = [:]
        var order: [UUID] = []
        for excerpt in excerpts {
            if let existing = best[excerpt.meetingID] {
                if excerpt.similarity > existing.similarity { best[excerpt.meetingID] = excerpt }
            } else {
                best[excerpt.meetingID] = excerpt
                order.append(excerpt.meetingID)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// `[Me]` / `[Them]` are transcription routing tags, not speaker names. The
    /// prompt already forbids echoing them; showing them raw in the UI is the
    /// same leak.
    ///
    /// Since diarization the tag can carry a speaker — `[Them · Eric]`,
    /// `[Them · Speaker 2]` — so matching the two bare forms no longer catches
    /// it. A person's name survives (it is the answer to "who said this", which
    /// is the opposite of a leak); a cluster number does not, being the same
    /// kind of internal artefact as the tag around it.
    static func readable(_ text: String) -> String {
        text
            .split(separator: "\n")
            .map { stripRoutingTag(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let routingTag = try? NSRegularExpression(
        pattern: #"^\[(?:Me|Them)(?: · ([^\]]+))?\]:?[ \t]*"#
    )

    private static let clusterName = try? NSRegularExpression(pattern: #"^Speaker \d+$"#)

    private static func stripRoutingTag(_ line: String) -> String {
        guard let routingTag,
              let match = routingTag.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let tag = Range(match.range, in: line)
        else { return line }

        let body = String(line[tag.upperBound...])
        guard let nameRange = Range(match.range(at: 1), in: line) else { return body }
        let name = String(line[nameRange])
        let isCluster = clusterName?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        return isCluster ? body : "\(name): \(body)"
    }

    /// Prefix each excerpt with a human source label so the model can cite it.
    private func labeledExcerpt(_ chunk: RetrievedChunk, in byID: [UUID: Meeting]) -> String {
        let label = byID[chunk.meetingID].map { groundingLabel(for: $0) } ?? "a past session"
        return "[From: \(label)]\n\(chunk.content)"
    }
}
