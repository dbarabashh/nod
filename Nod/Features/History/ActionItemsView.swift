import SwiftUI

/// The meeting's action items as an interactive checklist. Each row toggles a
/// persisted `done` state (optimistic, reverted on failure). Single-user
/// product: no owner/assignee chrome — just the task, an optional deadline, and
/// the checkbox. Renders nothing until (and unless) the meeting has any items.
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

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Divider().overlay(Theme.Palette.border)
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Action items")
                        VStack(spacing: 4) {
                            ForEach(items) { item in
                                row(item)
                            }
                        }
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
    }
}
