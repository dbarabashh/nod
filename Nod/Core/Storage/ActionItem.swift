import Foundation

/// One thing a meeting produced — a task, a decision, an open question. Wire
/// compatible with the `action_items` table (`20260629120000_action_items.sql`,
/// widened by `20260806164035_action_item_lifecycle.sql`).
///
/// It is no longer only the recap's output. A row can be raised mid-meeting,
/// corroborated or dropped when the recap lands, and superseded by a later
/// moment in the same conversation — which is why `status` exists alongside
/// `done`. `done` is the user's checkbox on a real task; `status` is whether it
/// is a real task at all yet.
///
/// Single-user product: there is no owner/assignee column — every item is the
/// user's own task; an "ask Sam" lives inside `text`. `createdAt`/`updatedAt`/
/// `deletedAt` are server-driven and nil on a freshly-built row before insert.
struct ActionItem: Codable, Identifiable, Equatable {
    let id: UUID
    let meetingID: UUID
    let userID: UUID
    var text: String
    /// Free-text deadline as stated in the meeting ("by Friday"), or nil.
    var deadline: String?
    /// What kind of thing a meeting produced. Tasks are the majority and the
    /// only kind the recap has ever emitted; the rest come from the live pass,
    /// which hears decisions and open questions too.
    var kind: Kind = .action
    /// Where in its life this is — orthogonal to `done`, which is the user's
    /// checkbox on a real task. This is whether it is a real task *yet*.
    var status: Status = .confirmed
    /// Which pass produced it, so the finalize can reconcile rather than
    /// refusing to write because rows already exist.
    var source: Source = .recap
    /// What this replaces, when a later moment in the same meeting overruled an
    /// earlier one. The replacement points back; the replaced row is marked
    /// `superseded` rather than rewritten, because rewriting loses the history
    /// that is the whole point of noticing.
    var revisionOf: UUID?
    /// The transcript entry that produced this (`meeting_transcripts.idx`).
    /// The answer to "why does this exist, and who said it".
    var evidenceIdx: Int?
    /// The words themselves, kept so the citation survives re-transcription: an
    /// index moves when a meeting is transcribed again, and a quote does not.
    var evidenceQuote: String?
    /// Preserves the recap's emitted order within a meeting. Nil for anything
    /// the live pass appended — it has no order to preserve.
    var position: Int?
    var done: Bool
    var doneAt: Date?
    /// What became of it, as against whether somebody ticked a box.
    ///
    /// `done` is one bit set by hand, and most rows sit open because nobody ever
    /// sets it. This is the same thing with room for what we can actually work
    /// out: a PR merged and a Linear issue closed is not the same amount of
    /// knowing as the person who asked saying thanks, and a system that treats
    /// them alike closes things that are not done.
    ///
    /// The two are kept coherent by the database, in both directions, so a build
    /// that has never heard of this column still reads and writes these rows
    /// correctly — see `20260827010000_a_loop_closes_on_evidence.sql`.
    var loopState: LoopState = .open
    /// Where this was filed, once it has been. All four move together — see the
    /// check constraint in `20260812195722_action_item_external_refs.sql`.
    var externalProvider: String?
    var externalKey: String?
    var externalURL: String?
    var externalCreatedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?

    /// Where this sits in its meeting's list. Anything the live pass appended
    /// has no `position` of its own and falls to the end.
    var order: Int {
        position ?? .max
    }

    /// Whether this has been filed in a connected product — the cheap question,
    /// for callers that only need to know whether to offer to file it.
    var isFiled: Bool {
        externalKey != nil
    }

    /// Where it was filed, for the caller that draws the reference.
    var filed: ProviderLinkItem? {
        guard let externalProvider, let provider = IntegrationProvider(rawValue: externalProvider),
              let externalKey, let externalURL, let url = URL(string: externalURL)
        else { return nil }
        return ProviderLinkItem(provider: provider, title: externalKey, url: url)
    }

    /// Records where this landed, matching the value-returning mutators its
    /// siblings use rather than poking fields at the call site.
    func filed(in reference: ProviderLinkItem, at filedAt: Date) -> ActionItem {
        var copy = self
        copy.externalProvider = reference.provider.rawValue
        copy.externalKey = reference.title
        copy.externalURL = reference.url.absoluteString
        copy.externalCreatedAt = filedAt
        return copy
    }

    /// Still outstanding: a real task, not ticked off, not in the trash.
    ///
    /// `proposed` is excluded on purpose. The live pass is allowed to be wrong,
    /// and a bad minute of transcription must not inflate the commitments count
    /// on the Home screen — an item earns its place there once the recap
    /// corroborates it or the user acts on it.
    var isOpen: Bool {
        kind == .action && status == .confirmed && !done && deletedAt == nil
    }

    /// Whole days since it was raised, floored, and never negative.
    ///
    /// By calendar day, through the same helper every other date in the app
    /// counts with — a promise made at 20:00 yesterday is "1 day", the way the
    /// session label beside it already says. Never negative, so a row stamped by
    /// a server clock a second ahead reads as today rather than "-0 days".
    func daysOpen(to now: Date = Date()) -> Int {
        guard let createdAt else { return 0 }
        return max(0, DayCount.between(createdAt, and: now))
    }

    /// The text worth matching a conversation against: what the extractor wrote,
    /// plus the sentence it was read from where there is one.
    var matchable: String {
        guard let quote = evidenceQuote, !quote.isEmpty else { return text }
        return "\(text) \(quote)"
    }

    /// Live, confirmed, still open, and not from the meeting doing the asking.
    ///
    /// The last clause is the one worth naming: a loop raised from this very
    /// transcript minutes ago would otherwise come back as a candidate, and
    /// asking the model whether this conversation resolved what this
    /// conversation just raised is asking it to agree with itself.
    func isReachable(excluding meetingID: UUID) -> Bool {
        self.meetingID != meetingID
            && deletedAt == nil
            && status == .confirmed
            && loopState.isOpen
    }

    enum Kind: String, Codable, Equatable, CaseIterable {
        case action
        /// A commitment somebody else made, which the user only witnessed.
        ///
        /// Not an owner column — this stays a single-user product and the
        /// person is named inside `text` as before. It is the answer to a
        /// narrower question the recap alone could not record: is this the
        /// user's to do? Without it the only options were to put someone
        /// else's task in the user's checklist or to drop it, and dropping it
        /// is what a call the user sat in on but did not speak at reduces to.
        case theirs
        case decision
        case question
        case risk
        case followUp = "follow_up"
    }

    /// Where a loop is in its life.
    ///
    /// More than open/closed, because the interesting cases are in between:
    /// something the team started, something an external system says is finished
    /// but nobody acknowledged, something waiting on a named blocker. Closure is
    /// deliberately the hardest state to reach — raising a loop wrongly is
    /// annoying, closing one wrongly loses the thing the product exists to hold.
    enum LoopState: String, Codable, Equatable, CaseIterable {
        /// Nobody has moved on it.
        case open
        /// Somebody has, and said so.
        case inProgress = "in_progress"
        /// Evidence says it is done and nobody confirmed it. Reached readily —
        /// a merged PR, a closed issue — because being wrong here costs a
        /// glance, and never reaching it costs the whole feature.
        case probablyDone = "probably_done"
        /// Done, and we can say why we believe it. Needs the person, the person
        /// who asked, or an authoritative system — not an inference.
        case confirmed
        /// Waiting on something with a name.
        case blocked
        /// It will not happen, and that is settled.
        case cancelled
        /// Another item replaced it.
        case superseded

        /// Whether this still wants somebody's attention. `probablyDone` does:
        /// it is a claim awaiting a glance, and hiding it is how a wrong
        /// closure becomes permanent.
        var isOpen: Bool {
            switch self {
            case .open, .inProgress, .probablyDone, .blocked: true
            case .confirmed, .cancelled, .superseded: false
            }
        }

        /// How the state is named to a person. "Probably done" rather than a
        /// tidier "Done" on purpose: the word carries the doubt, and a label
        /// that hides the doubt is the one that gets believed and left alone.
        var label: String {
            switch self {
            case .open: "Open"
            case .inProgress: "In progress"
            case .probablyDone: "Probably done"
            case .confirmed: "Confirmed done"
            case .blocked: "Blocked"
            case .cancelled: "Dropped"
            case .superseded: "Superseded"
            }
        }
    }

    enum Status: String, Codable, Equatable {
        /// The live pass found it; nothing has corroborated it yet.
        case proposed
        /// Real: the recap agreed, or the user acted on it.
        case confirmed
        /// A later moment in the meeting replaced it.
        case superseded
        /// Retired without ever becoming a real task — the recap stayed
        /// silent on a live guess, or the user rejected a soft one on the
        /// spot (`LiveMeetingAnalyst.dismissNotice(userRejected:)`). Not the
        /// same as the user deleting a *confirmed* item — this is a thing
        /// that never made it into the record in the first place.
        case dropped
    }

    enum Source: String, Codable, Equatable {
        case recap
        case live
        case user
    }

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case userID = "user_id"
        case text
        case deadline
        case kind
        case status
        case source
        case revisionOf = "revision_of"
        case evidenceIdx = "evidence_idx"
        case evidenceQuote = "evidence_quote"
        case loopState = "loop_state"
        case position
        case done
        case doneAt = "done_at"
        case externalProvider = "external_provider"
        case externalKey = "external_key"
        case externalURL = "external_url"
        case externalCreatedAt = "external_created_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    /// Insert payload — server-driven timestamps are omitted so the DB defaults
    /// apply; `done_at` is only sent once the item is checked off (via a patch).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(meetingID, forKey: .meetingID)
        try c.encode(userID, forKey: .userID)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(revisionOf, forKey: .revisionOf)
        try c.encodeIfPresent(evidenceIdx, forKey: .evidenceIdx)
        try c.encodeIfPresent(evidenceQuote, forKey: .evidenceQuote)
        try c.encode(loopState, forKey: .loopState)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
    }

    static func new(
        id: UUID = UUID(),
        meetingID: UUID,
        userID: UUID,
        text: String,
        deadline: String?,
        position: Int?,
        kind: Kind = .action,
        status: Status = .confirmed,
        source: Source = .recap,
        revisionOf: UUID? = nil,
        evidenceIdx: Int? = nil,
        evidenceQuote: String? = nil
    ) -> ActionItem {
        ActionItem(
            id: id,
            meetingID: meetingID,
            userID: userID,
            text: text,
            deadline: deadline,
            kind: kind,
            status: status,
            source: source,
            revisionOf: revisionOf,
            evidenceIdx: evidenceIdx,
            evidenceQuote: evidenceQuote,
            position: position,
            done: false,
            doneAt: nil,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil
        )
    }

    /// A copy with the done state flipped — used for the optimistic local
    /// update before `ActionItemStore.setDone` persists it.
    func marked(done: Bool, at date: Date?) -> ActionItem {
        var copy = self
        copy.done = done
        copy.doneAt = done ? date : nil
        return copy
    }

    /// A copy the recap has corroborated: a live guess that turned out to be
    /// right, restated in the recap's words and taking its place in the recap's
    /// order.
    ///
    /// The text comes from the recap because the recap is the better writer —
    /// whole transcript, stronger model. What survives from the live row is its
    /// `evidenceIdx` and its `source`, which is the half the recap cannot know:
    /// the line this came from, and that Nod caught it while the meeting ran.
    ///
    /// The recap also settles whose task it is. The live pass hears a
    /// commitment and cannot tell, from a few minutes of window, whether the
    /// user is the one on the hook for it.
    func corroborating(_ action: MeetingRecap.Action, position: Int?) -> ActionItem {
        var copy = self
        copy.status = .confirmed
        copy.kind = action.isSomeoneElses ? .theirs : .action
        copy.position = position
        copy.text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let restated = action.deadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copy.deadline = restated.isEmpty ? deadline : restated
        return copy
    }
}
