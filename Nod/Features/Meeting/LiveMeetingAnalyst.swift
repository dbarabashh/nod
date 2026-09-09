import Combine
import Foundation

/// Listens to the meeting while it is happening and keeps a short memory of what
/// it has committed to, decided, or left open.
///
/// This is the one thing Nod does that a recorder cannot: everything else in the
/// app reads a finished recording, where the user already knows how it ended.
/// Here the meeting is still running, and a task named at 14:03 and moved to
/// Monday at 14:12 is two facts the transcript will only ever show as two
/// unconnected sentences.
///
/// Three properties are load-bearing, and each is a defence against the failure
/// mode that would kill this feature:
///
/// * **It costs almost nothing when nothing is happening.** A pass runs only
///   when enough NEW speech has landed AND enough time has passed. Silence,
///   small talk and a paused recording are free. We charge a flat rate per hour,
///   so a timer that fires regardless of what was said is a dial on our own
///   margin, not the user's.
/// * **It remembers.** Each pass is given the findings still standing, so a task
///   discussed across ten minutes stays one task, and a change of mind arrives
///   as a revision instead of a contradiction sitting next to its original.
/// * **The model proposes, this verifies.** Every finding carries a verbatim
///   quote, and one that is not literally in the window is dropped before it
///   reaches memory. It is the cheapest guard we have against the failure the
///   user would notice first — a confident task nobody agreed to.
///
/// Nothing is written to the database *by* this object. It hands its findings to
/// `mirrorFindings` when somebody is listening in, and the record itself is
/// still written once, at finalize. See `LiveFinding` for both.
@MainActor
final class LiveMeetingAnalyst: ObservableObject {
    /// Everything still standing, oldest first. Superseded findings stay in the
    /// list, flagged — a meeting that changed its mind is the interesting case,
    /// and dropping the original loses half of it.
    @Published private(set) var findings: [LiveFinding] = []

    /// The one thing worth interrupting the user with, if anything.
    ///
    /// Deliberately not "the newest finding". Most of what this hears belongs in
    /// the summary and nowhere else: a risk noted, a question left open, a
    /// decision recorded. Surfacing each of them turns the notch into a ticker,
    /// and the cost of that is not the pixels — it is that the one card that
    /// mattered arrives looking like the four that didn't.
    @Published private(set) var notice: LiveFinding?

    /// What Nod already knew and the room just made relevant. Separate from
    /// `notice` because it answers a different question — that one says "you
    /// just committed to something", this one says "you settled this in
    /// August" — and because only this one can be wrong about a session the
    /// user is not in.
    @Published private(set) var recall: LiveRecall?

    /// Every open loop raised during this meeting, kept after its card has gone.
    ///
    /// A proactive card says its piece and gets out of the way, which is right
    /// for an interruption and wrong for a record: a promise raised while
    /// somebody was mid-sentence is exactly the one they were too busy to read.
    /// Notes is where they look afterwards, so it has to still be there.
    @Published private(set) var surfacedLoops: [LiveRecall] = []

    /// Runs a typed question against the connected tools. Injected and optional
    /// for the same reason `mirrorFindings` is: an account with nothing
    /// connected has no lookups, and no test needs one.
    var meetingLookup: MeetingLookup?
    /// Asks before anything the Ask box does reaches a connected product.
    ///
    /// The same gate both chats use, rather than a second idea of what consent
    /// is — that is the whole argument in `ChatToolGate`, and a box that files
    /// tasks during a meeting is the last place to make an exception. Owned
    /// here so it dies with the meeting: an approval nobody answered is not a
    /// question the next meeting should inherit.
    let askToolGate = ChatToolGate()

    /// The meeting in progress, so a search for what was said *before* can
    /// exclude what is being said now. Set by `MeetingSession` at start.
    var currentMeetingID: UUID?
    /// Resolves a session id to "Product Sync · Aug 8". Injected rather than
    /// looked up: the analyst has no business holding the meeting list, and a
    /// recall with no readable source is one we refuse to show.
    var recallSourceLabel: ((UUID) -> String?)?
    /// The user's still-open loops, asked for at the moment of the pass.
    ///
    /// Injected and `async` rather than held: the list changes while the
    /// meeting runs, and the closure is the only thing that can make sure it
    /// has been loaded at all — a meeting can start with no window ever having
    /// been opened.
    var openLoops: (() async -> [ActionItem])?
    /// The entity edges the candidate filter walks before it falls back to
    /// counting shared words. Empty is an account whose sessions have not been
    /// through extraction, and the filter degrades to what it did before.
    var loopGraph: (() async -> LoopGraph.Index)?
    /// Where findings go so that somebody listening to this meeting sees the
    /// same Notes as the person recording it. Injected for the same reason
    /// `recallSourceLabel` is — the analyst has no business holding the meeting
    /// store — and left nil wherever there is nobody to tell, which is every
    /// test and every preview.
    ///
    /// Handed all of them rather than what just changed — see
    /// `MeetingStore.mirrorLiveFindings` for why the whole list is the point.
    var mirrorFindings: (([LiveFinding]) -> Void)?
    var recallLanguage: AppLanguage = .english
    var recallsUsed = 0
    var lastRecallAt: Date?
    private var recallExpiry: Task<Void, Never>?
    /// The recall question asked alongside the live pass. Held so `stop()`
    /// reaches it: it is started unstructured so it never blocks the pass, and
    /// unstructured means nothing else cancels it — a card landing after the
    /// meeting ended is the same bug the pass itself was just fixed for.
    private var recallPass: Task<Void, Never>?

    /// Not `private`: `LiveMeetingAnalyst+Assist.swift` (the on-demand
    /// catch-up/follow-ups/ask calls) reads both directly, from a separate
    /// file — same rationale as `windowLines` below.
    let llm: LLMProxyClient
    let store: TranscriptStore
    /// How eagerly this analyst interrupts — see `ProactivityPreference.Level`
    /// for what each step changes. A plain reference, not `@ObservedObject`:
    /// nothing here is a View, so nothing needs to re-render on a change —
    /// `tick()` just reads the current `level` each time it fires.
    private let proactivity: ProactivityPreference

    private var loop: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var lastPassAt: Date?
    private var lastNoticeAt: Date?
    private var noticeExpiry: Task<Void, Never>?
    private var analyzedLines = 0

    /// How often the trigger is checked. Not how often a pass runs — see
    /// `ProactivityPreference.Level.minNewLines` / `.minInterval`, which are
    /// what actually gate the spend.
    private static let tickInterval: TimeInterval = 15

    /// The ceiling on how much transcript one pass reads — and what a first
    /// pass, or one after a long quiet stretch, actually gets.
    /// Not `private`: `LiveMeetingAnalyst+Assist.swift`'s `ask` reads the same
    /// width.
    static let windowLines = 40

    /// How far back a pass reads *behind* the new material. Wider than the new
    /// material on purpose: a commitment is usually made a few lines after the
    /// thing it answers, and a window starting exactly at the new material
    /// keeps cutting that in half. Kept proportional rather than flat because
    /// at Maximum a pass fires on 4 new lines, and a flat 40 then re-read 36
    /// lines the previous pass had already reported on.
    static let lookbackLines = 12

    /// The window for a pass that has `newLines` of unread transcript. Capped
    /// so a burst after a long silence still gets a full read.
    nonisolated static func windowSize(forNewLines newLines: Int) -> Int {
        min(windowLines, newLines + lookbackLines)
    }

    /// How long a notice stays up before it goes away on its own. Long enough
    /// to read mid-sentence, short enough that it is gone before the user
    /// wonders whether they have to do something about it.
    static let noticeLifetime: TimeInterval = 12

    /// A soft finding's own, longer lifetime — reading it is not the whole job,
    /// deciding whether to dismiss it is, and 12 seconds is not enough to do
    /// both mid-sentence.
    private static let softNoticeLifetime: TimeInterval = 20

    /// How much of the meeting the settlement call is shown. Everything still
    /// standing, up to a bound only a pathological meeting reaches — sixty
    /// one-line findings is under a thousand tokens, and a meeting with more
    /// open than that has a worse problem than a duplicate.
    /// Not `private`: read from `LiveMeetingAnalyst+Settlement.swift`, same as
    /// `windowLines` is read from `+Assist`.
    static let settlementDepth = 60

    /// The findings handed to the model as memory. Older ones fall out — a
    /// superseded item from forty minutes ago is not what the current window is
    /// about, and the memory is the part of the prompt that grows without bound.
    private static let memoryDepth = 12

    /// Override to A/B the cadence without a rebuild, the same way the models
    /// are overridable: `defaults write com.example.nod live.minInterval 30`.
    /// Takes priority over the proactivity level so a support session can pin
    /// an exact number regardless of what the user has picked.
    private static let intervalKey = "live.minInterval"

    private var interval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: Self.intervalKey)
        return override > 0 ? override : proactivity.level.minInterval
    }

    init(llm: LLMProxyClient, store: TranscriptStore, proactivity: ProactivityPreference) {
        self.llm = llm
        self.store = store
        self.proactivity = proactivity
    }

    /// Begin listening. Safe to call on an already-running analyst.
    func start() {
        guard loop == nil else { return }
        Log.llm.info("live: listening (\(proactivity.level.title), >=\(proactivity.level.minNewLines) new lines, >=\(Int(interval))s apart)")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    /// Stop listening but keep what was found — the finalize still needs it.
    func stop() {
        let wasRunning = loop != nil
        loop?.cancel()
        loop = nil
        pass?.cancel()
        pass = nil
        recallPass?.cancel()
        recallPass = nil
        guard wasRunning else { return }
        Log.llm.info("live: stopped with \(findings.count) finding(s)")
    }

    /// Forget the meeting. Called when the recording is cleaned up, after the
    /// finalize has taken what it needs.
    func reset() {
        stop()
        lastPassAt = nil
        lastNoticeAt = nil
        analyzedLines = 0
        lastRecallAt = nil
        recallsUsed = 0
        surfacedLoops = []
        dismissNotice()
        dismissRecall()
        findings = []
    }

    /// Take the notice down. Defaults to forgetting nothing — what it said is
    /// already saved and reaches the summary either way — which is the only
    /// safe default: this is called from a timeout and from the user opening
    /// the panel for an unrelated reason, and neither of those is the user
    /// answering the card.
    ///
    /// `userRejected` is the one path that means something different: the
    /// user's own tap on the dismiss glyph. For a soft finding that is the
    /// veto its tier exists for — it is dropped and will never become a task.
    /// A strict finding is already trustworthy on its own reading, so even a
    /// rejected tap only takes the card down.
    func dismissNotice(userRejected: Bool = false) {
        if userRejected, let notice, notice.tier == .soft,
           let index = findings.firstIndex(where: { $0.id == notice.id }) {
            findings[index].state = .dismissed
            Log.llm.info("live: soft finding dismissed")
            mirrorFindings?(findings)
        }
        noticeExpiry?.cancel()
        noticeExpiry = nil
        guard notice != nil else { return }
        notice = nil
    }

    private func tick() {
        guard pass == nil else { return }
        let lines = store.entries.count
        guard lines - analyzedLines >= proactivity.level.minNewLines else { return }
        if let lastPassAt, Date().timeIntervalSince(lastPassAt) < interval { return }

        // Not marked analysed yet: `run` commits on success, so a pass that
        // fails leaves its lines for the next one to read again. `pass == nil`
        // above is what stops a second pass seeing the same delta meanwhile.
        let newLines = lines - analyzedLines
        lastPassAt = Date()
        // The handle is cleared only if it is still this task's. Pause/resume
        // cancels a pass and starts the loop again, and the cancelled task's
        // continuation still runs — clearing unconditionally it would drop its
        // successor's handle, and the next tick would start a second pass
        // alongside one already in flight.
        let task = Task<Void, Never> { [weak self] in await self?.run(newLines: newLines) }
        pass = task
        Task { [weak self] in
            _ = await task.value
            guard let self, pass == task else { return }
            pass = nil
        }
    }

    private func run(newLines: Int) async {
        guard !Task.isCancelled else { return }
        let window = store.recentContext(maxEntries: Self.windowSize(forNewLines: newLines))
        guard !window.isEmpty else { return }
        // Same window, same cadence, one more question asked of it: does
        // anything the user already knows bear on this? Fired alongside rather
        // than after, because it must not wait on the live pass to finish and
        // it never blocks it.
        recallPass?.cancel()
        recallPass = Task { [weak self] in await self?.considerRecall(window: window) }

        // A dismissed finding is the user's own veto — it must not block a later,
        // genuine version of the same thing from registering as new, and it has
        // no business being restated as [ALREADY FOUND].
        let memory = Array(findings.filter { $0.state == .standing }.suffix(Self.memoryDepth))
        let prompt = PromptLibrary.buildLivePass(
            window: window,
            known: memory.map { (kind: $0.kind.rawValue, text: $0.text) }
        )
        do {
            let result = try await llm.completeJSON(
                system: prompt.system,
                user: prompt.user,
                as: PromptLibrary.LivePassResult.self,
                primaryModel: llm.utilityModel
            )
            // After the apply, not before. A pause cancels the pass mid-flight
            // — `MeetingSession.toggleRecording` does exactly that — and lines
            // marked read by a pass that then threw its findings away are lines
            // nothing reads again. The commitment made just before the pause
            // would reach the recap and nothing else.
            if await apply(result.items, window: window, memory: memory) {
                analyzedLines += newLines
            }
        } catch {
            // The meeting is being recorded and summarised regardless; a failed
            // live pass costs the user nothing they can see, and the next tick
            // tries again on a wider window. A pause cancels the request, and
            // that is not a fault to report.
            if Task.isCancelled {
                Log.llm.info("live: pass cancelled")
            } else {
                Log.llm.error("live: pass failed — \(error.localizedDescription)")
            }
        }
    }

    private func apply(
        _ items: [PromptLibrary.LivePassItem],
        window: String,
        memory: [LiveFinding]
    ) async -> Bool {
        // Verified first, settled second, committed last. The pure guards can
        // say no on their own — a quote that is not in the window is not a
        // finding whatever it means — and only what survives them is worth
        // asking the model about.
        //
        // `pending` is what this response has already accepted: `verify` reads
        // it alongside the committed list, so a second item quoting a span the
        // first one used, or claiming the same original, is refused exactly as
        // it would be a pass later.
        var pending: [LiveFinding] = []
        for item in items {
            guard let finding = verify(item, window: window, memory: memory, pending: pending) else { continue }
            pending.append(finding)
        }
        guard !pending.isEmpty else { return true }

        let declared = Set(pending.compactMap { $0.revisionOf == nil ? nil : $0.id })
        let accepted = await settle(pending)
        // The pass can be cancelled while the settlement is in flight — the
        // user pressing stop is the ordinary way — and `settle` cannot tell a
        // cancelled request from a failed one, so it fails open on both.
        // Committing here would put a card on screen for a meeting that has
        // ended and mirror findings the finalize has already read past.
        guard !Task.isCancelled else { return false }
        guard !accepted.isEmpty else { return true }

        for finding in accepted {
            if let supersededID = finding.revisionOf,
               let index = findings.firstIndex(where: { $0.id == supersededID }),
               findings[index].state == .standing {
                findings[index].state = .superseded
            }
            findings.append(finding)
            Log.llm.info("live: \(finding.kind.rawValue)\(finding.revisionOf == nil ? "" : " (revision)")")
            Log.llm.sensitive("live: \(finding.text)")
        }
        mirrorFindings?(findings)

        // One notice per pass, at most. Raising two means the first is replaced
        // before it can be read, which is worse than not showing it — a card
        // that flashes reads as a glitch, not as something Nod knew.
        raiseNotice(from: accepted, declared: declared)
        return true
    }

    /// Whether this is worth taking the user's attention mid-meeting, and
    /// whether now is the moment.
    ///
    /// A revision the pass itself named always is — `urgent`. "We said
    /// Thursday, now it's Monday" is precisely what nobody reconstructs
    /// afterwards, and it is the one thing Nod can say that the room itself may
    /// not have noticed. Beyond that, a commitment or a decision earns an
    /// interruption; an open question is worth recording, not worth stopping
    /// someone mid-sentence for.
    nonisolated static func worthInterrupting(_ finding: LiveFinding, urgent: Bool) -> Bool {
        urgent || finding.kind == .action || finding.kind == .decision
    }

    private func raiseNotice(from accepted: [LiveFinding], declared: Set<UUID>) {
        // Chosen from what would actually be shown, not from what came first.
        // Picking the candidate before the worthiness test is how a settlement
        // that read an open question as a change came to take the slot and then
        // fail the kind gate, so a real commitment beside it showed nothing.
        let worthy = accepted.filter { Self.worthInterrupting($0, urgent: declared.contains($0.id)) }
        // A change of mind the pass itself named leads: it is the only one that
        // skips the cooldown, and letting anything else take the slot costs the
        // user the one card this whole feature exists for.
        guard let finding = worthy.first(where: { declared.contains($0.id) }) ?? worthy.first else { return }

        let urgent = declared.contains(finding.id)
        if !urgent, let lastNoticeAt, Date().timeIntervalSince(lastNoticeAt) < proactivity.level.noticeCooldown {
            return
        }
        noticeExpiry?.cancel()
        lastNoticeAt = Date()
        notice = finding
        let lifetime = finding.tier == .soft ? Self.softNoticeLifetime : Self.noticeLifetime
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            dismissNotice()
        }
    }

    /// Puts a recall on screen, with the same lifetime the findings use: it
    /// says its piece and gets out of the way, because the user is in a
    /// conversation and did not ask.
    func raise(_ recalled: LiveRecall) {
        recallExpiry?.cancel()
        recall = recalled
        if recalled.origin.isOpenLoop {
            surfacedLoops.append(recalled)
        }
        recallExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeLifetime * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            dismissRecall()
        }
    }

    func dismissRecall() {
        recallExpiry?.cancel()
        recallExpiry = nil
        guard recall != nil else { return }
        recall = nil
    }

    /// The model's half of the contract, checked. A finding survives only if it
    /// names a kind we store, says something, and quotes the window verbatim.
    private func verify(
        _ item: PromptLibrary.LivePassItem,
        window: String,
        memory: [LiveFinding],
        pending: [LiveFinding]
    ) -> LiveFinding? {
        let evidenceIdx = evidenceIndex(for: item.quote.trimmingCharacters(in: .whitespacesAndNewlines))
        return Self.verify(
            item,
            window: window,
            memory: memory,
            found: findings + pending,
            evidence: (evidenceIdx, evidenceIdx.map { store.entries[$0].timestamp })
        )
    }

    /// The judgement itself, with the transcript already resolved to a line.
    /// `nonisolated static` for the same reason `isQuoted` is: it is the part
    /// worth testing, and it needs nothing from the running meeting.
    nonisolated static func verify(
        _ item: PromptLibrary.LivePassItem,
        window: String,
        memory: [LiveFinding],
        found: [LiveFinding],
        evidence: (idx: Int?, spokenAt: Date?)
    ) -> LiveFinding? {
        // `theirs` is the recap's own classification, from a field the live
        // prompt does not have. A live finding carrying it would land confirmed
        // with nothing to corroborate it — `saveExtracted` reconciles actions.
        guard let kind = ActionItem.Kind(rawValue: item.kind), kind != .theirs else { return nil }
        let tier = LiveFinding.Tier(rawValue: item.tier ?? "") ?? .strict
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isQuoted(quote, in: window) else {
            Log.llm.info("live: dropped — quote is not in the window")
            return nil
        }

        let claimed = revised(by: item, of: kind, in: memory, among: found)

        // One sentence, one finding. Consecutive windows overlap by design, so
        // the same line is read three or four times and read differently each
        // time — on a real call one line about who could bring in users
        // produced two tasks, and one line about pricing produced a task and an
        // open question. `found` is the live list, so an item accepted earlier
        // in this same response is already in the way.
        //
        // Standing only, per the rule the memory is built on: a dismissed
        // finding is the user's veto on that reading, not on the sentence, and
        // a superseded one has already been answered by a later moment.
        //
        // A revision is not exempt. A change of mind is said in a *new*
        // sentence, so an item quoting a span that has already been read is
        // that span read again whatever it claims about it.
        if found.contains(where: { $0.state == .standing && sameSpan($0, at: evidence.idx, quote: quote) }) {
            Log.llm.info("live: dropped — this sentence has already been read")
            return nil
        }

        // The same sentence twice. Not a threshold — literally the same words,
        // which is never a change of mind and never needs a model to say so.
        // Everything looser than this is `settle`'s question.
        if found.contains(where: {
            $0.state == .standing && $0.id != claimed?.id
                && ActionItemDedup.normalized($0.text) == ActionItemDedup.normalized(text)
        }) {
            Log.llm.info("live: dropped — word for word what is already open")
            return nil
        }

        // A revision has to say something else. Observed on a real call: the
        // model re-emitted a finding word for word and marked it as superseding
        // its own original, which retired a good row for nothing and — because
        // revisions bypass the notice cooldown — put a "Changed" card in front
        // of the user that said what the last one said.
        //
        // Literally the same sentence, and nothing looser. A task is four or
        // five words, so every similarity bar low enough to catch a repeat also
        // catches a change of mind: "Ship the deck by Friday" against "…by
        // Monday" scores 0.67 on meaningful tokens, "Ship v2 by Friday" and
        // "Ship v3 by Friday" tokenize identically, and "Anna sends to Mike"
        // and "Mike sends to Anna" are the same set of words. Whether two
        // sentences say the same thing is `settle`'s question, not a
        // comparison's.
        if let claimed, ActionItemDedup.normalized(claimed.text) == ActionItemDedup.normalized(text) {
            Log.llm.info("live: dropped — revision restates its original")
            return nil
        }

        return LiveFinding(
            kind: kind,
            text: text,
            tier: tier,
            deadline: item.deadline?.nilIfBlank,
            evidenceIdx: evidence.idx,
            quote: quote,
            spokenAt: evidence.spokenAt,
            revisionOf: claimed?.id
        )
    }

    /// What the model says this item replaces, taken only when the claim can be
    /// acted on: the number has to be in range, it has to name the same kind of
    /// thing — a task changes a task, a decision changes a decision, and
    /// "migrate the schema to Postgres" does not retire "we're going with
    /// Postgres" — the finding has to still be standing, and nothing may
    /// already be revising it.
    ///
    /// The rule costs one real case: a cancellation the room phrases as a
    /// decision ("we're not doing the offsite") cannot retire the task it
    /// cancels, so both stand. That is the cheap half of the trade — two rows
    /// the user can read against each other, rather than a commitment deleted
    /// because something adjacent was said about it. The settlement takes the same rule on the
    /// other path that can retire a standing finding. Two items in one
    /// response can both point at the same original, and the retirement does
    /// not land until the whole response has been verified — so `found`
    /// carries the response's own accepted items, and the third condition is
    /// what stops one change of mind becoming two.
    ///
    /// Nothing here judges whether the claim is *apt*. A cancellation is
    /// shorter than what it cancels and shares almost nothing with it, so every
    /// bar that refuses an ill-fitting claim also refuses a real withdrawal.
    /// These two conditions can only be wrong about the model's arithmetic,
    /// never about its intent.
    private nonisolated static func revised(
        by item: PromptLibrary.LivePassItem,
        of kind: ActionItem.Kind,
        in memory: [LiveFinding],
        among found: [LiveFinding]
    ) -> LiveFinding? {
        guard let claimed = item.supersedes else { return nil }
        guard let candidate = memory.indices.contains(claimed - 1) ? memory[claimed - 1] : nil,
              candidate.kind == kind,
              found.contains(where: { $0.id == candidate.id && $0.state == .standing }),
              !found.contains(where: { $0.revisionOf == candidate.id })
        else {
            Log.llm.info("live: revision claim doesn't hold up — reading it as new")
            return nil
        }
        return candidate
    }

    /// Whether a finding was read from these same words.
    ///
    /// The words *and*, when both sides resolve to one, the line. Either alone
    /// is wrong: a transcript entry is a whole VAD segment — seventeen seconds
    /// at p90 — so the line on its own lets the first finding in a turn veto a
    /// second, genuine commitment in it, and the words on their own collide
    /// wherever the room is fluent ("I'll send it over" is said about the deck
    /// at minute six and the SOC 2 letter at minute forty-eight).
    ///
    /// Equality on the words, not containment. A span that contains another is
    /// as often a second commitment in the same turn as it is the same one
    /// quoted twice, and a room correcting itself mid-sentence — "we said
    /// Thursday, actually make it Monday" — quotes a span that contains the
    /// one its original was read from. Refusing that loses the correction; the
    /// most a miss here costs is one duplicate.
    private nonisolated static func sameSpan(
        _ finding: LiveFinding,
        at line: Int?,
        quote: String
    ) -> Bool {
        guard sameEvidence(finding.quote, quote) else { return false }
        guard let line, let known = finding.evidenceIdx else { return true }
        return known == line
    }

    /// Whether the quote is literally in the window. Whitespace is normalised
    /// because the window is assembled with speaker tags and line breaks the
    /// model does not reproduce exactly — but nothing else is, since tolerating
    /// a paraphrase here would give up the only check we have.
    nonisolated static func isQuoted(_ quote: String, in window: String) -> Bool {
        let needle = normalized(quote)
        guard needle.count >= 12 else { return false }
        return normalized(window).contains(needle)
    }

    /// Whether a finding already on file was read from the same words.
    ///
    /// Equality, not containment: a longer span that happens to contain a
    /// shorter one is as often a second commitment in the same turn as it is
    /// the same commitment quoted twice, and `isQuoted`'s floor is twelve
    /// characters — three words — so a generic early quote would go on vetoing
    /// every longer line that contained it for the rest of the meeting.
    nonisolated static func sameEvidence(_ existing: String?, _ candidate: String) -> Bool {
        guard let existing else { return false }
        return normalized(existing) == normalized(candidate)
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The transcript line the quote came from, or nil when no single line
    /// carries it — a quote spanning two turns has no one line to point at, and
    /// guessing one would put the wrong sentence behind the finding.
    private func evidenceIndex(for quote: String) -> Int? {
        let needle = Self.normalized(quote)
        return store.entries.lastIndex { Self.normalized($0.text).contains(needle) }
    }
}
