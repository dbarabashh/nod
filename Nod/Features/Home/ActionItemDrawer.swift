import SwiftUI

/// What clicking a commitment on Today opens: the actions, in place.
///
/// The session is evidence, not the destination — so the row expands into what
/// can be done about the item, and the source is a line to click rather than
/// where the click lands. "Take action" leads because acting on the item is
/// the product act; "Ask Nod" stays secondary.
struct ActionItemDrawer: View {
    let item: ActionItem
    let sourceTitle: String?
    /// Related on-screen work, already fetched under the person's own opt-in.
    /// Empty when the scope is off — the drawer then simply has no such rows.
    let ambientHints: [ScreenObservation]
    let onAsk: (String) -> Void
    let onOpenSource: () -> Void

    @EnvironmentObject private var integrations: IntegrationService

    @State private var isChoosingIntent = false
    @State private var intent: ActionIntent?
    @State private var plan = ""
    /// An outcome that just landed — its line, and the created thing's own
    /// page, because "created" without a way to open it is a claim, not a
    /// result. Not a delegation: a reminder does not move the item to
    /// "waiting on others".
    @State private var completed: (record: String, url: URL?)?

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
            } else if isChoosingIntent {
                intentMenu
            } else {
                actionsRow
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

    /// The action item is the outcome; the products are only how. So the row
    /// names the act, never a logo — with twelve integrations a Slack button
    /// beside a Linear button beside a calendar button is a toolbar, not a
    /// decision.
    private var actionsRow: some View {
        HStack(spacing: 8) {
            if !intents.isEmpty {
                Button("Take action") {
                    isChoosingIntent = true
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.GlassButton.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassButtonSurface(Capsule(style: .continuous))
                .buttonStyle(.plain)
                .linkCursor()
            }
            secondaryButton("Ask Nod") {
                onAsk(ActionDelegation.askPrompt(for: item, source: sourceTitle))
            }
            Spacer(minLength: 0)
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
            HStack {
                Text("What should happen?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
                Button("Close") { isChoosingIntent = false }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .buttonStyle(.plain)
                    .linkCursor()
            }
            TextField("Describe the outcome… @ names a tool", text: $plan)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
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
                            .offset(y: 32)
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
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
        }
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
        let offered = mentionCandidates(matching: fragment)
        return VStack(spacing: 0) {
            ForEach(offered.prefix(5), id: \.self) { provider in
                Button {
                    plan = ActionDelegation.inserting(mention: provider, into: plan)
                } label: {
                    HStack(spacing: 8) {
                        ProviderMark(provider: provider, size: 12)
                        Text(provider.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.Palette.bg)
                .overlay(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.border, lineWidth: 1))
        .shadow(color: Theme.Palette.scrim.opacity(0.35), radius: 14, y: 6)
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
        isChoosingIntent = false
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
        isChoosingIntent = false
        onAsk("\(typed)\n\nThis is about my open action: \(item.text)" +
            (sourceTitle.map { " (from \"\($0)\")" } ?? ""))
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

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong))
            .buttonStyle(.plain)
            .linkCursor()
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
