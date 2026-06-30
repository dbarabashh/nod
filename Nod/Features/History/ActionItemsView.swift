import SwiftUI

/// The meeting's action items as an interactive checklist. Each row toggles a
/// persisted `done` state (optimistic, reverted on failure). Single-user
/// product: no owner/assignee chrome — just the task, an optional deadline, and
/// the checkbox. Renders nothing until (and unless) the meeting has any items.
struct ActionItemsView: View {
    let meeting: Meeting

    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService

    @State private var items: [ActionItem] = []
    /// Items whose toggle is mid-flight — disables the row so a double-tap
    /// can't race two writes for the same id.
    @State private var inFlight: Set<UUID> = []

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
        .task(id: meeting.id) { await load() }
    }

    private func row(_ item: ActionItem) -> some View {
        Button {
            Task { await toggle(item) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                checkbox(done: item.done)
                Text(item.text)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(item.done ? Theme.Palette.muted : Theme.Palette.ink.opacity(0.92))
                    .strikethrough(item.done, color: Theme.Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline = item.deadline, !deadline.isEmpty {
                    deadlinePill(deadline)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inFlight.contains(item.id))
        .contextMenu {
            Button(role: .destructive) {
                Task { await delete(item) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func checkbox(done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Theme.Palette.brand : Color.clear)
                .overlay(
                    Circle().stroke(
                        done ? Theme.Palette.brand : Theme.Palette.borderStrong,
                        lineWidth: 1.5
                    )
                )
                .frame(width: 18, height: 18)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.bg)
            }
        }
        // Keep the control aligned with the first text line.
        .offset(y: 1)
    }

    private func deadlinePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Palette.warning)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.warning.opacity(0.12))
            )
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.muted)
    }

    private func load() async {
        // Pro-gated, fail-open like the cross-meeting upsell: a Starter / locked
        // user doesn't get the checklist, but an unresolved entitlement still
        // loads so a Pro user with a transient fetch failure isn't blocked.
        guard entitlements.entitlement == nil || entitlements.can(.actionItems) else { return }
        do {
            // `itemsPromoting` backfills from the recap when the finalize-time
            // save was skipped (offline) or hadn't committed yet (raced this
            // view's first load), so the checklist never stays falsely empty.
            items = try await actionItemStore.itemsPromoting(for: meeting)
        } catch {
            Log.ui.error("ActionItemsView.load failed: \(error.localizedDescription)")
        }
    }

    private func toggle(_ item: ActionItem) async {
        guard let idx = items.firstIndex(where: { $0.id == item.id }),
              !inFlight.contains(item.id) else { return }
        let target = !items[idx].done
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }

        let previous = items[idx]
        items[idx] = previous.marked(done: target, at: Date())
        do {
            try await actionItemStore.setDone(target, itemID: item.id)
        } catch {
            // Revert the optimistic flip if the row drifted; otherwise restore.
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = previous
            }
            Log.ui.error("ActionItemsView.toggle failed: \(error.localizedDescription)")
        }
    }

    private func delete(_ item: ActionItem) async {
        guard !inFlight.contains(item.id) else { return }
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }
        let snapshot = items
        withAnimation(.easeInOut(duration: 0.18)) {
            items.removeAll { $0.id == item.id }
        }
        do {
            try await actionItemStore.softDelete(itemID: item.id)
        } catch {
            items = snapshot
            Log.ui.error("ActionItemsView.delete failed: \(error.localizedDescription)")
        }
    }
}
