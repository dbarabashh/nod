import Foundation

/// Answers one request out of the tools the user has connected, and carries out
/// the ones they confirm.
///
/// Two kinds of call, told apart by `ChatTool.mutating` and never by a prompt:
///
/// A **read** runs unasked, because it changes nothing and a question typed
/// mid-meeting cannot wait on a dialog. A **write** runs only through
/// `ChatToolGate` — the same gate both chats use, showing the same card with
/// the arguments on it. Nothing reaches a connected product from here without
/// somebody having read what it would do and said yes.
///
/// The follow-up call is offered the same catalogue as the first, and gets the
/// same treatment: a write there raises its own card. It was read-only at
/// first, on the reasoning that one confirmation must not license a second call
/// nobody saw — which confused "a second call" with "an *unconfirmed* second
/// call". Nothing here is unconfirmed, and the restriction made a whole class
/// of request unanswerable: "invite Vlad to that channel" spends its one
/// routing choice finding the channel's id, and could then never invite
/// anybody.
///
/// Its own type rather than more of `LiveMeetingAnalyst`, for the reason
/// `ProposalRaiser` is its own type: the analyst is about what the room said,
/// and this is about what the user connected. They fail differently, and an
/// account with no integrations should make this produce nothing at all rather
/// than make the analyst quieter.
@MainActor
struct MeetingLookup {
    let llm: LLMProxyClient
    let integrations: IntegrationService
    let language: LanguagePreference
    /// Asks before a mutating call goes out. Without one this stays read-only:
    /// a write nobody can confirm is not a write we make.
    let gate: ChatToolGate?
    /// Who is in the room, asked at the moment of the call.
    ///
    /// A dependency rather than a check the caller makes, because the caller
    /// cannot make it for the follow-up read: that one is chosen inside this
    /// type, after the caller has stopped looking. A gate at one call site is a
    /// gate a new path walks around, and this one guards a tracker's contents
    /// reaching a screen somebody may be sharing.
    let room: () -> RoomComposition
    /// Which earlier sessions to search, asked at the moment of the request —
    /// a meeting can be filed into a project while it is still running.
    let scope: () -> LookupScope
    /// Reports where a live question got to. Optional so a test can build a
    /// lookup without one, the same way `gate` is optional.
    var analytics: ProductAnalytics?

    /// One question, read once.
    ///
    /// The three calls a lookup takes — can this be served at all, which tool,
    /// how does the answer read — each used to derive the same two facts from
    /// the same sentence. Asked separately they can disagree, and both
    /// disagreements are the kind nobody sees: a question routed against one
    /// minute of the conversation and phrased against the next, or narrowed to
    /// a product that the refusal check had already judged unreachable.
    struct Request {
        /// What the person typed.
        let text: String
        /// The products the sentence names, in the order it names them. The
        /// fact the whole narrowing turns on, so it is derived once.
        let named: [IntegrationProvider]
        /// What was being said when they typed it, and what "that ticket"
        /// therefore means. Empty for a voice note, or a meeting nobody has
        /// spoken in yet.
        let room: String

        init(_ text: String, room: String = "") {
            self.text = text
            named = MentionMark.namedTools(in: text)
            self.room = room
        }
    }

    /// The tool that would serve this request, chosen but not yet run.
    ///
    /// Routing is its own step because the caller has to answer a question
    /// between choosing a tool and running it — whether this is a question for
    /// a tool at all. Routing a second time to get there would spend that model
    /// call twice.
    struct Routed {
        let tool: ChatTool
        let arguments: String

        var provider: IntegrationProvider {
            tool.provider
        }

        /// Whether this would redo a call already made. The hop exists to reach
        /// past a result, and re-running the call that produced it spends the
        /// one extra read on the same answer — which is what a model does when
        /// a call failed and it cannot tell why.
        func repeats(_ other: Routed) -> Bool {
            tool.name == other.tool.name && arguments == other.arguments
        }
    }

    func routing(for request: Request, thread: AskThread = AskThread()) async -> Routed? {
        let offered = await offeredTools(naming: request.named)
        guard !offered.isEmpty else { return nil }
        return await route(request, among: offered, thread: thread)
    }

    /// Why this request cannot be served at all, when it names products and Nod
    /// can reach none of them.
    ///
    /// Said rather than routed around. A named product is an instruction: a
    /// question written "@Linear what's the status" and answered out of Slack,
    /// or out of what the room happened to say, is not a worse answer to the
    /// same question — it is an answer to a different one, and the person has
    /// no way to tell which they got.
    ///
    /// Only when *none* of them is reachable. Naming two and having one
    /// connected is a question this can still answer.
    func objection(to request: Request) async -> LiveLookup.Refusal? {
        await integrations.refreshIfNeeded()
        guard let first = request.named.first, !request.named.contains(where: integrations.isUsable) else { return nil }
        return .unreachable(first, blockedByOrganization: integrations.blockedByOrganization.contains(first))
    }

    /// Whether this request's reads may leave at all.
    ///
    /// A write discloses nothing to the room and carries its own confirmation,
    /// so it is not asked about. Refusing one because a customer is on the call
    /// would shut the box in the meetings it gets opened in most.
    private func mayRun(_ routed: Routed) -> Bool {
        routed.tool.mutating || room().mayReadFreely
    }

    /// What either call may choose from. Read-only without a gate, because a
    /// write nobody can confirm is not a write we make.
    ///
    /// Narrowed to the products the request names, whenever it names any — the
    /// hop included, which is why this takes them rather than the caller
    /// filtering once at the top: a question aimed at one tracker must not
    /// reach past its result into a different product.
    ///
    /// The condition is "did the sentence name anything", not "did the filter
    /// find anything". Keyed on the filter's result, a naming whose tools all
    /// fell out — a product the person has connected whose only actions are
    /// writes, with no gate to confirm them — silently re-opened the whole
    /// catalogue and answered `@Linear` out of Slack, which is the thing this
    /// parameter exists to stop. Narrowing to nothing routes nothing, and the
    /// question falls back to the room's own words.
    ///
    /// This narrows the *live* lookup, which gets one routing choice and must
    /// spend it where it was pointed. The two chats read the same token as a
    /// hint the model may weigh, because they can call again.
    private func offeredTools(naming named: [IntegrationProvider]) async -> [ChatTool] {
        let all = await integrations.chatTools()
        let allowed = gate == nil ? all.filter { !$0.mutating } : all
        return named.isEmpty ? allowed : allowed.filter { named.contains($0.provider) }
    }

    /// Run a routing the caller has already accepted, and phrase what comes
    /// back together with what earlier sessions said about the same question.
    ///
    /// Both at once. A tool call and a vector search have nothing to say to
    /// each other, so running them in sequence would spend the slower one's
    /// latency twice, and this is a surface where somebody is watching a
    /// spinner.
    func answer(_ request: Request, running routed: Routed, thread: AskThread = AskThread()) async -> LiveLookup.State {
        // Memory is skipped for a write: what earlier sessions said cannot bear
        // on whether to create something, and on a refusal it is thrown away
        // unread — a billed embedding and vector search for nothing.
        async let running = run(routed)
        async let remembered = routed.tool.mutating ? [] : recall(request.text)
        let (first, memory) = await (running, remembered)

        // Both end it where they stand. Answering anyway out of memory would
        // read as if the thing had been done, or as if the room had been asked.
        if case .declined = first { return .refused(.declined) }
        if case .refusedByRoom = first { return .refused(.outsidersPresent) }
        if case let .failed(_, failure) = first, memory.isEmpty { return .failed(failure) }

        var runs = [first]
        // The hop's catalogue is offered only when there is a result to reach
        // past. It is a thousand tokens, and a hop is "I now have the id, read
        // the thing" — with nothing in hand there is no id and nothing to ask
        // for.
        let hopTools = first.report == nil ? [] : await offeredTools(naming: request.named)
        // A tool that answered and a phrasing pass that then failed is our
        // fault, not the product's. Blaming the product sends somebody to
        // reconnect an integration that is working.
        guard var written = await phrase(request, ran: runs, memory: memory, thread: thread, hopTools: hopTools) else {
            return .failed(first.failure ?? .nod(Self.couldNotPhrase))
        }

        // The one follow-up read, taken only when the model asked for it and
        // named something the catalogue actually holds. Not offered again on
        // the way back, which is what makes this a hop rather than a loop.
        if let next = written.next, let hop = await follow(next, naming: request.named), !hop.repeats(routed) {
            Log.llm.info("live: lookup hop \(routed.tool.name) → \(hop.tool.name)")
            await runs.append(run(hop))
            // Falling back to what the first pass wrote rather than failing: the
            // hop is an attempt to do better, and a hedge is still better than
            // nothing when it doesn't come off.
            if let closed = await phrase(request, ran: runs, memory: memory, thread: thread, hopTools: []) {
                written = closed
            }
        }

        report(runs.first ?? first, provider: routed.provider)

        let text = written.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // A call that failed is not a product that had nothing. Reported as
            // the second, it reads as an answer about the user's Slack rather
            // than about ours.
            if let failed = runs.compactMap(\.failure).first { return .failed(failed) }
            return .empty
        }

        // The mark follows what the answer actually used, not what was fetched,
        // and names the read it came out of — the hop, when there was one.
        let usedTool = written.usedTool ?? runs.contains { $0.report != nil }
        return .answered(
            LiveLookup.Answer(
                text: text,
                provider: usedTool ? runs.compactMap(\.report).last.map { _ in routed.provider } : nil,
                subject: Self.mark(written.subject, notNaming: runs.compactMap { $0.tool?.name } + [routed.tool.name])
            )
        )
    }

    /// What the provenance mark is allowed to say, or nothing.
    ///
    /// The field is written by the model, and it arrives as the name of the
    /// function it called — `gmail_search_messages` — as readily as an issue
    /// key or a channel. Matched against the names actually in play rather than
    /// by shape: a real Slack channel is `eng_releases`, so punctuation cannot
    /// tell the two apart.
    nonisolated static func mark(_ written: String?, notNaming toolNames: [String]) -> String? {
        guard let subject = written?.nilIfBlank else { return nil }
        guard !toolNames.contains(where: { $0.caseInsensitiveCompare(subject) == .orderedSame }) else { return nil }
        return subject
    }

    /// What the question reached, and whether the product answered it.
    ///
    /// Linking an integration and it being *useful* are different facts, and
    /// only the second one is worth anything — an account with Linear connected
    /// that never gets an answer out of it is a failure that looks identical to
    /// success in a table of connections.
    ///
    /// `empty` is kept apart from `failed` deliberately: "your tracker is quiet"
    /// and "your tracker is unreachable" send somebody to two different places.
    private func report(_ run: ToolRun, provider: IntegrationProvider) {
        let outcome: ProductAnalytics.Outcome = switch run {
        case .succeeded: .success
        case .failed: .failure
        case .declined: .declined
        case .refusedByRoom: .refused
        }
        analytics?.record(
            .lookupRouted,
            properties: .init(
                entryPoint: .notch,
                surface: .capture,
                outcome: outcome,
                provider: provider.rawValue
            )
        )
    }

    /// Said when the tools answered and we could not turn it into a sentence.
    /// Distinct from anything a provider says, because it is not about them.
    static let couldNotPhrase = "Nod couldn't put that into an answer"

    /// A follow-up call the model asked for, checked back against the same
    /// catalogue the first choice came from. The model answers with a
    /// string; a string that is not in the list it was given is not a tool,
    /// whatever it looks like.
    private func follow(_ choice: PromptLibrary.LookupChoice, naming named: [IntegrationProvider]) async -> Routed? {
        await Self.routed(choice, among: offeredTools(naming: named))
    }

    /// What a tool run came back with.
    private enum ToolRun {
        case succeeded(ChatTool, String)
        /// Reached and refused, or not reached at all. Carries the tool so the
        /// answering pass can name what failed — a report headed by a
        /// placeholder tells the model nothing it can act on.
        case failed(ChatTool, LiveLookup.Failure)
        /// The card was shown and the answer was no.
        case declined
        /// Somebody in the room is not on the invitation. Never attempted.
        case refusedByRoom

        var tool: ChatTool? {
            switch self {
            case let .succeeded(tool, _), let .failed(tool, _): tool
            case .declined, .refusedByRoom: nil
            }
        }

        /// What the answering model is shown for a call that worked.
        var report: (tool: String, body: String)? {
            if case let .succeeded(tool, result) = self { (tool.name, result) } else { nil }
        }

        /// What it is shown for a call that did not, named by the tool that
        /// was asked.
        var breakage: (tool: String, message: String)? {
            guard case let .failed(tool, failure) = self else { return nil }
            return (tool.name, failure.label)
        }

        var failure: LiveLookup.Failure? {
            if case let .failed(_, failure) = self { failure } else { nil }
        }
    }

    private func run(_ routed: Routed) async -> ToolRun {
        // Every read, not only the first: the follow-up is chosen in here, long
        // after any caller stopped looking, and what it returns lands on the
        // same possibly-shared screen.
        guard mayRun(routed) else { return .refusedByRoom }

        let call = ChatToolCall(
            id: UUID().uuidString,
            type: "function",
            function: ChatToolCall.Function(name: routed.tool.name, arguments: routed.arguments)
        )
        if routed.tool.mutating {
            guard let gate else { return .failed(routed.tool, .provider(routed.provider, nil)) }
            return await confirm(call, routed: routed, through: gate)
        }
        return await Self.settle(routed.tool, integrations.run(call, tool: routed.tool))
    }

    /// A write, put to the person before it goes anywhere.
    ///
    /// `ChatToolGate` shows the card, waits, and runs it, so the waiting is not
    /// reimplemented here and cannot drift from what the chats do. A refusal is
    /// its own outcome rather than an error: nothing went wrong, somebody said
    /// no, and the answer should say that instead of offering to retry.
    private func confirm(_ call: ChatToolCall, routed: Routed, through gate: ChatToolGate) async -> ToolRun {
        let outcome = await gate.run([call], tools: [routed.tool], provider: routed.provider, using: integrations)
        let declined = outcome.steps.first?.outcome == .declined
        // The one number that says whether the approval card protects more than
        // it interrupts. A gate nobody ever refuses is a dialog, not a gate.
        analytics?.record(
            .toolCallReviewed,
            properties: .init(
                entryPoint: .notch,
                surface: .capture,
                outcome: declined ? .declined : .granted,
                provider: routed.provider.rawValue
            )
        )
        if declined { return .declined }
        return Self.settle(routed.tool, outcome.turns.last?.content ?? "")
    }

    private static func settle(_ tool: ChatTool, _ result: String) -> ToolRun {
        if let message = IntegrationService.failure(in: result) {
            return .failed(tool, .provider(tool.provider, message))
        }
        guard !result.isEmpty else { return .failed(tool, .provider(tool.provider, nil)) }
        return .succeeded(tool, result)
    }

    /// An excerpt from an earlier session, with somewhere to put it.
    private struct Remembered {
        let text: String
    }

    /// What earlier sessions said about this.
    ///
    /// Scoped when the meeting is filed or recurs, unscoped when it is neither
    /// — see `LookupScope` for why widening is safe. The floor is the recall
    /// pass's own: below it retrieval had nothing worth paying a model to read.
    private func recall(_ request: String) async -> [Remembered] {
        let scope = scope()
        do {
            let matches = try await llm.searchKnowledge(
                query: request,
                matchCount: Self.memoryMatches,
                meetingIDs: scope.meetingIDs
            )
            .chunks
            .filter { $0.similarity >= LiveMeetingAnalyst.recallFloor }
            Log.llm.info("live: lookup memory scope=\(scope.label ?? "all") hits=\(matches.count)")
            return matches.map { Remembered(text: $0.content) }
        } catch {
            // Memory failing is not the lookup failing: a tool may still answer.
            Log.llm.error("live: lookup memory failed — \(error.localizedDescription)")
            return []
        }
    }

    /// Enough to answer from, few enough that the card's one model call stays
    /// short. The recall pass uses six to pick one; this reads all of them.
    private static let memoryMatches = 4

    private func route(_ request: Request, among tools: [ChatTool], thread: AskThread) async -> Routed? {
        let (system, user) = PromptLibrary.buildLookupRouting(
            request: request.text,
            tools: tools,
            thread: thread,
            transcript: request.room
        )
        do {
            let choice = try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.LookupChoice.self,
                primaryModel: llm.utilityModel
            )
            return Self.routed(choice, among: tools)
        } catch {
            Log.llm.error("lookup routing failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A named choice turned into something runnable, or nil. The one place a
    /// model-supplied tool name is checked against the catalogue, so the first
    /// choice and the follow-up cannot disagree about what counts as a tool.
    private static func routed(_ choice: PromptLibrary.LookupChoice, among tools: [ChatTool]) -> Routed? {
        guard let name = choice.tool,
              let tool = tools.first(where: { $0.name == name })
        else { return nil }

        // A call the schema says cannot be made. Refused here rather than sent,
        // because a provider's own complaint about it — "`query` is required" —
        // reaches the person as their Linear being unreachable, which it is
        // not. Nothing chosen is a better answer than something malformed: the
        // question falls back to the transcript, which for a follow-up like
        // "and the previous one?" is where the answer was all along.
        let given = choice.arguments?.filter { !$0.value.isEmpty } ?? [:]
        let missing = tool.parameters.required.filter { given[$0] == nil }
        guard missing.isEmpty else {
            Log.llm.info("lookup: \(tool.name) not run — missing \(missing.joined(separator: ", "))")
            return nil
        }

        guard let arguments = encode(given) else { return nil }
        return Routed(tool: tool, arguments: arguments)
    }

    private func phrase(
        _ request: Request,
        ran: [ToolRun],
        memory: [Remembered],
        thread: AskThread,
        hopTools: [ChatTool]
    ) async -> PromptLibrary.LookupAnswer? {
        let (system, user) = await PromptLibrary.buildLookupAnswer(
            request: request.text,
            results: ran.compactMap(\.report),
            failures: ran.compactMap(\.breakage),
            memory: memory.map(\.text),
            thread: thread,
            hopTools: hopTools,
            transcript: request.room,
            language: language.current
        )
        do {
            return try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.LookupAnswer.self,
                primaryModel: llm.utilityModel
            )
        } catch {
            Log.llm.error("lookup phrasing failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func encode(_ arguments: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(arguments) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
