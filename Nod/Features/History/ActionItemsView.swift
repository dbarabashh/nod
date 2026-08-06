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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Empty unless the checklist is this user's to see. The store is shared and
    /// other surfaces populate it unconditionally, so gating only the loader
    /// below left a Starter user with a fully interactive Pro checklist.
    private var items: [ActionItem] {
        guard entitlements.mayUse(.actionItems) else { return [] }
        return actionItemStore.items(forMeeting: meeting.id)
    }

    /// What the meeting settled or left open, caught as it was said. Loaded
    /// here rather than held in the store: these are not tasks, and a decision
    /// counted among the user's open commitments would be wrong on every screen
    /// that reads them.
    @State private var notes: [ActionItem] = []

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
                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("Also noted")
                            VStack(spacing: 4) {
                                ForEach(notes) { note in
                                    noteRow(note)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .task(id: meeting.id) { await load() }
    }

    /// No checkbox: nothing here is the user's to complete. A decision the room
    /// made is a fact about the meeting, and offering to tick it off would
    /// invite them to edit the record rather than read it.
    private func noteRow(_ note: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label(for: note.kind))
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 62, alignment: .leading)
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
        case .decision: "DECIDED"
        case .question: "OPEN"
        case .risk: "RISK"
        case .followUp: "FOLLOW UP"
        }
    }

    private func row(_ item: ActionItem) -> some View {
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
                Label("Delete", systemImage: "trash")
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
