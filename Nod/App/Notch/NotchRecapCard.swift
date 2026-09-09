import SwiftUI

// MARK: - Recap, right where the meeting just ended

/// The one thing this whole surface has been building toward: the meeting is
/// over, and the recap is right here instead of behind a window the user has
/// to go find. Raised on its own — see `NotchPresentation.recap` — and reads
/// straight off `MeetingStore`, the same source `MeetingDetailView` renders
/// from, so the two never disagree about what happened.
///
/// The action items carry the filing button, which is the point of showing them
/// here rather than only in the window: the moment a commitment is worth putting
/// in a tracker is the moment it was made, and that moment is now — not after
/// the user remembers to go looking for it.
struct NotchRecapCard: View {
    let state: RecapState
    let onClose: () -> Void
    let onExpand: (UUID) -> Void
    let onCopy: (SessionKind) -> Void

    /// Rows, not the recap's own `action_items`: filing writes a pointer back
    /// onto the row, so the button needs the persisted item and its id. They are
    /// written by `saveExtracted` as the meeting finalises, which is the same
    /// moment this card appears.
    @EnvironmentObject private var actionItemStore: ActionItemStore
    /// Only to answer whether the meeting has reached the server yet — sharing
    /// it before then would ask the backend about a row it does not have.
    @EnvironmentObject private var meetingStore: MeetingStore
    /// For the knowledge line alone: what this session's distillation changed.
    /// Zero changes — the expected case — renders nothing at all.
    @EnvironmentObject private var knowledge: KnowledgeStore
    /// For the pattern offer: a habit the miner counted, shown exactly where
    /// the repetition happens — under the proposals the user keeps approving —
    /// and nowhere else.
    @EnvironmentObject private var agents: AgentStore

    private static let maxHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            content(for: state)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("nc-file")
                .icon(12)
                .foregroundStyle(Theme.Palette.brand)
            Text("Session summary")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            NotchGlyphButton(icon: "nc-xmark", help: "Dismiss", action: onClose)
        }
    }

    @ViewBuilder
    private func content(for state: RecapState) -> some View {
        switch state {
        case .generating:
            generating
        case let .ready(meeting):
            ready(meeting)
        case let .failed(message):
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No live partial text: streaming it in redrew this card, and the model's
    /// own identity-change churned the fold-through-resting transition, on
    /// every token the summary streamed. Same three-line script
    /// `MeetingDetailView` paces its own placeholder with, so ending the
    /// meeting in the notch and watching it from the detail view read as one
    /// thing happening, not two.
    private var generating: some View {
        ThinkingIndicator(script: [
            "Writing the recap…",
            "Capturing decisions & action items…",
            "Almost there…"
        ])
    }

    private func ready(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 13) {
                    Text(renderRecapMarkdown(meeting.summary))
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.graphite)
                        .fixedSize(horizontal: false, vertical: true)

                    let filed = actionItemStore.items(forMeeting: meeting.id).filter(\.isOpen)
                    if !filed.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            SectionLabel("Action items", size: .compact)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(filed) { item in
                                    actionRow(item)
                                }
                            }
                        }
                    } else if let items = meeting.recap?.actionItems, !items.isEmpty {
                        // The rows haven't landed yet (a save still in flight, or
                        // one that failed). Showing the recap's own list keeps the
                        // card honest about what the meeting produced; it just
                        // can't be filed from here until there is a row to point
                        // the reference at.
                        VStack(alignment: .leading, spacing: 5) {
                            SectionLabel("Action items", size: .compact)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(items, id: \.text) { item in
                                    pendingRow(item.text, deadline: item.deadline)
                                }
                            }
                        }
                    }

                    // Under the action items, where the demo puts it: the
                    // moment a commitment is worth filing is the moment it was
                    // made, and this is the card that is on screen then.
                    ReadyToFileCard(meetingID: meeting.id, isCompact: true) { onExpand(meeting.id) }
                    knowledgeLine(for: meeting.id)
                    patternOffer
                    grantOffer
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: Self.maxHeight)
            // The rows were written server-side as this meeting finalised, and
            // the notch can run a whole session without the main window ever
            // opening — so this is the one place that has to go and get them.
            .task(id: meeting.id) { await actionItemStore.refresh(force: true) }

            // Bottom-right rather than beside the dismiss glyph: closing is
            // what you do to the card, these are what you do with the meeting.
            HStack(spacing: 6) {
                // Leading, and the only control here carrying words: handing the
                // call to the team that was on it is a decision about the
                // meeting, and it is only ever made in the minute after one ends.
                MeetingShareButton(meetingID: meeting.id, isReady: meetingStore.isPersisted(meeting.id))
                Spacer(minLength: 0)
                NotchCopyGlyphButton(
                    text: {
                        MeetingMarkdownExport.summaryPayload(
                            meeting: meeting,
                            actions: meeting.recap?.actionItems ?? []
                        )
                    },
                    onCopy: { onCopy(meeting.kind) }
                )
                NotchGlyphButton(icon: "nc-arrow-up-right", help: "Open in Nod") { onExpand(meeting.id) }
            }
        }
    }

    /// What this session taught the knowledge layer, said in one line. Shown
    /// only when distillation for THIS meeting changed something: most
    /// sessions restate what is already known, and a "0 facts" line every time
    /// would teach the user the line means nothing.
    @ViewBuilder
    private func knowledgeLine(for meetingID: UUID) -> some View {
        if let outcome = knowledge.lastDistillation,
           outcome.meetingID == meetingID,
           outcome.counts.changed > 0 {
            HStack(spacing: 5) {
                Image("nc-sparkle-3")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.violet)
                Text(Self.knowledgeSummary(outcome.counts))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }

    /// One habit, with its receipts and three answers. Appears only for a
    /// person whose own history earned it, and never twice for a dismissed
    /// one — `answer_pattern_candidate` refuses to resurrect those.
    @ViewBuilder
    private var patternOffer: some View {
        if let candidate = agents.offerableCandidate {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("A habit Nod noticed", size: .compact)
                Text(Self.patternOfferLine(candidate))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(candidate.evidenceLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                    Spacer(minLength: 0)
                    Button("Not useful") {
                        Task { await agents.dismiss(candidate) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
                    Button("Try it") {
                        Task { await agents.accept(candidate) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.brand)
                    .linkCursor()
                }
            }
        }
    }

    /// The offer of standing authority, earned by arithmetic: this agent's
    /// drafts keep being approved untouched. Granting names the exact scope —
    /// one action, five a week, ninety days — and declining costs nothing:
    /// the agent keeps asking, which is what it was already doing.
    @ViewBuilder
    private var grantOffer: some View {
        if let offer = agents.grantOffer {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("Standing grant", size: .compact)
                Text(Self.grantOfferLine(offer.agent, approvals: offer.approvals))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("Keep asking") {
                        agents.declineStanding(offer.agent)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
                    Button("Grant \(AgentStore.grantDays) days") {
                        Task { await agents.grantStanding(offer.agent) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.brand)
                    .linkCursor()
                }
            }
        }
    }

    static func grantOfferLine(_ agent: Agent, approvals: Int) -> String {
        let what = [agent.draftActionPhrase, agent.draftProviderName.map { "in \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
        return "\(agent.title) has drafted right \(approvals) times, nothing rejected. "
            + "Let it file \(what.isEmpty ? "these" : what) itself — "
            + "up to \(AgentStore.grantPerWeek) a week, expires in \(AgentStore.grantDays) days?"
    }

    static func patternOfferLine(_ candidate: PatternCandidate) -> String {
        "You've approved \(candidate.actionPhrase) in \(candidate.providerName) "
            + "\(candidate.support) times. Want a brief after sessions that produce more?"
    }

    static func knowledgeSummary(_ counts: DistillCounts) -> String {
        var parts: [String] = []
        if counts.added > 0 {
            parts.append(counts.added == 1 ? "1 fact learned" : "\(counts.added) facts learned")
        }
        if counts.updated > 0 {
            parts.append(counts.updated == 1 ? "1 updated" : "\(counts.updated) updated")
        }
        if counts.retired > 0 {
            parts.append(counts.retired == 1 ? "1 retired" : "\(counts.retired) retired")
        }
        return parts.joined(separator: " · ")
    }

    private func actionRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            pendingRow(item.text, deadline: item.deadline)
            ActionItemFilingButton(item: item)
                .padding(.top, 1)
        }
    }

    private func pendingRow(_ text: String, deadline: String?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Theme.Palette.muted.opacity(0.7))
                .frame(width: 3, height: 3)
                .padding(.top, 5.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline {
                    Text(deadline)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
