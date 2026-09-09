import AppKit
import SwiftUI

/// Where a meeting's proposals stand, read off the rows rather than remembered.
///
/// One value for the whole meeting rather than a status per card: the person
/// answers the batch once, and the surface has to move as one — from asking,
/// to filing, to done — or the third "Approve" in a row is pressed unread.
enum ReadyToFilePhase: Equatable {
    case nothing
    /// Waiting on the person: the offers, and anything that failed last time
    /// and will be tried again with them.
    case review([ActionProposal])
    /// Approved and on its way, or stranded between approval and execution.
    case running([ActionProposal])
    /// Everything filed, this session.
    case done([ActionProposal])

    /// - Parameters:
    ///   - items: the meeting's action items, so an offer for a row that has
    ///     since been ticked, deleted or filed by hand is dropped rather than
    ///     shown. An offer whose row is not loaded is kept — a missing row is
    ///     a load in flight, not a decision.
    static func of(_ proposals: [ActionProposal], items: [ActionItem]) -> ReadyToFilePhase {
        let rows = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let relevant = proposals.filter { proposal in
            guard let itemID = proposal.actionItemID, let item = rows[itemID] else { return true }
            if proposal.status == .completed { return true }
            return !item.done && item.deletedAt == nil && !item.isFiled
        }
        let statuses = Set(relevant.map(\.status))
        let hasAwaiting = !statuses.isDisjoint(with: ActionProposal.Status.awaiting)
        let hasMoving = statuses.contains(.approved) || statuses.contains(.executing)
        // In the order the offers were made, whatever each is doing now: a row
        // that jumped to the bottom on completion is a list nobody can follow.
        if hasMoving {
            return .running(relevant.filter { $0.status != .rejected && !ActionProposal.Status.awaiting.contains($0.status) })
        }
        if hasAwaiting {
            return .review(relevant.filter { ActionProposal.Status.awaiting.contains($0.status) || $0.status == .failed })
        }
        if statuses.contains(.failed) {
            return .running(relevant.filter { $0.status == .failed || $0.status == .completed })
        }
        if statuses.contains(.completed) {
            return .done(relevant.filter { $0.status == .completed })
        }
        return .nothing
    }
}

/// What the meeting is offering to do, and then what it did.
///
/// Shown under the recap rather than as a dialog when the meeting ends. A modal
/// arrives while the user is still standing up from the call, and a decision
/// taken to dismiss a modal is not a decision — it is the reflex this whole
/// confirm-before-acting design exists to avoid.
///
/// Draws nothing at all when there is nothing outstanding, which is every
/// meeting for a user who has connected no tracker.
struct ReadyToFileCard: View {
    let meetingID: UUID
    /// The notch's density. Same rows, smaller type, no editing.
    var isCompact = false
    /// "View in Nod" from the notch; nil where the card already is in Nod.
    var onOpen: (() -> Void)?

    @EnvironmentObject private var proposals: ActionProposalStore
    @EnvironmentObject private var actionItems: ActionItemStore
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var meetingStore: MeetingStore

    @State private var titles: [UUID: String] = [:]
    @State private var isDeciding = false
    @State private var isUndoing = false
    @State private var isConfirmingUndo = false
    /// The row whose inline form (a message, an event, a note) is open.
    @State private var expanded: UUID?
    /// The review list as it stood when "Set it up" was pressed, held until
    /// every approval has landed — otherwise the first row to be approved
    /// flips the card to "Setting things up" with the rest of the batch gone.
    @State private var held: [ActionProposal]?
    @State private var problem: String?

    /// Another card on the same store — the notch beside the window — may be
    /// running the batch; its queued rows are not this card's to retry.
    private var isBatchExecuting: Bool {
        proposals.proposals(forMeeting: meetingID).contains { $0.status == .executing }
    }

    /// The batch is tasks only: those are what one press can file. A message,
    /// an event or a note waits on the person for its missing piece, so it
    /// sits in its own group below, whatever the batch is doing.
    private var taskRows: [ActionProposal] {
        proposals.proposals(forMeeting: meetingID).filter { Self.isBatchable($0) }
    }

    private var manualRows: [ActionProposal] {
        let items = actionItems.items(forMeeting: meetingID)
        return proposals.proposals(forMeeting: meetingID).filter {
            !Self.isBatchable($0) && ActionProposal.Status.awaiting.contains($0.status)
                && ReadyToFilePhase.of([$0], items: items) != .nothing
        }
    }

    static func isBatchable(_ proposal: ActionProposal) -> Bool {
        (ActionVerb.of(type: proposal.type) ?? .task) == .task
    }

    private var phase: ReadyToFilePhase {
        if let held { return .review(held) }
        return ReadyToFilePhase.of(taskRows, items: actionItems.items(forMeeting: meetingID))
    }

    var body: some View {
        let manual = manualRows
        Group {
            switch phase {
            case .nothing:
                if !manual.isEmpty {
                    card(head: "For you to send", icon: "nc-paper-plane-2", tint: Theme.Palette.brand, count: manual.count) {
                        ForEach(manual) { proposal in reviewRow(proposal) }
                    }
                }
            case let .review(list):
                card(head: "Ready to file", icon: "nc-paper-plane-2", tint: Theme.Palette.brand, count: list.count) {
                    ForEach(list) { proposal in reviewRow(proposal) }
                    reviewActions(list)
                    manualGroup(manual)
                }
            case let .running(list):
                card(head: "Setting things up", icon: "nc-wand-sparkle", tint: Theme.Palette.brand) {
                    ForEach(list) { proposal in progressRow(proposal) }
                    manualGroup(manual)
                }
            case let .done(list):
                card(head: "Everything is ready", icon: "nc-shield-check", tint: Theme.Palette.success) {
                    ForEach(list) { proposal in doneRow(proposal) }
                    doneActions(list)
                    manualGroup(manual)
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: phase)
    }

    @ViewBuilder
    private func manualGroup(_ manual: [ActionProposal]) -> some View {
        if !manual.isEmpty {
            VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
                SectionLabel("For you to send", size: .compact)
                ForEach(manual) { proposal in reviewRow(proposal) }
            }
            .padding(.top, 4)
        }
    }

    private func card(
        head: String,
        icon: String,
        tint: Color,
        count: Int? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            HStack(spacing: 6) {
                Image(icon)
                    .icon(isCompact ? 11 : 12)
                    .foregroundStyle(tint)
                Text(head)
                    .font(.system(size: isCompact ? 11.5 : 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                if let count {
                    Text("\(count)")
                        .font(.system(size: isCompact ? 10.5 : 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            content()
            if let problem {
                Text(problem)
                    .font(metaFont)
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(isCompact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .opacity(isDeciding || isUndoing ? 0.6 : 1)
        .disabled(isDeciding || isUndoing)
    }

    private var rowFont: Font {
        .system(size: isCompact ? 11.5 : 13, weight: .medium)
    }

    private var metaFont: Font {
        .system(size: isCompact ? 10.5 : 11)
    }

    private func reviewRow(_ proposal: ActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            reviewLine(proposal)
            if expanded == proposal.id, !isCompact, let item = item(of: proposal) {
                inlineForm(for: proposal, item: item)
            }
        }
    }

    private func item(of proposal: ActionProposal) -> ActionItem? {
        guard let itemID = proposal.actionItemID else { return nil }
        return actionItems.items(forMeeting: meetingID).first { $0.id == itemID }
    }

    private func reviewLine(_ proposal: ActionProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            verbChip(proposal)
            VStack(alignment: .leading, spacing: 3) {
                if isCompact || !Self.isBatchable(proposal) {
                    Text(proposal.headline)
                        .font(rowFont)
                        .foregroundStyle(Theme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Editable in place. A ticket is read by somebody with none
                    // of the meeting in their head, and the person approving is
                    // the only one who has both — asking them to accept or
                    // reject a sentence they cannot fix would make "reject" the
                    // answer to a wording problem.
                    TextField("Task title", text: titleBinding(proposal))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(rowFont)
                        .foregroundStyle(Theme.Palette.ink)
                }
                if let draftedBy = draftedBy(proposal) {
                    Text("Drafted by \(draftedBy)")
                        .font(metaFont)
                        .foregroundStyle(Theme.Palette.muted)
                }
                // The words that will be in the ticket, shown before they
                // go: an approval covers what is sent, not just the title.
                if let quote = quote(of: proposal) {
                    Text("“\(quote)”")
                        .font(metaFont)
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(isCompact ? 1 : 2)
                }
                owner(of: proposal)
                if proposal.status == .failed, let failure = proposal.failureMessage {
                    Text(failure)
                        .font(metaFont)
                        .foregroundStyle(Theme.Palette.warning)
                        .lineLimit(2)
                }
                if let verb = ActionVerb.of(type: proposal.type), verb != .task {
                    // Not filed by the batch: who it goes to, or when, is the
                    // person's to say, in the form the row opens.
                    if isCompact {
                        if let onOpen {
                            Button(Self.prompt(for: verb) + " in Nod", action: onOpen)
                                .buttonStyle(.plain)
                                .font(metaFont.weight(.semibold))
                                .foregroundStyle(Theme.Palette.cyan)
                                .linkCursor()
                        }
                    } else if expanded != proposal.id {
                        Button(Self.prompt(for: verb)) { expanded = proposal.id }
                            .buttonStyle(.plain)
                            .font(metaFont.weight(.semibold))
                            .foregroundStyle(Theme.Palette.cyan)
                            .linkCursor()
                            .disabled(item(of: proposal) == nil)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { skip(proposal) } label: {
                Image("nc-xmark")
                    .icon(9)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Skip this one")
        }
    }

    /// Who this is for, or the question that stands in for an answer.
    ///
    /// Never a percentage. A number reads as a precision the measurement does
    /// not have, and nobody has ever acted differently on 0.74 than on 0.68.
    @ViewBuilder
    private func owner(of proposal: ActionProposal) -> some View {
        if let assignee = proposal.parameters["assignee_name"] {
            Text("For \(assignee)")
                .font(metaFont)
                .foregroundStyle(Theme.Palette.muted)
        } else if let hint = proposal.parameters["assignee_hint"], ActionProposal.Status.awaiting.contains(proposal.status) {
            // The name as it was said, still unresolved — and a way to resolve
            // it, because a warning the user cannot act on is just a worse
            // version of saying nothing. Left unanswered, the task is filed
            // without an owner and the name rides along in its description.
            // A failed row is past editing on the server, so it only shows.
            Menu {
                ForEach(candidates(for: proposal)) { person in
                    Button(person.name) { assign(person, to: proposal) }
                }
                if candidates(for: proposal).isEmpty {
                    Text("Nobody in your connected tools matches")
                }
            } label: {
                Label("Who is \(hint)?", image: "nc-triangle-warning")
                    .labelStyle(.titleAndIcon)
                    .font(metaFont)
                    .foregroundStyle(Theme.Palette.warning)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else if let hint = proposal.parameters["assignee_hint"] {
            Text("Owner as said: \(hint)")
                .font(metaFont)
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    /// What will happen to this row, as a verb wearing its product's mark.
    /// The menu lists verbs, not products: two hundred integrations are still
    /// four things to do with a commitment, and which product carries each is
    /// a default the person set once.
    private func verbChip(_ proposal: ActionProposal) -> some View {
        let verb = ActionVerb.of(type: proposal.type) ?? .task
        let choices = ActionVerb.allCases.filter { !integrations.carriers(of: $0).isEmpty }
        return Menu {
            ForEach(choices) { choice in
                let carriers = integrations.carriers(of: choice)
                if carriers.count == 1, let only = carriers.first {
                    Button { retype(proposal, to: choice, in: only) } label: {
                        IconLabel(title: "\(choice.title) in \(only.displayName)", icon: only.iconName)
                    }
                } else {
                    Menu(choice.title) {
                        ForEach(carriers) { carrier in
                            Button { retype(proposal, to: choice, in: carrier) } label: {
                                IconLabel(title: "in \(carrier.displayName)", icon: carrier.iconName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let provider = proposal.provider {
                    ProviderMark(provider: provider, size: isCompact ? 11 : 12)
                }
                Text(verb.title)
                    .font(metaFont.weight(.medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(choices.count <= 1 && ActionVerb.of(type: proposal.type) == choices.first)
        .help("What should happen to this")
    }

    static func prompt(for verb: ActionVerb) -> String {
        switch verb {
        case .task: "File it"
        case .message: "Write the message"
        case .event: "Pick a time"
        case .note: "Log the note"
        }
    }

    @ViewBuilder
    private func inlineForm(for proposal: ActionProposal, item: ActionItem) -> some View {
        let verb = ActionVerb.of(type: proposal.type)
        let provider = proposal.provider
        switch (verb, provider) {
        case let (.message, .some(messenger)):
            DelegateForm(
                item: item,
                messenger: messenger,
                ambientHints: [],
                initialMessage: ActionDelegation.draft(for: item, source: sourceTitle),
                onDone: {
                    settle(proposal, record: ActionDelegation.recorded(for: item.id) ?? "Sent", url: nil)
                },
                onCancel: { expanded = nil }
            )
        case (.event, .some):
            CalendarEventForm(
                item: item,
                kind: .meeting,
                onDone: { record, url in settle(proposal, record: record, url: url) },
                onClose: { expanded = nil }
            )
        case let (.note, .some(crm)):
            CRMNoteForm(
                item: item,
                crm: crm,
                initialBody: noteBody(for: item),
                onDone: { record, url in settle(proposal, record: record, url: url) },
                onCancel: { expanded = nil }
            )
        default:
            EmptyView()
        }
    }

    private var sourceTitle: String? {
        meetingStore.byID[meetingID]?.displayTitle(dateFormatter: Meeting.shortDateFormatter)
    }

    private func noteBody(for item: ActionItem) -> String {
        guard let meeting = meetingStore.byID[meetingID] else { return item.text }
        let source = ProposalRaiser.source(for: meeting)
        let footer = FiledTaskFooter.text(
            meetingTitle: source.meetingTitle,
            meetingDate: source.meetingDate,
            quote: item.evidenceQuote,
            link: source.link
        )
        return FiledTaskFooter.appended(to: item.text, footer: footer)
    }

    /// The form did the write and confirmed it; the offer is answered with
    /// what came back, never declined.
    private func settle(_ proposal: ActionProposal, record: String, url: URL?) {
        expanded = nil
        let reference = url.flatMap { url in
            proposal.provider.map { ProviderLinkItem(provider: $0, title: record, url: url) }
        }
        Task {
            if await !proposals.settle(proposal, reference: reference, record: record) {
                problem = proposals.lastError
            }
        }
    }

    /// The person picked another verb by hand. Remembered per kind of item,
    /// so the third such pick becomes the default the next meeting drafts.
    private func retype(_ proposal: ActionProposal, to verb: ActionVerb, in provider: IntegrationProvider) {
        guard !isDeciding, let item = item(of: proposal), let meeting = meetingStore.byID[meetingID] else { return }
        let current = ActionVerb.of(type: proposal.type)
        guard verb != current || provider != proposal.provider else { return }
        // The owner the meeting named rides along whatever the verb becomes;
        // a redraft is not a reason to forget who the room said.
        let owner = proposal.parameters["assignee_name"] ?? proposal.parameters["assignee_hint"]
        guard var draft = ProposalDrafting.redraft(
            item,
            verb: verb,
            provider: provider,
            owner: owner,
            directory: organizations.people,
            source: ProposalRaiser.source(for: meeting)
        ) else { return }
        if let edited = titles[proposal.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty {
            draft.parameters["title"] = edited
        }
        isDeciding = true
        expanded = nil
        titles.removeValue(forKey: proposal.id)
        Task {
            defer { isDeciding = false }
            problem = nil
            if await proposals.retype(proposal, to: draft) {
                if verb != current { VerbMemory().note(verb, for: item.kind) }
            } else {
                problem = proposals.lastError
            }
        }
    }

    private func quote(of proposal: ActionProposal) -> String? {
        guard let itemID = proposal.actionItemID,
              let item = actionItems.items(forMeeting: meetingID).first(where: { $0.id == itemID }),
              let quote = item.evidenceQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quote.isEmpty else { return nil }
        return quote.count > FiledTaskFooter.quoteLimit ? String(quote.prefix(FiledTaskFooter.quoteLimit)) + "…" : quote
    }

    /// Who prepared this, when it wasn't the meeting pipeline. Authorship on
    /// the card is what makes an agent's work answerable — and correctable.
    private func draftedBy(_ proposal: ActionProposal) -> String? {
        guard let agentID = proposal.raisedByAgent else { return nil }
        return agents.agents.first { $0.id == agentID }?.title ?? "an agent"
    }

    /// Who this can be handed to: everybody the organization knows about,
    /// reachable in the product this proposal targets. Somebody Nod cannot find
    /// there is not an assignee — offering them would only move the failure to
    /// after the approval.
    private func candidates(for proposal: ActionProposal) -> [Person] {
        guard let provider = proposal.provider else { return [] }
        return organizations.people.filter { $0.isReachable(in: provider) }
    }

    private func reviewActions(_ list: [ActionProposal]) -> some View {
        HStack(spacing: 8) {
            GlassPillButton(isDeciding ? "Setting up…" : "Set it up", size: .compact, isLoading: isDeciding) {
                setUp(list)
            }
            SecondaryPillButton("Not this time", isSelected: false) { skipAll(list) }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func progressRow(_ proposal: ActionProposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let provider = proposal.provider {
                ProviderMark(provider: provider, size: isCompact ? 12 : 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(proposal.headline)
                        .font(rowFont)
                        .foregroundStyle(proposal.status == .completed ? Theme.Palette.ink : Theme.Palette.muted)
                        .lineLimit(2)
                    switch proposal.status {
                    case .completed:
                        Image("nc-circle-check")
                            .icon(10)
                            .foregroundStyle(Theme.Palette.success)
                            .transition(.scale.combined(with: .opacity))
                    case .failed:
                        Image("nc-triangle-warning")
                            .icon(10)
                            .foregroundStyle(Theme.Palette.warning)
                    default:
                        ThreeBalls(diameter: 3, color: Theme.Palette.muted)
                    }
                }
                switch proposal.status {
                case .completed:
                    if let key = proposal.externalKey {
                        Text(key)
                            .font(metaFont)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                case .approved where isBatchExecuting:
                    Text("Queued")
                        .font(metaFont)
                        .foregroundStyle(Theme.Palette.muted)
                case .failed, .approved:
                    // `approved` and not running is where a crash between the
                    // two calls leaves a row. The decision was taken; only the
                    // running is owed, so the offer is to run it, not to ask
                    // again.
                    HStack(spacing: 8) {
                        if let failure = proposal.failureMessage {
                            Text(failure)
                                .font(metaFont)
                                .foregroundStyle(Theme.Palette.warning)
                                .lineLimit(2)
                        }
                        Button("Try again") { retry(proposal) }
                            .buttonStyle(.plain)
                            .font(metaFont.weight(.semibold))
                            .foregroundStyle(Theme.Palette.cyan)
                            .linkCursor()
                        Button("Skip") { skip(proposal) }
                            .buttonStyle(.plain)
                            .font(metaFont)
                            .foregroundStyle(Theme.Palette.muted)
                            .linkCursor()
                    }
                default:
                    Text("Filing…")
                        .font(metaFont)
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: proposal.status)
    }

    @ViewBuilder
    private func doneRow(_ proposal: ActionProposal) -> some View {
        if let reference = Self.reference(of: proposal) {
            ProviderLink(item: reference, style: isCompact ? .compact : .reference)
        }
    }

    /// Undo closes tickets other people may already be looking at, so it is
    /// the one control here that asks twice.
    private func doneActions(_ list: [ActionProposal]) -> some View {
        HStack(spacing: 8) {
            if let onOpen {
                SecondaryPillButton("View in Nod", isSelected: false, action: onOpen)
            }
            if isConfirmingUndo {
                Text("Close \(list.count == 1 ? "this ticket" : "these \(list.count) tickets")?")
                    .font(metaFont)
                    .foregroundStyle(Theme.Palette.muted)
                InlineConfirmButtons(
                    confirmIcon: "nc-check",
                    confirmHelp: "Close the tickets and take the tasks back",
                    cancelHelp: "Keep them",
                    onConfirm: { isConfirmingUndo = false; undo(list) },
                    onCancel: { isConfirmingUndo = false }
                )
            } else {
                SecondaryPillButton(isUndoing ? "Undoing…" : "Undo", isSelected: false) { isConfirmingUndo = true }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    static func reference(of proposal: ActionProposal) -> ProviderLinkItem? {
        guard let provider = proposal.externalProvider.flatMap(IntegrationProvider.init(rawValue:)) ?? proposal.provider,
              let key = proposal.externalKey,
              let raw = proposal.externalURL,
              let url = URL(string: raw) else { return nil }
        return ProviderLinkItem(provider: provider, title: key, url: url, note: proposal.headline)
    }

    private func titleBinding(_ proposal: ActionProposal) -> Binding<String> {
        Binding(
            get: { titles[proposal.id] ?? proposal.headline },
            set: { titles[proposal.id] = $0 }
        )
    }

    /// Naming the owner is an edit, not an approval. The person may still want
    /// to change the title, or decide the task should not exist — answering one
    /// question should not commit them to the rest.
    private func assign(_ person: Person, to proposal: ActionProposal) {
        guard !isDeciding else { return }
        var parameters = proposal.parameters
        parameters["assignee_person_id"] = person.personID.uuidString
        parameters["assignee_name"] = person.name
        parameters.removeValue(forKey: "assignee_hint")
        isDeciding = true
        Task {
            defer { isDeciding = false }
            problem = nil
            if await !proposals.assign(proposal, parameters: parameters) { problem = proposals.lastError }
        }
    }

    private func skip(_ proposal: ActionProposal) {
        guard !isDeciding else { return }
        isDeciding = true
        Task {
            defer { isDeciding = false }
            problem = nil
            if await !proposals.reject(proposal) { problem = proposals.lastError }
        }
    }

    private func skipAll(_ list: [ActionProposal]) {
        guard !isDeciding else { return }
        isDeciding = true
        Task {
            defer { isDeciding = false }
            problem = nil
            for proposal in list where await !proposals.reject(proposal) {
                problem = proposals.lastError
            }
        }
    }

    /// Approval is what a retry is missing: the server runs only what is
    /// `approved`, and a failure leaves the row `failed`.
    private func retry(_ proposal: ActionProposal) {
        guard !isDeciding else { return }
        isDeciding = true
        Task {
            defer { isDeciding = false }
            problem = nil
            if proposal.status == .failed {
                guard await proposals.approve(proposal) else {
                    problem = proposals.lastError
                    return
                }
            }
            await run(proposal)
        }
    }

    /// One press for the batch. Approving is what the user asked for; running
    /// it is what they meant. They are two calls because they fail
    /// differently, and the second one leaves its own trail whatever it does.
    /// In order, one at a time: three tickets landing at once in a tracker is
    /// how rate limits are met, and the rows animate in the order they read.
    private func setUp(_ list: [ActionProposal]) {
        guard !isDeciding else { return }
        isDeciding = true
        held = list
        problem = nil
        Task {
            defer { isDeciding = false }
            var approved: [ActionProposal] = []
            for proposal in list where ActionVerb.of(type: proposal.type) == .task {
                var parameters = proposal.parameters
                let edited = (titles[proposal.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !edited.isEmpty { parameters["title"] = edited }
                if let hint = parameters["assignee_hint"], !(parameters["description"] ?? "").hasPrefix(Self.ownerLine) {
                    parameters["description"] = ["\(Self.ownerLine) \(hint)", parameters["description"] ?? ""]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                }
                if await proposals.approve(proposal, parameters: parameters) {
                    approved.append(proposal)
                    titles.removeValue(forKey: proposal.id)
                } else {
                    problem = proposals.lastError
                }
            }
            held = nil
            for proposal in approved {
                await run(proposal)
            }
        }
    }

    private static let ownerLine = "Owner (as said):"

    /// Executes one approved proposal and, on success, marks its row filed on
    /// this Mac too — the server wrote the reference, but the row's own
    /// filing mark reads the local copy, and would otherwise offer a second
    /// ticket until the next refresh.
    private func run(_ proposal: ActionProposal) async {
        guard await proposals.execute(proposal) else {
            problem = proposals.lastError
            return
        }
        guard let itemID = proposal.actionItemID,
              let done = proposals.proposals.first(where: { $0.id == proposal.id }),
              let reference = Self.reference(of: done) else { return }
        actionItems.applyFiling(itemID: itemID, reference: reference)
    }

    /// Takes the batch back: each ticket is closed with a note saying so, and
    /// its row offers its filing mark again. Closed rather than deleted —
    /// Nod's writes append and never destroy, and a closed ticket that says
    /// "undone from Nod" is honest in a way a vanished one is not.
    private func undo(_ list: [ActionProposal]) {
        guard !isUndoing else { return }
        isUndoing = true
        Task {
            defer { isUndoing = false }
            problem = nil
            for proposal in list {
                guard let reference = Self.reference(of: proposal) else { continue }
                // The row is un-filed only once the ticket is really closed:
                // un-filing first and failing to close is how a second ticket
                // gets filed beside an open one.
                guard await integrations.closeTask(reference, note: "Undone from Nod — this was filed and taken back.") else {
                    problem = "Couldn't close \(reference.title) in \(reference.provider.displayName) — it's still open there."
                    continue
                }
                if let itemID = proposal.actionItemID {
                    await actionItems.clearFiling(itemID: itemID)
                }
                proposals.forget(proposal)
            }
        }
    }
}
