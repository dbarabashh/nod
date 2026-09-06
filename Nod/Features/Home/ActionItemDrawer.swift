import SwiftUI

/// What clicking a commitment on Today opens: the actions, in place.
///
/// The session is evidence, not the destination — so the row expands into what
/// can be done about the item, and the source is a line to click rather than
/// where the click lands. It opens straight into the outcomes: the row's own
/// "Take action" pill is what the person already clicked to get here.
struct ActionItemDrawer: View {
    let item: ActionItem
    let sourceTitle: String?

    private var source: KnowledgeChatStore.SessionRef? {
        sourceTitle.map { KnowledgeChatStore.SessionRef(id: item.meetingID, title: $0) }
    }

    /// Related on-screen work, already fetched under the person's own opt-in.
    /// Empty when the scope is off — the drawer then simply has no such rows.
    let ambientHints: [ScreenObservation]
    /// An outcome the caller already named — a right-click that picked
    /// "Schedule a follow-up" opens that form, not the menu holding it.
    let preselectedIntent: ActionIntent?
    let onAsk: (ActionDelegation.AskRequest) -> Void
    let onOpenSource: () -> Void
    /// Collapse the whole row. The menu is the drawer's resting state, so
    /// dismissing it has nowhere left to go inside the drawer.
    let onClose: () -> Void

    @EnvironmentObject private var integrations: IntegrationService

    @State private var intent: ActionIntent?
    @State private var plan = ""
    /// An outcome that just landed — its line, and the created thing's own
    /// page, because "created" without a way to open it is a claim, not a
    /// result. Not a delegation: a reminder does not move the item to
    /// "waiting on others".
    @State private var completed: (record: String, url: URL?)?

    init(
        item: ActionItem,
        sourceTitle: String?,
        ambientHints: [ScreenObservation],
        preselectedIntent: ActionIntent? = nil,
        onAsk: @escaping (ActionDelegation.AskRequest) -> Void,
        onOpenSource: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.sourceTitle = sourceTitle
        self.ambientHints = ambientHints
        self.preselectedIntent = preselectedIntent
        self.onAsk = onAsk
        self.onOpenSource = onOpenSource
        self.onClose = onClose
        _intent = State(initialValue: preselectedIntent)
    }

    /// The first connected product that can carry a message. Slack today; the
    /// array is what keeps tomorrow's chat product a one-line change.
    private var messenger: IntegrationProvider? {
        [IntegrationProvider.slack].first { integrations.isUsable($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            contextSection
            if let completed {
                completedLine(completed)
            }
            if intent == .sendMessage, let messenger {
                DelegateForm(
                    item: item,
                    messenger: messenger,
                    ambientHints: ambientHints,
                    initialMessage: ActionDelegation.draft(for: item, source: sourceTitle),
                    // A sent handoff moves the item to "Waiting on others",
                    // which unmounts this drawer — nothing to show here after.
                    onDone: { intent = nil },
                    onCancel: { intent = nil }
                )
            } else if intent == .createTask {
                createTaskRow
            } else if intent == .scheduleMeeting || intent == .addReminder {
                CalendarEventForm(
                    item: item,
                    kind: intent == .scheduleMeeting ? .meeting : .reminder,
                    onDone: { record, url in
                        completed = (record, url)
                        intent = nil
                    },
                    onClose: { intent = nil }
                )
            } else {
                intentMenu
            }
        }
    }

    /// The evidence behind the action, in three provenances: what the meeting
    /// said, what the screen saw (private, opt-in), where it was filed. The
    /// session stops being the destination once its words are right here.
    @ViewBuilder private var contextSection: some View {
        if item.evidenceQuote != nil || !ambientHints.isEmpty || item.filed != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let quote = item.evidenceQuote, !quote.isEmpty {
                    Button(action: onOpenSource) {
                        contextRow(icon: "nc-msgs", label: sourceTitle.map { "From \($0)" } ?? "From the meeting") {
                            Text("“\(quote)”")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                    .help("Open the source session")
                }
                ForEach(ambientHints) { hint in
                    contextRow(icon: "nc-window-pointer", label: "From your screen · Private") {
                        Text("\(hint.appDisplayName): \(hint.sourceTitle) · \(AmbientScopes.when(hint.observedAt))")
                    }
                }
                if let filed = item.filed {
                    contextRow(icon: nil, label: "Filed") {
                        HStack(spacing: 5) {
                            ProviderMark(provider: filed.provider, size: 11)
                            Text(filed.title)
                        }
                    }
                }
            }
        }
    }

    private func contextRow(icon: String?, label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon {
                Image(icon)
                    .icon(10)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
            content()
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .lineLimit(2)
        }
    }

    private var intents: [ActionIntent] {
        ActionIntent.available(usable: integrations.isUsable)
    }

    /// "What should happen?" — the outcome composer first, because free words
    /// are what scale to a plan across tools; the named suggestions below are
    /// the shortcuts for the common single outcomes. Suggested products are a
    /// recommendation, never the intent's identity.
    private var intentMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineFormHeader("What should happen?", onDismiss: onClose)
            InlineTextField("Describe the outcome… @ names a tool", text: $plan)
                .onSubmit {
                    // Return while a tool is being named completes the name;
                    // sending "@Sl" as a plan is never what Return meant.
                    if let fragment = ActionDelegation.mentionFragment(in: plan),
                       let first = mentionCandidates(matching: fragment).first {
                        plan = ActionDelegation.inserting(mention: first, into: plan)
                    } else {
                        submitPlan()
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let fragment = ActionDelegation.mentionFragment(in: plan) {
                        mentionRows(matching: fragment)
                    }
                }
                .zIndex(1)
            Text("Nod can create a plan across connected tools.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Palette.muted)
            Text("SUGGESTED FOR THIS ACTION")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(intents) { offered in
                    intentRow(offered)
                }
                askRow
            }
            .inlineFieldSurface()
        }
    }

    /// Asking is an outcome too, so it sits with the others rather than beside
    /// them as a second pill. It also keeps the list from being empty for
    /// someone with nothing connected yet.
    private var askRow: some View {
        Button {
            onAsk(ActionDelegation.askPrompt(for: item, source: source))
        } label: {
            HStack(spacing: 8) {
                Image("nc-msgs")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 14)
                Text("Ask Nod about this")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    /// The products the typed `@` could mean. Picking one writes the same
    /// `@Name` token the chat's composer uses, so the plan arrives there
    /// already naming its tools.
    private func mentionCandidates(matching fragment: String) -> [IntegrationProvider] {
        let query = fragment.lowercased()
        return integrations.usable.filter {
            query.isEmpty || $0.displayName.lowercased().hasPrefix(query)
        }
    }

    private func mentionRows(matching fragment: String) -> some View {
        SuggestionPopover(
            items: Array(mentionCandidates(matching: fragment).prefix(5)),
            width: 220,
            onPick: { plan = ActionDelegation.inserting(mention: $0, into: plan) },
            row: { provider in
                ProviderMark(provider: provider, size: 12)
                Text(provider.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink)
            }
        )
    }

    private func intentRow(_ offered: ActionIntent) -> some View {
        Button {
            choose(offered)
        } label: {
            HStack(spacing: 8) {
                Image(offered.icon)
                    .icon(11)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(offered.contextTitle(for: item))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    if offered == .createTask, let filed = item.filed {
                        Text("Already filed as \(filed.title)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.warning)
                    } else if let suggested = offered.carriers.first(where: integrations.isUsable) {
                        Text("Suggested: \(suggested.displayName)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.muted)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(offered.carriers.filter(integrations.isUsable), id: \.self) { provider in
                        ProviderMark(provider: provider, size: 10)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    private func choose(_ offered: ActionIntent) {
        completed = nil
        intent = offered
    }

    /// Compound requests go to the chat with the action's context attached —
    /// that is the execution engine that already plans across tools and stops
    /// every write at a card.
    private func submitPlan() {
        let typed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        plan = ""
        onAsk(ActionDelegation.AskRequest(
            text: "\(typed)\n\nThis is about my open action: \(item.text)" + (source.map { " (from \($0.mentionToken))" } ?? ""),
            session: source
        ))
    }

    /// The "create a task" outcome, inline — the popover the shared filing
    /// button opens floats over the list and hides which thing is the button;
    /// here the form sits in the flow and the filing button says its verb.
    private var createTaskRow: some View {
        TaskCreateForm(
            item: item,
            onDone: { record, url in
                completed = (record, url)
                intent = nil
            },
            onClose: { intent = nil }
        )
    }

    /// The result, openable: created things get clicked, not just believed.
    @ViewBuilder private func completedLine(_ outcome: (record: String, url: URL?)) -> some View {
        if let url = outcome.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 6) {
                    Image("nc-circle-check")
                        .icon(11)
                        .foregroundStyle(Theme.Palette.success)
                    Text(outcome.record)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    Image("nc-arrow-up-right").icon(8)
                        .foregroundStyle(Theme.Palette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Open it")
        } else {
            HStack(spacing: 6) {
                Image("nc-circle-check")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.success)
                Text(outcome.record)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }
}
