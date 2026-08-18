import AppKit
import SwiftUI

/// The cross-meeting action-items screen — its own left-rail destination beside
/// the library, a single checklist of every task pulled from the user's meetings, each tagged
/// with the meeting it came from. Single-user product: no owners/avatars.
/// Flag-only dedup: near-duplicate tasks from different meetings get a "possible
/// duplicate" hint the user resolves by hand (delete one, or dismiss the flag).
struct ActionItemsAggregateView: View {
    /// Active (non-trashed) meetings, for resolving each item's source title and
    /// scoping the list to live meetings.
    let meetings: [Meeting]
    let onOpenMeeting: (UUID) -> Void
    /// It is reached from the attention column's open-actions block, never from
    /// the sidebar, so it carries its own way back.
    let onBack: () -> Void

    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var analytics: ProductAnalytics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [ActionItem] {
        actionItemStore.items
    }

    /// Cached cross-meeting duplicate flags (id → strongest match id) over the
    /// OPEN items. Recomputed via `recomputeFlags()` only when `items`/`dismissed`
    /// change, not on every body read.
    @State private var flagged: [UUID: UUID] = [:]
    @State private var filter: Filter = .open
    @State private var loaded = false
    @State private var dismissed: Set<String> = Dismissals.load()
    /// The task just checked off under the Open filter — where it vanishes from
    /// view — offered for a few seconds as a one-tap Undo so an accidental
    /// completion is easy to take back. Nil when no toast is showing.
    @State private var undoItem: ActionItem?
    @State private var undoToken = UUID()
    /// The item being inline-edited (its text replaced by a field); nil when no
    /// edit is active.
    @State private var editingID: UUID?
    @State private var editingText: String = ""
    @FocusState private var editingFocused: Bool
    /// The meeting whose card is showing an "add task" field; nil when none is.
    @State private var addingMeetingID: UUID?
    @State private var newItemText: String = ""
    @FocusState private var addingFocused: Bool
    /// Row currently under the pointer, so its trailing delete button reveals.
    @State private var hoveredID: UUID?
    @State private var hoveredGroup: UUID?

    /// What a bulk action will act on. Empty is the ordinary state — the bar
    /// only exists while something is selected.
    @State private var search = ""
    /// Sessions folded away. Twenty meetings' worth of tasks is a scroll; the
    /// ones already dealt with should be able to get out of the way.
    @State private var collapsed: Set<UUID> = []

    @State private var selection: Set<UUID> = []
    /// Which tracker the review sheet is filing into, or nil while it's closed.
    @State private var filingInto: IntegrationProvider?

    enum Filter: String, CaseIterable, Identifiable {
        case open = "Open"
        case done = "Done"
        case all = "All"
        var id: String {
            rawValue
        }
    }

    /// Fail OPEN on an unresolved entitlement (nil / load failure), mirroring the
    /// other Pro gates: the feature is granted on trial/Pro, and a Pro user whose
    /// entitlement fetch transiently failed shouldn't be shown the upsell.
    private var canUseActionItems: Bool {
        entitlements.mayUse(.actionItems)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header first in every state: an empty or locked checklist still
            // needs the way back it was opened from.
            header
            if !canUseActionItems {
                upsell
            } else if loaded, !relevantItems.isEmpty {
                list
            } else if loaded {
                emptyState
            } else {
                loadingState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let undoItem {
                undoToast(undoItem)
                    .padding(.bottom, 16)
                    .transition(.edgeSlide(.bottom, reduceMotion: reduceMotion))
            }
        }
        .animation(.momentum(reduceMotion: reduceMotion), value: undoItem?.id)
        .task(id: meetingScopeKey) {
            guard canUseActionItems else { return }
            await load()
            analytics.record(
                .actionItemsViewed,
                properties: .init(
                    entryPoint: .library,
                    surface: .library,
                    contentType: .actionItems,
                    outcome: .viewed
                ),
                oncePerSession: "aggregate"
            )
        }
        .onChange(of: actionItemStore.revision) { _ in recomputeFlags() }
        .onChange(of: dismissed) { _ in recomputeFlags() }
    }

    /// Shown to Starter / locked users in place of the checklist — advertises the
    /// feature and routes to the paywall, matching the cross-meeting "Ask Nod"
    /// upsell.
    private var upsell: some View {
        VStack(spacing: 12) {
            Image("nc-tasks-2")
                .icon(30)
                .foregroundStyle(Theme.Palette.violet)
            Text("Track action items across meetings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text(
                "Nod pulls the to-dos out of every meeting into one checklist you can tick off, with duplicates flagged across sessions. Available on Pro."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.Palette.graphite)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            } label: {
                Text("Upgrade to Pro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private func undoToast(_ item: ActionItem) -> some View {
        HStack(spacing: 10) {
            Image("nc-circle-check")
                .icon(13)
                .foregroundStyle(Theme.Palette.brand)
            Text("Marked done")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 8)
            Button {
                Task { await undo(item) }
            } label: {
                Text("Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            Button {
                dismissUndo()
            } label: {
                Image("nc-xmark")
                    .icon(9)
                    .foregroundColor(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.Palette.bgSoft.opacity(0.85)))
                .overlay(Capsule().stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image("nc-chevron-left")
                    .icon(13)
                    .foregroundStyle(Theme.Palette.muted)
                    .iconButtonChrome()
            }
            .buttonStyle(.plain)
            .help("Back")
            .linkCursor()
            Text("Action Items")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
            if openCount > 0 {
                Text("\(openCount) open")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 8)
            if !relevantItems.isEmpty {
                SearchField(prompt: "Search tasks", text: $search)
                    .frame(maxWidth: 220)
                filterControl
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var filterControl: some View {
        HStack(spacing: 2) {
            ForEach(Filter.allCases) { f in
                let selected = filter == f
                Button {
                    withAnimation(.standard(reduceMotion: reduceMotion)) { filter = f }
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Theme.Palette.surfaceStrong : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groupedItems) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        sectionHeader(group)
                        if !isCollapsed(group.meetingID) {
                            groupCard(group)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 24)
            // Declarative, because checking a row off is an `await` on the store:
            // an imperative `withAnimation` around that call wraps the creation
            // of the Task, and the published change lands a main-actor turn later
            // — outside the transaction, animating nothing.
            .animation(.standard(reduceMotion: reduceMotion), value: visibleItems)
        }
        .scrollContentBackground(.hidden)
        .tooltipContainer()
        .overlay(alignment: .bottom) { selectionBar }
        .animation(.standard(reduceMotion: reduceMotion), value: selection.isEmpty)
        // Escape is what every list on this platform answers with, and the bar
        // has a ✕ for the pointer.
        .onExitCommand { selection = [] }
        // Switching filters changes what the list is about; carrying a
        // selection across that means acting on rows chosen under a different
        // question.
        .onChange(of: filter) { _ in selection = [] }
    }

    private var isFiling: Binding<Bool> {
        Binding(get: { filingInto != nil }, set: { if !$0 { filingInto = nil } })
    }

    /// Per-meeting heading sitting above the group's card, so a session's tasks
    /// stay together and never interleave down the list. Tappable to open the
    /// source meeting; the per-row meeting chip is dropped as redundant.
    private func sectionHeader(_ group: ItemGroup) -> some View {
        // The select-all is a sibling of the title button, not a child of it:
        // nested in the label it would sit inside the hit area that opens the
        // meeting, so selecting a session's tasks would navigate away from them.
        HStack(spacing: 6) {
            Button {
                toggleCollapsed(group.meetingID)
            } label: {
                Image(isCollapsed(group.meetingID) ? "nc-chevron-right" : "nc-chevron-down")
                    .icon(9)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help(isCollapsed(group.meetingID) ? "Show these tasks" : "Fold this session away")

            Button {
                onOpenMeeting(group.meetingID)
            } label: {
                HStack(spacing: 6) {
                    Image(meetingIcon(group.meetingID))
                        .icon(10.5)
                    Text(meetingTitle(group.meetingID))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(group.items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.7)
                }
                .foregroundStyle(Theme.Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this meeting")

            Spacer(minLength: 0)

            // A whole meeting's tasks is the selection people actually want —
            // "everything we agreed in that call, into Linear" — and picking
            // eight rows one command-click at a time is the same intent typed
            // out longhand.
            if hoveredGroup == group.meetingID || isFullySelected(group) {
                Button {
                    toggleGroup(group)
                } label: {
                    Text(isFullySelected(group) ? "Deselect all" : "Select all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .padding(.horizontal, 4)
        .onHover { hovering in
            if hovering { hoveredGroup = group.meetingID }
            else if hoveredGroup == group.meetingID { hoveredGroup = nil }
        }
    }

    /// A search overrides what is folded away: a result you cannot see is the
    /// same as no result, and having to remember which session you folded is
    /// exactly the work searching was meant to replace.
    private func isCollapsed(_ meetingID: UUID) -> Bool {
        search.isEmpty && collapsed.contains(meetingID)
    }

    private func toggleCollapsed(_ meetingID: UUID) {
        withAnimation(.standard(reduceMotion: reduceMotion)) {
            if collapsed.contains(meetingID) { collapsed.remove(meetingID) } else { collapsed.insert(meetingID) }
        }
    }

    private func isFullySelected(_ group: ItemGroup) -> Bool {
        !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) }
    }

    private func toggleGroup(_ group: ItemGroup) {
        let ids = group.items.map(\.id)
        if isFullySelected(group) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    /// A session's tasks in one rounded card; rows separated by inset hairlines
    /// (aligned to the text column), not full-width rules — clean grouping
    /// instead of a ruled-paper look.
    private func groupCard(_ group: ItemGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                row(item)
                if idx < group.items.count - 1 {
                    rowDivider(leading: 41)
                }
            }
            if !group.items.isEmpty {
                rowDivider(leading: 12)
            }
            addRow(group)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    private func rowDivider(leading: CGFloat) -> some View {
        Divider()
            .overlay(Theme.Palette.border.opacity(0.6))
            .padding(.leading, leading)
    }

    /// Card footer: a "+ Add task" affordance that swaps to an inline field,
    /// inserting a user-written task into this session.
    @ViewBuilder
    private func addRow(_ group: ItemGroup) -> some View {
        if addingMeetingID == group.meetingID {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                ActionCheckbox(done: false)
                TextField("New task", text: $newItemText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Palette.ink)
                    .focused($addingFocused)
                    .chatSubmit(text: $newItemText) { Task { await commitAdd(group.meetingID) } }
                    .onExitCommand { cancelAdd() }
                    .onAppear { addingFocused = true }
                fieldButtons(
                    save: { Task { await commitAdd(group.meetingID) } },
                    cancel: { cancelAdd() }
                )
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        } else {
            Button {
                startAdd(group.meetingID)
            } label: {
                HStack(spacing: 9) {
                    Image("nc-plus")
                        .icon(11)
                    Text("Add task")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.Palette.muted)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Save (↩) / cancel (esc) pair shown beside an inline edit or add field.
    private func fieldButtons(save: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: save) {
                Image("nc-check")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.brand)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Save (↩)")
            Button(action: cancel) {
                Image("nc-xmark")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Cancel (esc)")
        }
    }

    // MARK: - Row

    private func row(_ item: ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            ActionCheckbox(done: item.done)
                .onTapGesture { Task { await toggle(item) } }
            VStack(alignment: .leading, spacing: 5) {
                if editingID == item.id {
                    editor(item)
                } else {
                    Text(item.text)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(item.done ? Theme.Palette.muted : Theme.Palette.ink.opacity(0.92))
                        .strikethrough(item.done, color: Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { startEdit(item) }
                    if hasMeta(item) {
                        HStack(spacing: 6) {
                            if let deadline = item.deadline, !deadline.isEmpty {
                                let spoken = spokenAt(item)
                                DeadlinePill(
                                    display: ActionItemDeadline.display(phrase: deadline, spokenAt: spoken),
                                    spokenAt: spoken,
                                    meetingTitle: meetingTitle(item.meetingID),
                                    compact: true,
                                    done: item.done
                                )
                            }
                            if flagged[item.id] != nil {
                                duplicatePill(for: item)
                            }
                        }
                    }
                }
            }
            // Reserve the trailing zone the hover delete button occupies, so a
            // long task never wraps under it (kept always, to avoid reflow on
            // hover).
            Spacer(minLength: 62)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) { rowActions(item) }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.violet.opacity(selection.contains(item.id) ? 0.16 : 0))
                .padding(.horizontal, 4)
        )
        .onHover { hovering in
            if hovering { hoveredID = item.id }
            else if hoveredID == item.id { hoveredID = nil }
        }
        // Command-click selects, the way a list on this platform has always
        // selected — and the bar it raises is what teaches the rest.
        .highPriorityGesture(
            TapGesture().modifiers(.command).onEnded { toggleSelected(item.id) }
        )
        .contextMenu { rowMenu(item) }
    }

    private func toggleSelected(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// What is selected, and the one button that acts on it.
    ///
    /// One "Actions" menu rather than a row of buttons: the list of things you
    /// can do to a task grows with every integration Nod connects, and a bar
    /// that spends a button on each runs out of bar. The count is the other
    /// half — a bulk action with no statement of what it will touch is how you
    /// complete forty tasks by accident.
    @ViewBuilder
    private var selectionBar: some View {
        // Against what is on screen, not against the set: checking a row off
        // under Open takes it out of the list, and a bar still counting it
        // would offer to act on something the person can no longer see.
        let selected = visibleItems.filter { selection.contains($0.id) }
        if !selected.isEmpty {
            HStack(spacing: 10) {
                Text("\(selected.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)

                Menu {
                    if selected.contains(where: { !$0.done }) {
                        Button {
                            Task { await completeSelected(true) }
                        } label: {
                            IconLabel(title: "Mark done", icon: "nc-check")
                        }
                    }
                    if selected.contains(where: \.done) {
                        Button {
                            Task { await completeSelected(false) }
                        } label: {
                            IconLabel(title: "Mark not done", icon: "nc-arrow-up-right")
                        }
                    }
                    let unfiled = selected.filter { !$0.isFiled }
                    if !unfiled.isEmpty, !integrations.taskTargets.isEmpty {
                        Divider()
                        ForEach(integrations.taskTargets) { provider in
                            Button {
                                filingInto = provider
                            } label: {
                                IconLabel(
                                    title: "Send \(unfiled.count) to \(provider.displayName)",
                                    icon: provider.iconName
                                )
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { await deleteSelected() }
                    } label: {
                        IconLabel(title: "Not actions", icon: "nc-xmark")
                    }
                } label: {
                    Text("Actions")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    selection = []
                } label: {
                    Image("nc-xmark")
                        .icon(9)
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
                .help("Clear selection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
                    .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            )
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .popover(isPresented: isFiling, arrowEdge: .top) {
                if let provider = filingInto {
                    BulkFilingSheet(
                        items: selected.filter { !$0.isFiled },
                        provider: provider,
                        onFinish: {
                            filingInto = nil
                            selection = []
                        }
                    )
                }
            }
        }
    }

    private func completeSelected(_ done: Bool) async {
        let targets = visibleItems.filter { selection.contains($0.id) && $0.done != done }
        selection = []
        // A single undo toast can only speak for one row, and forty rows
        // vanishing behind one "Undo" would promise something it can't keep.
        clearUndo()
        for item in targets {
            await actionItemStore.setDone(done, itemID: item.id)
        }
    }

    private func deleteSelected() async {
        let targets = visibleItems.filter { selection.contains($0.id) }
        selection = []
        clearUndo()
        for item in targets {
            await actionItemStore.softDelete(itemID: item.id)
        }
    }

    /// Top-aligned, so the save/cancel pair stays put on the first line as the
    /// field grows instead of riding its baseline down the row.
    private func editor(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Vertical axis so a two-line task stays fully visible while it's
            // edited — a single-line field scrolls the sentence out of view
            // exactly when you need to read it.
            TextField("Task", text: $editingText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink)
                .focused($editingFocused)
                .chatSubmit(text: $editingText) { Task { await commitEdit(item) } }
                .onExitCommand { cancelEdit() }
                .onAppear {
                    editingFocused = true
                    placeCaretAtEnd()
                }
            fieldButtons(
                save: { Task { await commitEdit(item) } },
                cancel: { cancelEdit() }
            )
        }
    }

    /// The row's trailing slot: where this went, and what can be done with it.
    private func rowActions(_ item: ActionItem) -> some View {
        let hovering = hoveredID == item.id && editingID != item.id
        // A filed item shows its reference whether or not the pointer is there
        // — that one is information, not an affordance.
        let show = hovering || item.isFiled
        return HStack(spacing: 6) {
            ActionItemFilingButton(item: item)
            deleteButton(item)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.trailing, 10)
        .opacity(show ? 1 : 0)
        .allowsHitTesting(show)
        .animation(.easeInOut(duration: 0.12), value: show)
    }

    private func deleteButton(_ item: ActionItem) -> some View {
        Button {
            Task { await delete(item) }
        } label: {
            Image("nc-xmark")
                .icon(11)
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        // "Not an action", not "Delete": these rows are extractions, and the
        // common reason one goes is that the model heard a commitment where
        // there wasn't one. Naming it a deletion asks the user to think of this
        // as their task list, which is the reading the product is moving away
        // from.
        .help("Not an action")
    }

    @ViewBuilder
    private func rowMenu(_ item: ActionItem) -> some View {
        Button {
            startEdit(item)
        } label: {
            IconLabel(title: "Edit", icon: "nc-pen-writing")
        }
        Button {
            onOpenMeeting(item.meetingID)
        } label: {
            IconLabel(title: "Open meeting", icon: "nc-arrow-up-right")
        }
        if let matchID = flagged[item.id] {
            Button {
                dismissDuplicate(item.id, matchID)
            } label: {
                IconLabel(title: "Not a duplicate", icon: "nc-check")
            }
        }
        Divider()
        Button(role: .destructive) {
            Task { await delete(item) }
        } label: {
            IconLabel(title: "Not an action", icon: "nc-xmark")
        }
    }

    private func duplicatePill(for item: ActionItem) -> some View {
        HStack(spacing: 3) {
            Image("nc-files-2")
                .icon(8)
            Text("Possible duplicate")
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(Theme.Palette.warning)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.Palette.warning.opacity(0.12)))
        .hoverTooltip(duplicateHelp(for: item), icon: "nc-files-2")
    }

    // MARK: - States

    private var searchEmptyTitle: String {
        if !search.isEmpty { return "Nothing matches “\(search)”" }
        return filter == .open ? "No open action items." : "No action items yet."
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image("nc-tasks-2")
                .icon(34)
                .foregroundStyle(Theme.Palette.muted)
            Text(searchEmptyTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            if search.isEmpty {
                Text("Tasks Nod pulls from your meetings show up here, with a checkbox each.")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .multilineTextAlignment(.center)
            } else {
                Button {
                    search = ""
                } label: {
                    Text("Clear search")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.brand)
                }
                .buttonStyle(.plain)
            }
            if search.isEmpty, filter != .all, !relevantItems.isEmpty {
                Button {
                    withAnimation(.standard(reduceMotion: reduceMotion)) { filter = .all }
                } label: {
                    Text("Show all")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.brand)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var loadingState: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    private var activeMeetingIDs: Set<UUID> {
        Set(meetings.map(\.id))
    }

    /// Items whose meeting is still active (have a title, not trashed).
    private var relevantItems: [ActionItem] {
        items.filter { activeMeetingIDs.contains($0.meetingID) }
    }

    /// Matched against the task's own words and the title of the session it came
    /// from, so "standup" finds everything that meeting produced without anyone
    /// having to remember how a task was worded.
    private func matchesSearch(_ item: ActionItem) -> Bool {
        guard !search.isEmpty else { return true }
        return item.text.localizedCaseInsensitiveContains(search)
            || meetingTitle(item.meetingID).localizedCaseInsensitiveContains(search)
    }

    private var visibleItems: [ActionItem] {
        relevantItems.filter { item in
            guard matchesSearch(item) else { return false }
            return switch filter {
            case .open: !item.done
            case .done: item.done
            case .all: true
            }
        }
    }

    struct ItemGroup: Identifiable {
        let meetingID: UUID
        let items: [ActionItem]
        var id: UUID {
            meetingID
        }
    }

    /// Visible items bucketed by source meeting, groups ordered by the meeting's
    /// own recency (`meetings` is already newest-first) and rows within a group
    /// by `position`. Keying off the meeting — not item `created_at` — keeps a
    /// session's tasks contiguous AND stops a freshly user-added task (which
    /// carries the newest timestamp) from hoisting its whole, possibly old,
    /// meeting group to the top of the list on the next reload.
    private var groupedItems: [ItemGroup] {
        let buckets = Dictionary(grouping: visibleItems, by: \.meetingID)
        return meetings.compactMap { meeting in
            guard let group = buckets[meeting.id], !group.isEmpty else { return nil }
            return ItemGroup(meetingID: meeting.id, items: group.sorted { $0.order < $1.order })
        }
    }

    private func hasMeta(_ item: ActionItem) -> Bool {
        if let deadline = item.deadline, !deadline.isEmpty { return true }
        return flagged[item.id] != nil
    }

    private var openCount: Int {
        relevantItems.lazy.filter { !$0.done }.count
    }

    /// Recompute the duplicate-flag map. `ActionItemDedup.flag` is O(n²); keeping
    /// the result in `@State` (recomputed only when `items`/`dismissed` change)
    /// avoids rerunning the full pairwise scan on every `flagged[...]` read —
    /// each rendered row touches it several times, so a computed property turned
    /// one body pass into O(rows × n²) and visibly janked large lists.
    private func recomputeFlags() {
        flagged = ActionItemDedup.flag(relevantItems.filter { !$0.done }, dismissed: dismissed)
    }

    /// Every row asks for its meeting's title, icon, and date, so a linear scan
    /// per lookup is O(rows × meetings) on each body pass.
    private var meetingsByID: [UUID: Meeting] {
        Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func meetingTitle(_ id: UUID) -> String {
        guard let meeting = meetingsByID[id] else { return "Meeting" }
        return meeting.displayTitle(dateFormatter: Self.dateFormatter)
    }

    private func meetingIcon(_ id: UUID) -> String {
        meetingsByID[id]?.kind.icon ?? "nc-calendar"
    }

    /// The day a deadline phrase was spoken — what "end of week" was relative
    /// to. Falls back to the row's own creation date for a user-added task or a
    /// meeting that's no longer in scope.
    private func spokenAt(_ item: ActionItem) -> Date {
        meetingsByID[item.meetingID]?.startedAt ?? item.createdAt ?? Date()
    }

    private func duplicateHelp(for item: ActionItem) -> String {
        guard let matchID = flagged[item.id],
              let match = items.first(where: { $0.id == matchID }) else {
            return "Looks similar to another action item."
        }
        return "Looks similar to a task from \(meetingTitle(match.meetingID)). Right-click to delete one or dismiss."
    }

    // Re-runs the loader whenever the active meeting set changes (e.g. after
    // refresh) so the list stays in sync without a manual reload.
    private var meetingScopeKey: String {
        meetings.map(\.id.uuidString).joined()
    }

    // MARK: - Actions

    private func load() async {
        // Backfills any active meeting whose recap actions were never promoted
        // (finalized offline, or whose finalize save raced and lost) so the
        // global list is complete without opening each meeting first.
        await actionItemStore.promoteMissing(in: meetings)
        loaded = true
        recomputeFlags()
    }

    // MARK: Inline edit

    /// AppKit selects the entire string when a field editor takes focus, which
    /// on an inline rename reads as "one keystroke wipes this task". Drop the
    /// caret at the end instead — the user opened an edit, not a replace.
    private func placeCaretAtEnd() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func startEdit(_ item: ActionItem) {
        cancelAdd()
        editingText = item.text
        editingID = item.id
    }

    private func cancelEdit() {
        editingID = nil
    }

    private func commitEdit(_ item: ActionItem) async {
        guard editingID == item.id else { return }
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        guard !text.isEmpty, text != item.text else { return }
        await actionItemStore.updateText(text, itemID: item.id)
    }

    // MARK: Add task

    private func startAdd(_ meetingID: UUID) {
        cancelEdit()
        newItemText = ""
        addingMeetingID = meetingID
    }

    private func cancelAdd() {
        addingMeetingID = nil
        newItemText = ""
    }

    private func commitAdd(_ meetingID: UUID) async {
        let text = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelAdd(); return }
        let position = (items.filter { $0.meetingID == meetingID }.compactMap(\.position).max() ?? -1) + 1
        await actionItemStore.add(text: text, meetingID: meetingID, position: position)
        cancelAdd()
    }

    private func toggle(_ item: ActionItem) async {
        let target = !item.done
        // Checking off under Open makes the row disappear — offer a quick Undo
        // so an accidental tap is reversible without hunting through filters.
        if target, filter == .open {
            presentUndo(item)
        } else if !target {
            // Manually unchecking is itself the undo — drop any stale toast.
            clearUndo()
        }
        Task { await actionItemStore.setDone(target, itemID: item.id) }
    }

    private func presentUndo(_ item: ActionItem) {
        undoItem = item
        let token = UUID()
        undoToken = token
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if undoToken == token, undoItem?.id == item.id {
                withAnimation(.momentum(reduceMotion: reduceMotion)) { undoItem = nil }
            }
        }
    }

    private func clearUndo() {
        undoToken = UUID()
        undoItem = nil
    }

    private func dismissUndo() {
        withAnimation(.momentum(reduceMotion: reduceMotion)) { clearUndo() }
    }

    private func undo(_ item: ActionItem) async {
        clearUndo()
        await actionItemStore.setDone(false, itemID: item.id)
    }

    private func delete(_ item: ActionItem) async {
        // Drop a pending "Marked done" toast for this row — otherwise Undo would
        // fire against a now soft-deleted item (a no-op write + a stale toast).
        if undoItem?.id == item.id { clearUndo() }
        await actionItemStore.softDelete(itemID: item.id)
    }

    private func dismissDuplicate(_ a: UUID, _ b: UUID) {
        dismissed.insert(ActionItemDedup.pairKey(a, b))
        Dismissals.save(dismissed)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Persisted "not a duplicate" pair keys (see `ActionItemDedup.pairKey`). Local
/// to the device — a dismissed flag is a UI preference, not synced data.
private enum Dismissals {
    private static let key = "actionItems.dedup.dismissed"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: key)
    }
}
