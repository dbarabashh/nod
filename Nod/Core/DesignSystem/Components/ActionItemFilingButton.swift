import AppKit
import SwiftUI

/// Files an action item into a connected tracker.
///
/// Draws one mark per connected tracker. Nothing connected means nothing drawn
/// — a button offering an integration the user hasn't set up is an advert, not
/// an affordance.
///
/// Clicking opens the task before it exists, not after. An action item is a note
/// to self written from one sentence; a ticket is read by someone with none of
/// the meeting in their head, so what goes across is drafted from the
/// conversation around it and shown for editing first. Two things are decided on
/// that sheet: what the task says, and whether it should exist at all — a match
/// already in the tracker is offered there rather than in a separate prompt.
///
/// Once filed the button is replaced by the reference, which is also what stops
/// the same item being filed twice.
struct ActionItemFilingButton: View {
    let item: ActionItem

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var composer: TaskDraftComposer

    @State private var composing: IntegrationProvider?
    @State private var draft: TaskDraft?
    @State private var match: TaskMatch?
    @State private var isFiling = false
    /// Local, not the service's `lastError`: that one is rendered in Settings,
    /// and a row on Home failing to file has no way to show it there.
    @State private var failed = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        content
            .popover(isPresented: isComposing, arrowEdge: .bottom) {
                if let provider = composing { sheet(provider) }
            }
    }

    @ViewBuilder private var content: some View {
        if let filed = item.filed {
            reference(filed)
        } else if integrations.taskTargets.count == 1, let only = integrations.taskTargets.first {
            // One tracker: the slot is that tracker. Asking "which one?" of a
            // list of one is a click that answers itself.
            mark(only)
        } else if !integrations.taskTargets.isEmpty {
            // One slot, whatever is connected. Drawn per tracker, the row grew a
            // button for every integration Nod ever adds — four connected
            // products meant four glyphs in a row that has space for two.
            targetMenu
        }
    }

    private var targetMenu: some View {
        Menu {
            ForEach(integrations.taskTargets) { provider in
                Button {
                    compose(in: provider)
                } label: {
                    IconLabel(title: "Send to \(provider.displayName)", icon: provider.iconName)
                }
            }
        } label: {
            Image("nc-paper-plane-2")
                .icon(11)
                .foregroundStyle(failed ? Theme.Palette.danger : Theme.Palette.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .linkCursor()
        .help(failed ? "Couldn't file that — try again" : "Send to…")
    }

    private var isComposing: Binding<Bool> {
        Binding(get: { composing != nil }, set: { if !$0 { dismiss() } })
    }

    private func mark(_ provider: IntegrationProvider) -> some View {
        Button { compose(in: provider) } label: {
            ProviderMark(provider: provider, size: 12)
                .opacity(failed ? 0.5 : 1)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help(failed ? "Couldn't file that — try again" : "File in \(provider.displayName)")
    }

    private func reference(_ filed: ProviderLinkItem) -> some View {
        Button { NSWorkspace.shared.open(filed.url) } label: {
            HStack(spacing: 4) {
                ProviderMark(provider: filed.provider, size: 11)
                Text(filed.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.muted)
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Open \(filed.title) in \(filed.provider.displayName)")
    }

    // MARK: - Compose sheet

    private func sheet(_ provider: IntegrationProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(provider)
            if let draft {
                editor(draft, in: provider)
            } else {
                drafting
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func header(_ provider: IntegrationProvider) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 13)
            Text("New task in \(provider.displayName)")
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(Theme.Palette.ink)
    }

    private var drafting: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reading the meeting…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    @ViewBuilder private func editor(_ current: TaskDraft, in provider: IntegrationProvider) -> some View {
        TextField("Title", text: titleBinding(current))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .focused($titleFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(field)

        TextEditor(text: descriptionBinding(current))
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.ink)
            .scrollContentBackground(.hidden)
            .frame(height: 130)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(field)

        if let match { duplicate(match) }

        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .linkCursor()

            Spacer(minLength: 8)

            if isFiling {
                ProgressView().controlSize(.small)
            }
            // What was discussed decides the verb. A match means the room was
            // talking about work that already exists, and the useful thing to do
            // with what they said is add it to that ticket — so updating is the
            // primary action and creating a second one is the escape hatch.
            if let match {
                Button("Create new") { create(current, in: provider) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                    .disabled(current.title.isEmpty || isFiling)
                    .linkCursor()
                Button("Update \(match.reference.title)") { update(current, to: match) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.cyan)
                    .disabled(isFiling)
                    .linkCursor()
            } else {
                Button("Create") { create(current, in: provider) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(current.title.isEmpty ? Theme.Palette.muted : Theme.Palette.cyan)
                    .disabled(current.title.isEmpty || isFiling)
                    .linkCursor()
            }
        }
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
            .fill(Theme.Palette.surfaceStrong)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .stroke(Theme.Palette.border, lineWidth: 0.5)
            )
    }

    /// The one thing on this sheet that isn't about wording: something matching
    /// is already there, so what the meeting produced is an update to it rather
    /// than a second ticket beside it.
    private func duplicate(_ match: TaskMatch) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderMark(provider: match.reference.provider, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(match.reference.title) already covers this")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(match.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(field)
    }

    private func titleBinding(_ current: TaskDraft) -> Binding<String> {
        Binding(get: { current.title }, set: { draft?.title = $0 })
    }

    private func descriptionBinding(_ current: TaskDraft) -> Binding<String> {
        Binding(get: { current.description }, set: { draft?.description = $0 })
    }

    // MARK: - Actions

    private func compose(in provider: IntegrationProvider) {
        composing = provider
        draft = nil
        match = nil
        failed = false
        // Two independent questions asked at once: the draft is what the task
        // will say, the search is whether it should be a task at all. Serialising
        // them would make the sheet wait for an answer it doesn't need yet.
        Task {
            draft = await composer.draft(for: item)
            titleFocused = true
        }
        Task {
            match = await integrations.existingTask(for: item, in: provider)
        }
    }

    private func dismiss() {
        composing = nil
        draft = nil
        match = nil
    }

    /// Appends the draft to the existing ticket and records the item as filed
    /// there. One gesture, because they are one intent: this meeting's take on
    /// work that already exists, and the row pointing at where it went.
    private func update(_ draft: TaskDraft, to match: TaskMatch) {
        isFiling = true
        Task {
            let note = [draft.title, draft.description]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if await integrations.update(match.reference, note: note) {
                await actionItemStore.recordFiling(itemID: item.id, reference: match.reference)
                dismiss()
            } else {
                failed = true
                dismiss()
            }
            isFiling = false
        }
    }

    private func create(_ draft: TaskDraft, in provider: IntegrationProvider) {
        isFiling = true
        Task {
            if let filed = await integrations.file(draft, in: provider) {
                await actionItemStore.recordFiling(itemID: item.id, reference: filed)
                dismiss()
            } else {
                failed = true
                dismiss()
            }
            isFiling = false
        }
    }
}
