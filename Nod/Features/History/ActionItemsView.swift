import SwiftUI

/// What the meeting produced: its action items as an interactive checklist,
/// what it settled or left open, and — last — what it moved that was already
/// open before it started.
///
/// The only place open loops are shown at rest. There is deliberately no screen
/// of everything still outstanding: a list you have to visit is a list you have
/// to keep, and this product's claim is that you do not. What is open reaches
/// you in the meeting where it matters, and afterwards it is here, under the
/// recap of the conversation that touched it.
///
/// Each task row toggles a persisted `done` state (optimistic, reverted on
/// failure). Single-user product: no owner/assignee chrome — just the task, an
/// optional deadline, and the checkbox. Renders nothing until (and unless) the
/// meeting has something in one of the lists.
struct ActionItemsView: View {
    let meeting: Meeting

    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var proposals: ActionProposalStore

    /// Loops from earlier meetings this conversation moved, newest first.
    @State private var moved: [Moved] = []
    /// Why a row is in a state the person did not put it in, for this meeting's
    /// rows only.
    @State private var reasons: [UUID: ActionItemTransition] = [:]

    /// A named type rather than a labelled tuple: an array of those has to have
    /// its metadata built at runtime, and doing that inside a list is what
    /// crashed the screen this section replaces.
    private struct Moved: Identifiable {
        let item: ActionItem
        let move: ActionItemTransition
        let source: String?

        var id: UUID {
            move.id
        }
    }

    /// Empty unless the checklist is this user's to see. The store is shared and
    /// other surfaces populate it unconditionally, so gating only the loader
    /// below left a Starter user with a fully interactive Pro checklist.
    private var items: [ActionItem] {
        guard entitlements.mayUse(.actionItems) else { return [] }
        return actionItemStore.items(forMeeting: meeting.id)
    }

    /// What the meeting settled, left open, or committed somebody else to,
    /// caught as it was said. Loaded here rather than held in the store: none
    /// of it is the user's to do, and any of it counted among their open
    /// commitments would be wrong on every screen that reads them.
    @State private var notes: [ActionItem] = []

    /// Real tasks with a real owner who is not the user. Their own group
    /// rather than a line in "Also noted": the user cannot tick them off, but
    /// they are the answer to "what did the room take on", and on a call the
    /// user mostly listened to they are most of what it produced.
    private var theirs: [ActionItem] {
        notes.filter { $0.kind == .theirs }
    }

    private var alsoNoted: [ActionItem] {
        notes.filter { $0.kind != .theirs }
    }

    var body: some View {
        Group {
            if !items.isEmpty || !notes.isEmpty || !moved.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Divider().overlay(Theme.Palette.border)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("Action items")
                            VStack(spacing: 4) {
                                ForEach(items) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                    if !theirs.isEmpty {
                        noteGroup("Committed by others", theirs, labelled: false)
                    }
                    if !alsoNoted.isEmpty {
                        noteGroup("Also noted", alsoNoted, labelled: true)
                    }
                    if !moved.isEmpty {
                        movedGroup
                    }
                }
                .padding(.top, 4)
            }
        }
        .task(id: meeting.id) {
            await load()
            guard !items.isEmpty else { return }
            analytics.record(
                .actionItemsViewed,
                properties: .init(
                    sessionKind: meeting.kind.rawValue,
                    entryPoint: .meetingDetail,
                    surface: .meetingDetail,
                    contentType: .actionItems,
                    outcome: .viewed
                ),
                oncePerSession: "meeting:\(meeting.id.uuidString)"
            )
        }
    }

    private func noteGroup(_ title: String, _ rows: [ActionItem], labelled: Bool) -> some View {
        group(title, rows) { noteRow($0, labelled: labelled) }
    }

    /// The heading-and-rows shape every section on this page shares.
    private func group<Row: Identifiable>(
        _ title: String,
        _ rows: [Row],
        @ViewBuilder row: @escaping (Row) -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            VStack(spacing: 4) {
                ForEach(rows) { row($0) }
            }
        }
    }

    /// No checkbox: nothing here is the user's to complete. A decision the room
    /// made is a fact about the meeting, and offering to tick it off would
    /// invite them to edit the record rather than read it.
    ///
    /// `labelled` is off for a group whose heading already says what every row
    /// in it is — a column of identical "THEIRS" chips is noise.
    private func noteRow(_ note: ActionItem, labelled: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if labelled {
                Text(label(for: note.kind))
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 62, alignment: .leading)
            }
            Text(note.text)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func label(for kind: ActionItem.Kind) -> String {
        switch kind {
        case .action: "TASK"
        case .theirs: "THEIRS"
        case .decision: "DECIDED"
        case .question: "OPEN"
        case .risk: "RISK"
        case .followUp: "FOLLOW UP"
        }
    }

    private func row(_ item: ActionItem) -> some View {
        HStack(spacing: 6) {
            toggleRow(item)
            ActionItemFilingButton(item: item)
        }
    }

    private func toggleRow(_ item: ActionItem) -> some View {
        Button {
            Task { await actionItemStore.setDone(!item.done, itemID: item.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ActionCheckbox(done: item.done)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(item.done ? Theme.Palette.muted : Theme.Palette.ink.opacity(0.92))
                        .strikethrough(item.done, color: Theme.Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // Only when something other than the person moved it. An
                    // unticked box beside "Linear says NOD-85 is done" is the
                    // one row here that needs explaining; the rest explain
                    // themselves, and a caption under every task is noise.
                    if let reason = reasons[item.id]?.caption {
                        Text(reason)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.65))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let deadline = item.deadline, !deadline.isEmpty {
                    DeadlinePill(
                        display: ActionItemDeadline.display(phrase: deadline, spokenAt: meeting.startedAt),
                        spokenAt: meeting.startedAt,
                        done: item.done
                    )
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    await actionItemStore.softDelete(itemID: item.id)
                    // An offer to file a row that no longer exists is not
                    // hidden, it is withdrawn — or it comes back on refresh.
                    await proposals.rejectAll(forActionItem: item.id)
                }
            } label: {
                IconLabel(title: "Delete", icon: "nc-trash")
            }
        }
    }

    /// What this conversation did to promises it did not make.
    ///
    /// Last on the page on purpose: everything above is what the meeting was,
    /// and this is what it changed elsewhere. It is also the only part a person
    /// might want to argue with, so it carries the words that moved it and the
    /// session it came from — a state nobody can see the basis for is a state
    /// nobody can correct, and this one was decided by a model.
    private var movedGroup: some View {
        group("Moved by this meeting", moved) { movedRow($0) }
    }

    private func movedRow(_ entry: Moved) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image("nc-arrow-dotted-rotate-anticlockwise")
                .icon(11)
                .foregroundStyle(Theme.Palette.brand)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.item.text)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(entry.move.toState.label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize()
                }
                if let caption = entry.move.caption {
                    Text(caption)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = entry.source {
                    Text("from \(source)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.muted)
    }

    private func load() async {
        guard entitlements.mayUse(.actionItems) else { return }
        // Promotes from the recap when the finalize-time save was skipped
        // (offline) or hadn't committed yet, so the checklist never stays
        // falsely empty.
        // Promotion first, because everything below reads the rows it may write.
        // The three reads after it share no data, so they overlap rather than
        // adding their latencies together on every detail open.
        await actionItemStore.promoteMissing(in: [meeting])
        async let told = actionItemStore.reasons(for: items.map(\.id))
        async let elsewhere = actionItemStore.movesMade(inMeeting: meeting.id)
        do {
            notes = try await actionItemStore.notes(forMeeting: meeting.id)
        } catch {
            // The recap above this already carries what the meeting decided in
            // prose; a failed read here costs a nicety, not the content.
            notes = []
            Log.ui.error("ActionItemsView.notes failed: \(error.localizedDescription)")
        }
        reasons = await told
        moved = await resolve(elsewhere)
    }

    /// The loops this meeting moved, against the rows the store already holds.
    ///
    /// A transition whose item is gone is dropped rather than shown as a move
    /// with no subject: the item was deleted after the fact, and a line saying
    /// something happened to nothing is worse than no line.
    private func resolve(_ transitions: [ActionItemTransition]) -> [Moved] {
        transitions.compactMap { move in
            guard let item = actionItemStore.items.first(where: { $0.id == move.actionItemID }),
                  item.meetingID != meeting.id
            else { return nil }
            let source = meetingStore.meetings
                .first { $0.id == item.meetingID }?
                .displayTitle(dateFormatter: Meeting.listDateFormatter)
            return Moved(item: item, move: move, source: source)
        }
    }
}
