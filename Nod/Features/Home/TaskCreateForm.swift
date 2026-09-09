import SwiftUI

/// The "create a task" outcome, carried out right here — the same composer,
/// dedupe search and filing the checklist's button uses, laid out inline
/// instead of in a popover, so nothing floats over the list and the button
/// that files says what it does in words.
struct TaskCreateForm: View {
    let item: ActionItem
    let onDone: (_ record: String, _ url: URL?) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var composer: TaskDraftComposer

    @State private var tracker: IntegrationProvider?
    @State private var title = ""
    @State private var details = ""
    @State private var match: TaskMatch?
    @State private var people: [ActionDelegation.Person] = []
    @State private var assignee: ActionDelegation.Person?
    @State private var status: LinearStatus = .teamDefault
    @State private var isFiling = false
    @State private var failed = false
    /// The composer is still writing the title and description out of the
    /// discussion — the fields appear when the words do, not before.
    @State private var isDrafting = false
    /// The person saw "already filed" and still wants a second ticket — an
    /// explicit step past the guard, never the default path.
    @State private var creatingAnother = false

    /// The starting column, in the workflow-type words every Linear team
    /// shares. Only Linear takes these on create today, so the picker shows
    /// only there — Jira and Asana file into their defaults, as before.
    enum LinearStatus: String, CaseIterable, Identifiable {
        case teamDefault = ""
        case unstarted
        case started
        case completed

        var id: String {
            rawValue
        }

        var label: String {
            switch self {
            case .teamDefault: "Default"
            case .unstarted: "To do"
            case .started: "In progress"
            case .completed: "Done"
            }
        }
    }

    private var supportsAssignment: Bool {
        tracker == .linear
    }

    private struct PrepareKey: Equatable {
        let tracker: IntegrationProvider?
        let wanted: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineFormHeader("Create a task", onDismiss: onClose)
            if let filed = item.filed, !creatingAnother {
                filedBanner(filed)
            } else {
                form
            }
        }
        // Keyed on the tracker that WILL be used, so seeding the default
        // inside `prepare` does not flip the id and start a second run while
        // the first is still drafting. Nothing runs behind the filed banner.
        .task(id: PrepareKey(tracker: tracker ?? integrations.taskTargets.first, wanted: item.filed == nil || creatingAnother)) {
            await prepare()
        }
    }

    /// This action already became a ticket. Filing again from here is how the
    /// board grows twins, so the door says where the work went and makes a
    /// second ticket an explicit choice.
    private func filedBanner(_ filed: ProviderLinkItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderMark(provider: filed.provider, size: 12)
                Text("Already filed as \(filed.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                GlassPillButton("Open \(filed.title)", size: .compact, trailingIcon: "nc-arrow-up-right") {
                    NSWorkspace.shared.open(filed.url)
                }
                .linkCursor()
                Button("Create another anyway") { creatingAnother = true }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .buttonStyle(.plain)
                    .linkCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .inlineFieldSurface()
    }

    @ViewBuilder private var form: some View {
        if integrations.taskTargets.count > 1 {
            trackerPicker
        }
        if isDrafting {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Drafting the title and description from the discussion…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 18)
            .inlineFieldSurface()
        } else {
            InlineTextField("Title", text: $title, weight: .medium)
            InlineTextEditor(text: $details, minHeight: 48, maxHeight: 100)
        }
        if supportsAssignment {
            HStack(spacing: 10) {
                assigneePicker
                Picker("", selection: $status) {
                    ForEach(LinearStatus.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
        if let match {
            matchRow(match)
        }
        if failed {
            Text("Filing failed — the tracker said no. Try again.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.danger)
        }
        HStack(spacing: 8) {
            GlassPillButton(isFiling ? "Creating…" : "Create in \(tracker?.displayName ?? "tracker")", size: .compact) {
                Task { await create() }
            }
            .linkCursor()
            .disabled(isFiling || isDrafting || tracker == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Files as you, with the meeting as context.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    private func prepare() async {
        guard item.filed == nil || creatingAnother else { return }
        tracker = tracker ?? integrations.taskTargets.first
        if title.isEmpty, !isDrafting {
            isDrafting = true
            defer { isDrafting = false }
            let draft = await composer.draft(for: item)
            guard !Task.isCancelled else { return }
            title = draft.title.isEmpty ? item.text : draft.title
            details = draft.description
        }
        // The dedupe search runs on both phrasings — the transcript's words
        // AND the drafted title — because the existing ticket was created from
        // a draft, and the transcript's words alone let it slip past. The
        // previous tracker's answer is cleared first: a stale twin from Linear
        // has nothing to say about Jira.
        if let tracker {
            match = nil
            let found = await integrations.existingTask(for: item, in: tracker, alsoMatching: title)
            guard !Task.isCancelled else { return }
            match = found
        }
        await loadPeople()
    }

    private func loadPeople() async {
        guard supportsAssignment, people.isEmpty, let tracker else { return }
        let result = await integrations.run(
            ActionDelegation.call(action: "list_users", of: tracker),
            tool: ActionDelegation.tool(action: "list_users", of: tracker),
            origin: .app
        )
        guard !Task.isCancelled else { return }
        people = ActionDelegation.people(in: result).sorted { $0.name < $1.name }
    }

    /// Who picks it up — the tracker's own people, fetched once. "Unassigned"
    /// stays a real choice; nothing is guessed from a name.
    private var assigneePicker: some View {
        Menu {
            Button("Unassigned") { assignee = nil }
            Divider()
            ForEach(people) { person in
                Button(person.name) { assignee = person }
            }
        } label: {
            HStack(spacing: 4) {
                Image("nc-user").icon(10)
                Text(assignee?.name ?? "Unassigned")
                    .font(.system(size: 11.5))
                Image("nc-chevron-down").icon(7)
            }
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(people.isEmpty)
        .help(people.isEmpty ? "Loading people…" : "Assign to a teammate")
    }

    /// Which tracker files it — a choice only when there is one to make, shown
    /// as labelled chips rather than a bare logo nobody knew was a button.
    private var trackerPicker: some View {
        HStack(spacing: 6) {
            ForEach(integrations.taskTargets) { provider in
                Button {
                    tracker = provider
                } label: {
                    HStack(spacing: 5) {
                        ProviderMark(provider: provider, size: 11)
                        Text(provider.displayName)
                    }
                    .font(.system(size: 11.5, weight: tracker == provider ? .semibold : .regular))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tracker == provider ? Theme.Palette.userTurn : Theme.Palette.surfaceStrong)
                    )
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
    }

    /// The dedupe answer: work that may already be tracked, offered as the
    /// alternative to creating a twin.
    private func matchRow(_ match: TaskMatch) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: match.reference.provider, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text("Possible duplicate — \(match.reference.title): \(match.summary)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    .lineLimit(1)
                Text(match.closed ? "Closed" : "Open")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 8)
            Button("Add to it") {
                Task { await update(to: match) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .buttonStyle(.plain)
            .linkCursor()
            .disabled(isFiling)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .inlineFieldSurface()
    }

    private func create() async {
        guard let tracker, !isFiling else { return }
        isFiling = true
        failed = false
        let draft = TaskDraft(title: title.trimmingCharacters(in: .whitespaces), description: details)
        var extra: [String: String] = [:]
        if supportsAssignment {
            if let assignee { extra["assigneeId"] = assignee.id }
            if status != .teamDefault { extra["state"] = status.rawValue }
        }
        if let filed = await integrations.file(draft, in: tracker, extra: extra) {
            await actionItemStore.recordFiling(itemID: item.id, reference: filed)
            let who = assignee.map { " · \($0.name)" } ?? ""
            onDone("Created \(filed.title) in \(tracker.displayName)\(who)", filed.url)
        } else {
            failed = true
        }
        isFiling = false
    }

    private func update(to match: TaskMatch) async {
        guard !isFiling else { return }
        isFiling = true
        failed = false
        let note = [title, details].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if await integrations.update(match.reference, note: note) {
            await actionItemStore.recordFiling(itemID: item.id, reference: match.reference)
            onDone("Added to \(match.reference.title)", match.reference.url)
        } else {
            failed = true
        }
        isFiling = false
    }
}
