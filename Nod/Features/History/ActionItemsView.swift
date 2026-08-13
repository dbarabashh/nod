import SwiftUI

/// What the meeting produced: its action items as an interactive checklist,
/// and below them what it settled or left open.
///
/// Each task row toggles a persisted `done` state (optimistic, reverted on
/// failure). Single-user product: no owner/assignee chrome — just the task, an
/// optional deadline, and the checkbox. Renders nothing until (and unless) the
/// meeting has something in either list.
struct ActionItemsView: View {
    let meeting: Meeting

    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var analytics: ProductAnalytics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            if !items.isEmpty || !notes.isEmpty {
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
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            VStack(spacing: 4) {
                ForEach(rows) { note in
                    noteRow(note, labelled: labelled)
                }
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
                Text(item.text)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(item.done ? Theme.Palette.muted : Theme.Palette.ink.opacity(0.92))
                    .strikethrough(item.done, color: Theme.Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
                Task { await actionItemStore.softDelete(itemID: item.id) }
            } label: {
                IconLabel(title: "Delete", icon: "nc-trash")
            }
        }
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
        await actionItemStore.promoteMissing(in: [meeting])
        do {
            notes = try await actionItemStore.notes(forMeeting: meeting.id)
        } catch {
            // The recap above this already carries what the meeting decided in
            // prose; a failed read here costs a nicety, not the content.
            notes = []
            Log.ui.error("ActionItemsView.notes failed: \(error.localizedDescription)")
        }
    }
}
