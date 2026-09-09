import SwiftUI

/// The free-text box plus whatever it's showing — a fresh field, a spinner,
/// an answer, or a failure. The field itself never goes away once Ask is
/// open, so answering one question and asking the next reads as one
/// conversation rather than a result screen you have to back out of.
struct MeetingAskPanel: View {
    let phase: AskPhase
    /// A write waiting on the person. Shown instead of the spinner: the
    /// question is not "still thinking", it is theirs to answer.
    var approval: ChatToolGate.Pending?
    /// Whether this bar has a lookup at all. Stated rather than defaulted, so
    /// the day a third bar appears it is asked the question rather than quietly
    /// answered no — the same reason the listening bar spells out its `loops`
    /// and its approval handlers.
    let canReachTools: Bool
    /// A question being spoken rather than typed; the field steps aside for
    /// as long as it lasts.
    var voice: VoiceAskPhase = .idle
    let onSubmit: (String) -> Void
    let onSummarize: () -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void

    @EnvironmentObject private var integrations: IntegrationService
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            result
            if voice != .idle {
                VoiceAskRow(phase: voice)
            }
            if voice == .idle || voice.isSpeaking {
                inputRow
            }
            if approval == nil {
                if canName {
                    ConnectedToolsRow(aimed: Set(MentionMark.namedTools(in: draft)), onTap: toggle)
                }
                if case .composing = phase {
                    suggestions
                }
            }
        }
        .onAppear { focused = true }
    }

    /// Whether a question typed here can name a product. One source for the row
    /// and for the placeholder: asked separately, a host with nothing connected
    /// was taught the `@` gesture by a prompt while the row beside it drew
    /// nothing to aim at.
    ///
    /// Providers rather than everything the row draws. An authorized product
    /// with no actions behind it appears there — that is what tells somebody
    /// the connection took — but it cannot be aimed at, so it is not a reason
    /// to teach the gesture.
    private var canName: Bool {
        canReachTools && !integrations.usable.isEmpty
    }

    @ViewBuilder
    private var result: some View {
        if let approval {
            ToolApprovalCard(approval: approval, onApprove: onApprove, onDeny: onDeny)
        } else {
            answerSoFar
        }
    }

    @ViewBuilder
    private var answerSoFar: some View {
        switch phase {
        case .composing:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                    .tint(Theme.Palette.muted)
                Text("Thinking…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case let .answered(question, answer, source):
            VStack(alignment: .leading, spacing: 4) {
                Text(question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                answerText(answer, source: source)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink)
                    .tint(Theme.Palette.brand)
                    .fixedSize(horizontal: false, vertical: true)
                // Only a catalogue mark still needs a line of its own — it is
                // fetched, so it cannot be part of the sentence.
                if let source, ProviderMark.inline(source.provider) == nil {
                    ProviderMark(provider: source.provider, size: 11)
                }
            }
        case let .failed(question):
            Text("Couldn't answer \u{201C}\(question)\u{201D} — try again.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    /// The answer with the product's mark trailing the last word, so a sentence
    /// that already fits keeps its line instead of pushing a one-icon row under
    /// it. A subject worth naming follows the mark, muted.
    private func answerText(_ answer: String, source: LiveMeetingAnalyst.AnswerSource?) -> Text {
        var text = Text(AnswerLinkText.linked(answer))
        guard let source else { return text }
        if let mark = ProviderMark.inline(source.provider) {
            text = text + Text(verbatim: "  ") + mark
        }
        guard let subject = source.subject else { return text }
        return text + Text(verbatim: " \(subject)").foregroundColor(Theme.Palette.muted)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(canName ? "Ask about this session, or @ a tool…" : "Ask anything about this session…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Image("nc-paper-plane-2")
                    .icon(11)
                    .foregroundStyle(canSubmit ? Theme.Palette.brand : Theme.Palette.muted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
    }

    private var suggestions: some View {
        HStack(spacing: 8) {
            chip("What did we decide?")
            chip("Who owns this?")
            Button(action: onSummarize) {
                Text("Summarize")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .buttonStyle(.pressable)
        }
    }

    private func chip(_ text: String) -> some View {
        Button { onSubmit(text) } label: {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(1)
        }
        .buttonStyle(.pressable)
    }

    /// Arms the product, or takes it back out. The token goes into the sentence
    /// rather than beside it, so deleting the words is a way of changing your
    /// mind that works without this row — and the tap asks the same reader that
    /// lit the mark, so a draft that merely spells a token is not one this can
    /// cut a word out of.
    private func toggle(_ provider: IntegrationProvider) {
        let mark = MentionMark(tool: provider)
        if MentionMark.namedTools(in: draft).contains(provider) {
            mark.remove(from: &draft)
        } else {
            mark.insert(into: &draft)
        }
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let question = draft
        draft = ""
        onSubmit(question)
    }
}

#if DEBUG
    #Preview("Composing") {
        MeetingAskPanel(
            phase: .composing,
            canReachTools: true,
            onSubmit: { _ in },
            onSummarize: {},
            onApprove: {},
            onDeny: {}
        )
        .environmentObject(IntegrationService.preview(linked: [.linear, .slack, .googleCalendar]))
        .environmentObject(IntegrationCatalogue(supabase: nil))
        .frame(width: 396)
        .padding()
        .background(WindowBackdrop())
    }

    #Preview("Answered, listening") {
        MeetingAskPanel(
            phase: .answered(question: "What did we decide?", answer: "Pricing moves to the 12th."),
            canReachTools: false,
            onSubmit: { _ in },
            onSummarize: {},
            onApprove: {},
            onDeny: {}
        )
        .environmentObject(IntegrationService.preview())
        .environmentObject(IntegrationCatalogue(supabase: nil))
        .frame(width: 396)
        .padding()
        .background(WindowBackdrop())
    }
#endif
