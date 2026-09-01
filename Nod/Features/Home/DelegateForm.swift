import SwiftUI

/// The "send a message" outcome: recipient picked from the workspace, a draft
/// the person reads and edits, and a send that is their own click. Split from
/// the drawer because it is a small machine of its own.
struct DelegateForm: View {
    let item: ActionItem
    let messenger: IntegrationProvider
    let ambientHints: [ScreenObservation]
    let initialMessage: String
    let onDone: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var integrations: IntegrationService
    @AppStorage(AmbientScopes.draftingKey) private var offersAmbientAdditions = false

    @State private var recipient = ""
    @State private var target: ActionDelegation.Target?
    @State private var directory: ActionDelegation.Directory?
    @State private var message = ""
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderMark(provider: messenger, size: 12)
                Text("Send a message in \(messenger.displayName)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
                // Not while a send is in flight: backing out of a form whose
                // message is already on its way would only hide the result.
                Button("Cancel", action: onCancel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .buttonStyle(.plain)
                    .linkCursor()
                    .disabled(isSending)
            }
            TextField("Who — a person, or # a channel", text: $recipient)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
                .onChange(of: recipient) { typed in
                    // Typing past a picked target un-picks it — the words in
                    // the field are the truth of who this goes to.
                    if let target, typed != target.display { self.target = nil }
                }
                // Floating under the field rather than in the column: a list
                // that pushes the message and the send button down makes the
                // whole card change height on every keystroke.
                .overlay(alignment: .topLeading) {
                    if target == nil, !suggestions.isEmpty {
                        suggestionRows
                            .offset(y: 34)
                    }
                }
                .zIndex(1)
            TextEditor(text: $message)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56, maxHeight: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
            if offersAmbientAdditions, !ambientHints.isEmpty {
                additionRows
            }
            if let sendError {
                Text(sendError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }
            HStack(spacing: 8) {
                Button(isSending ? "Sending…" : "Review & send") {
                    Task { await send(via: messenger) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.GlassButton.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassButtonSurface(Capsule(style: .continuous))
                .buttonStyle(.plain)
                .linkCursor()
                .disabled(isSending || recipient.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Sends as you. The item stays open until you close it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .onAppear {
            message = initialMessage
        }
        .task {
            await loadDirectory(via: messenger)
        }
    }

    /// Ambient-derived additions, offered and never applied on their own: a
    /// toggle edits the message editor above it, so what leaves is exactly what
    /// the person reads there — private context crosses out only by their click.
    private var additionRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggested from your ambient context · Private until you add it")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
            ForEach(ambientHints) { hint in
                let addition = ActionDelegation.addition(for: hint)
                let included = message.contains(addition)
                Button {
                    message = ActionDelegation.toggling(message: message, addition: addition)
                } label: {
                    HStack(spacing: 6) {
                        Image(included ? "nc-circle-check" : "nc-plus")
                            .icon(10)
                            .foregroundStyle(included ? Theme.Palette.success : Theme.Palette.muted)
                        Text(addition)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
    }

    /// Who the workspace can offer for what was typed: people first, then the
    /// channels this account can post to.
    private var suggestions: [ActionDelegation.Target] {
        guard let directory else { return [] }
        return ActionDelegation.matches(for: recipient, in: directory)
    }

    private var suggestionRows: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    target = suggestion
                    recipient = suggestion.display
                } label: {
                    HStack(spacing: 8) {
                        Image(suggestion.isChannel ? "nc-msgs" : "nc-user")
                            .icon(11)
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(width: 14)
                        Text(suggestion.display)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.ink)
                        if !suggestion.caption.isEmpty {
                            Text(suggestion.caption)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Palette.muted)
                                .lineLimit(1)
                        }
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
        .background(
            RoundedRectangle(cornerRadius: 7)
                // Opaque layers, because this now floats over the message: the
                // usual translucent wash would show the text underneath through
                // the rows meant to cover it.
                .fill(Theme.Palette.bg)
                .overlay(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.border, lineWidth: 1))
        .shadow(color: Theme.Palette.scrim.opacity(0.35), radius: 14, y: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The workspace's people and channels, fetched once per opening — the
    /// same reads the chat's tools use, under the same authorization.
    private func loadDirectory(via messenger: IntegrationProvider) async {
        guard directory == nil else { return }
        async let people = integrations.run(
            ActionDelegation.call(action: "list_users", of: messenger),
            tool: ActionDelegation.tool(action: "list_users", of: messenger)
        )
        async let channels = integrations.run(
            ActionDelegation.call(action: "list_channels", of: messenger),
            tool: ActionDelegation.tool(action: "list_channels", of: messenger)
        )
        directory = await ActionDelegation.directory(people: people, channels: channels)
    }

    /// One message, written and confirmed by the person right here — the same
    /// "you read it, you pressed send" contract as the chat's card.
    private func send(via messenger: IntegrationProvider) async {
        let typed = recipient.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !isSending else { return }
        if typed.hasPrefix("#"), target == nil {
            sendError = "Pick the channel from the list — a name alone isn't enough to post."
            return
        }
        isSending = true
        sendError = nil
        let arguments = ActionDelegation.sendArguments(target: target, typed: typed, message: message)
        let result = await integrations.run(
            ActionDelegation.call(action: "post_message", of: messenger, arguments: arguments),
            tool: ActionDelegation.tool(action: "post_message", of: messenger)
        )
        isSending = false
        if let failure = IntegrationService.failure(in: result) {
            sendError = failure
            return
        }
        let record = ActionDelegation.record(
            recipient: target?.display ?? typed,
            via: messenger
        )
        ActionDelegation.remember(record, for: item.id)
        onDone()
    }
}
