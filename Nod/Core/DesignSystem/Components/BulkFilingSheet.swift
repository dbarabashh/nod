import SwiftUI

/// Files several action items into one tracker, in a single pass.
///
/// The single-item sheet exists because a task read by someone with none of the
/// meeting in their head has to say more than the sentence someone spoke — so
/// the draft is shown before anything is created. Filing eight items one sheet
/// at a time would honour that rule by making it unusable, and skipping the
/// review to make bulk quick would drop it. So every draft is written first and
/// listed here: one pass, every title editable, nothing created until the
/// button at the bottom.
///
/// Anything already filed is not offered — the reference on the row is what
/// stops the same item being filed twice, and that has to hold for a selection
/// as much as for a click.
struct BulkFilingSheet: View {
    let items: [ActionItem]
    let provider: IntegrationProvider
    let onFinish: () -> Void

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var composer: TaskDraftComposer

    /// Keyed by item, because the drafts arrive out of order — they are written
    /// in parallel, and the sheet lists them in the order the person selected.
    @State private var drafts: [UUID: TaskDraft] = [:]
    @State private var excluded: Set<UUID> = []
    @State private var filing = false
    @State private var filed = 0
    @State private var failed = 0

    private var pending: [ActionItem] {
        items.filter { !$0.isFiled }
    }

    private var included: [ActionItem] {
        pending.filter { !excluded.contains($0.id) }
    }

    private var isReady: Bool {
        drafts.count == pending.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isReady {
                list
                footer
            } else {
                drafting
            }
        }
        .padding(14)
        .frame(width: 460)
        .task { await draftAll() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 13)
            Text("New tasks in \(provider.displayName)")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 0)
            Text("\(included.count) of \(pending.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
        }
        .foregroundStyle(Theme.Palette.ink)
    }

    private var drafting: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reading \(pending.count) \(pending.count == 1 ? "meeting moment" : "meeting moments")…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(pending) { item in
                    row(item)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private func row(_ item: ActionItem) -> some View {
        let isIncluded = !excluded.contains(item.id)
        return HStack(alignment: .top, spacing: 9) {
            Button {
                if isIncluded { excluded.insert(item.id) } else { excluded.remove(item.id) }
            } label: {
                ActionCheckbox(done: isIncluded)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help(isIncluded ? "Leave this one out" : "Include this one")

            TextField("Title", text: titleBinding(item))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isIncluded ? Theme.Palette.ink : Theme.Palette.muted)
                .disabled(!isIncluded)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
        .opacity(isIncluded ? 1 : 0.6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if failed > 0 {
                Text("\(failed) couldn't be created")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: onFinish)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .linkCursor()
            if filing {
                Text("\(filed)/\(included.count)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                ProgressView().controlSize(.small)
            }
            Button(included.count == 1 ? "Create task" : "Create \(included.count) tasks") { file() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(included.isEmpty ? Theme.Palette.muted : Theme.Palette.cyan)
                .disabled(included.isEmpty || filing)
                .linkCursor()
        }
    }

    private func titleBinding(_ item: ActionItem) -> Binding<String> {
        Binding(
            get: { drafts[item.id]?.title ?? item.text },
            set: { drafts[item.id]?.title = $0 }
        )
    }

    /// Written in parallel: each draft is its own model call, and eight of them
    /// in sequence is eight round trips the person waits through.
    private func draftAll() async {
        let written = await withTaskGroup(of: (UUID, TaskDraft).self) { group in
            for item in pending {
                group.addTask { @MainActor in await (item.id, composer.draft(for: item)) }
            }
            var result: [UUID: TaskDraft] = [:]
            for await (id, draft) in group {
                result[id] = draft
            }
            return result
        }
        drafts = written
    }

    /// One at a time, deliberately: a tracker's API is rate-limited, and a burst
    /// that half-succeeds leaves the person to work out which half.
    private func file() {
        filing = true
        filed = 0
        failed = 0
        Task {
            for item in included {
                guard let draft = drafts[item.id] else { continue }
                if let reference = await integrations.file(draft, in: provider) {
                    await actionItemStore.recordFiling(itemID: item.id, reference: reference)
                    filed += 1
                } else {
                    failed += 1
                }
            }
            filing = false
            if failed == 0 { onFinish() }
        }
    }
}
