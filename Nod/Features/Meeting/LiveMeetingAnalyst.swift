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
/// Nothing is written to the database from here. See `LiveFinding` for why.
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

    /// Not `private`: `LiveMeetingAnalyst+Assist.swift` (the on-demand
    /// catch-up/follow-ups/ask calls) reads both directly, from a separate
    /// file — same rationale as `windowLines` below.
    let llm: LLMProxyClient
    let store: TranscriptStore

    private var loop: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var lastPassAt: Date?
    private var lastNoticeAt: Date?
    private var noticeExpiry: Task<Void, Never>?
    private var analyzedLines = 0

    /// How often the trigger is checked. Not how often a pass runs — see
    /// `minNewLines` / `minInterval`, which are what actually gate the spend.
    private static let tickInterval: TimeInterval = 15

    /// How much new speech has to land before a pass is worth paying for.
    /// Roughly a minute of back-and-forth. Below this the window is mostly what
    /// the previous pass already read, and re-reading it is spend for nothing.
    private static let minNewLines = 12

    /// The floor between passes regardless of how fast people are talking. With
    /// `minNewLines` this bounds a very talkative hour at 60 passes and leaves a
    /// normal one nearer 25 — which is where the per-hour cost stays a rounding
    /// error against the flat price.
    private static let minInterval: TimeInterval = 60

    /// How much transcript each pass reads. Wider than the new material on
    /// purpose: a commitment is usually made a few lines after the thing it
    /// answers, and a window that starts exactly at the new material keeps
    /// cutting that in half.
    /// Not `private`: `LiveMeetingAnalyst+Assist.swift`'s `suggestFollowUps`
    /// reads the same window size the background pass uses.
    static let windowLines = 40

    /// How long a notice stays up before it goes away on its own. Long enough
    /// to read mid-sentence, short enough that it is gone before the user
    /// wonders whether they have to do something about it.
    private static let noticeLifetime: TimeInterval = 12

    /// A soft finding's own, longer lifetime — reading it is not the whole job,
    /// deciding whether to dismiss it is, and 12 seconds is not enough to do
    /// both mid-sentence.
    private static let softNoticeLifetime: TimeInterval = 20

    /// The quiet stretch after a notice. A meeting can produce three worth
    /// showing inside a minute; showing all three is how a proactive app starts
    /// being ignored. The rest are still recorded and still reach the summary.
    private static let noticeCooldown: TimeInterval = 3 * 60

    /// The findings handed to the model as memory. Older ones fall out — a
    /// superseded item from forty minutes ago is not what the current window is
    /// about, and the memory is the part of the prompt that grows without bound.
    private static let memoryDepth = 12

    /// Override to A/B the cadence without a rebuild, the same way the models
    /// are overridable: `defaults write com.example.nod live.minInterval 30`.
    private static let intervalKey = "live.minInterval"

    private var interval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: Self.intervalKey)
        return override > 0 ? override : Self.minInterval
    }

    init(llm: LLMProxyClient, store: TranscriptStore) {
        self.llm = llm
        self.store = store
    }

    /// Begin listening. Safe to call on an already-running analyst.
    func start() {
        guard loop == nil else { return }
        Log.llm.info("live: listening (>=\(Self.minNewLines) new lines, >=\(Int(interval))s apart)")
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
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        pass?.cancel()
        pass = nil
        Log.llm.info("live: stopped with \(findings.count) finding(s)")
    }

    /// Forget the meeting. Called when the recording is cleaned up, after the
    /// finalize has taken what it needs.
    func reset() {
        stop()
        lastPassAt = nil
        lastNoticeAt = nil
        analyzedLines = 0
        dismissNotice()
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
        }
        noticeExpiry?.cancel()
        noticeExpiry = nil
        guard notice != nil else { return }
        notice = nil
    }

    private func tick() {
        guard pass == nil else { return }
        let lines = store.entries.count
        guard lines - analyzedLines >= Self.minNewLines else { return }
        if let lastPassAt, Date().timeIntervalSince(lastPassAt) < interval { return }

        analyzedLines = lines
        lastPassAt = Date()
        // The handle is cleared only if it is still this task's. Pause/resume
        // cancels a pass and starts the loop again, and the cancelled task's
        // continuation still runs — clearing unconditionally it would drop its
        // successor's handle, and the next tick would start a second pass
        // alongside one already in flight.
        let task = Task<Void, Never> { [weak self] in await self?.run() }
        pass = task
        Task { [weak self] in
            _ = await task.value
            guard let self, pass == task else { return }
            pass = nil
        }
    }

    private func run() async {
        let window = store.recentContext(maxEntries: Self.windowLines)
        guard !window.isEmpty else { return }

        // A dismissed finding is the user's own veto — it must not block a later,
        // genuine version of the same thing from registering as new, and it has
        // no business being restated as [ALREADY FOUND].
        let standing = Array(findings.filter { $0.state == .standing }.suffix(Self.memoryDepth))
        let prompt = PromptLibrary.buildLivePass(window: window, known: standing.map(\.text))
        do {
            let result = try await llm.completeJSON(
                system: prompt.system,
                user: prompt.user,
                as: PromptLibrary.LivePassResult.self,
                primaryModel: llm.utilityModel
            )
            apply(result.items, window: window, standing: standing)
        } catch {
            // The meeting is being recorded and summarised regardless; a failed
            // live pass costs the user nothing they can see, and the next tick
            // tries again on a wider window.
            Log.llm.error("live: pass failed — \(error.localizedDescription)")
        }
    }

    private func apply(
        _ items: [PromptLibrary.LivePassItem],
        window: String,
        standing: [LiveFinding]
    ) {
        var accepted: [LiveFinding] = []
        for item in items {
            guard let finding = verify(item, window: window, standing: standing) else { continue }
            if let supersededID = finding.revisionOf,
               let index = findings.firstIndex(where: { $0.id == supersededID }) {
                findings[index].state = .superseded
            }
            findings.append(finding)
            accepted.append(finding)
            Log.llm.info("live: \(finding.kind.rawValue)\(finding.revisionOf == nil ? "" : " (revision)")")
            Log.llm.sensitive("live: \(finding.text)")
        }

        // One notice per pass, at most. Raising two means the first is replaced
        // before it can be read, which is worse than not showing it — a card
        // that flashes reads as a glitch, not as something Nod knew.
        guard let candidate = accepted.first(where: { $0.revisionOf != nil }) ?? accepted.first else { return }
        raiseNotice(for: candidate)
    }

    /// Whether this is worth taking the user's attention mid-meeting, and
    /// whether now is the moment.
    ///
    /// A revision always is: "we said Thursday, now it's Monday" is precisely
    /// what nobody reconstructs afterwards, and it is the one thing Nod can say
    /// that the room itself may not have noticed. Beyond that, only a commitment
    /// — an action — earns an interruption; a decision or an open question is
    /// worth recording, not worth stopping someone mid-sentence for.
    private func raiseNotice(for finding: LiveFinding) {
        let isRevision = finding.revisionOf != nil
        guard isRevision || finding.kind == .action else { return }
        if !isRevision, let lastNoticeAt, Date().timeIntervalSince(lastNoticeAt) < Self.noticeCooldown {
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

    /// The model's half of the contract, checked. A finding survives only if it
    /// names a kind we store, says something, and quotes the window verbatim.
    private func verify(
        _ item: PromptLibrary.LivePassItem,
        window: String,
        standing: [LiveFinding]
    ) -> LiveFinding? {
        guard let kind = ActionItem.Kind(rawValue: item.kind) else { return nil }
        let tier = LiveFinding.Tier(rawValue: item.tier ?? "") ?? .strict
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isQuoted(quote, in: window) else {
            Log.llm.info("live: dropped — quote is not in the window")
            return nil
        }

        let claimed = item.supersedes
            .map { $0 - 1 }
            .flatMap { standing.indices.contains($0) ? standing[$0] : nil }

        // A revision has to actually revise something. Observed on a real call:
        // the model re-emitted a finding word for word and marked it as
        // superseding its own original, which retired a good row for nothing and
        // — because revisions bypass the notice cooldown — put a "Changed"
        // card in front of the user that said what the last one said.
        if let claimed, ActionItemDedup.same(claimed.text, text) { return nil }

        // A restatement the model didn't flag as one. Cheaper to catch here than
        // to show the user the same task twice and ask them to tell them apart.
        if claimed == nil, standing.contains(where: { ActionItemDedup.same($0.text, text) }) {
            return nil
        }
        let revisionOf = claimed?.id

        return LiveFinding(
            kind: kind,
            text: text,
            tier: tier,
            deadline: item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
            evidenceIdx: evidenceIndex(for: quote),
            revisionOf: revisionOf
        )
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

private extension String {
    var nilWhenEmpty: String? {
        isEmpty ? nil : self
    }
}
