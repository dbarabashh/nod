import SwiftUI

/// Ask Nod, from the notch, with no meeting running: one field, and the answer
/// under it — out of every session, the calendar, and what has been on screen.
/// The hotkey opens it from any app; the field takes the caret without a click.
struct NotchAskCard: View {
    @ObservedObject var chat: KnowledgeChatStore
    let baseline: Int
    let canAskAcrossSessions: Bool
    let voice: VoiceAskPhase
    let onSubmit: (String) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onOpenLibrary: () -> Void
    let onClose: () -> Void
    /// Escape: stops the voice if it is speaking, closes the card otherwise.
    let onEscape: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("nc-sparkle-3")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.brand)
                Text("Ask Nod")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
                NotchGlyphButton(icon: "nc-window-pointer", help: "Open Nod window", action: onOpenLibrary)
                NotchGlyphButton(icon: "nc-xmark", help: "Close", action: onClose)
            }
            // Escape closes — or first cuts the voice off. A plain button rather
            // than a shortcut on the glyph: the glyph is a view around a button,
            // and the shortcut has to sit on the button itself to fire.
            .background(
                Button("", action: onEscape)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            )

            NotchAskAnswer(
                chat: chat,
                baseline: baseline,
                canAskAcrossSessions: canAskAcrossSessions,
                onOpenMeeting: onOpenMeeting
            )

            if voice != .idle {
                VoiceAskRow(phase: voice)
            }
            if voice == .idle || voice.isSpeaking {
                NotchAskComposer(
                    isSending: chat.isSending,
                    suggestions: chat.answer(after: baseline) == nil
                        ? ["What did I work on today?", "What's still open?", "What's next on my calendar?"]
                        : [],
                    onSubmit: onSubmit
                )
            }
        }
    }
}

/// The field's stand-in while a question is being spoken: the microphone is
/// open, or the clip is on its way to text. Shared by the idle card and both
/// meeting bars so a held key looks the same wherever it lands.
struct VoiceAskRow: View {
    let phase: VoiceAskPhase

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .transcribing, .thinking:
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                    .tint(Theme.Palette.muted)
            case .speaking:
                Image("nc-volume-up")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.brand)
                ListeningPulse()
            case .failed:
                Image("nc-mic-slash")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.muted)
            case .idle, .listening:
                Image("nc-mic")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.brand)
                ListeningPulse()
            }
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(isFailure ? Theme.Palette.muted : Theme.Palette.ink)
                .lineLimit(2)
            Spacer(minLength: 0)
            if phase.isSpeaking {
                Text("Esc to stop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
        .animation(.easeInOut(duration: 0.22), value: phase)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch phase {
        case .idle, .listening: "Listening — let go to ask"
        case .transcribing: "Writing that down…"
        case .thinking: "Thinking…"
        case let .speaking(words): words.isEmpty ? "Speaking…" : words
        case let .failed(reason): reason
        }
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }
}

/// A dot that breathes while the microphone is open. Real rather than
/// decorative: it is only drawn while the key is down.
struct ListeningPulse: View {
    @State private var isBright = false

    var body: some View {
        Circle()
            .fill(Theme.Palette.brand)
            .frame(width: 6, height: 6)
            .opacity(isBright ? 1 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isBright = true
                }
            }
    }
}

// MARK: - The field

/// The question box and, before anything has been asked, a few things worth
/// asking. Shared by the idle card and the setup flow's last step, so a
/// question feels the same the first time and every time after.
struct NotchAskComposer: View {
    let isSending: Bool
    let suggestions: [String]
    let onSubmit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask about your day, your sessions, or your screen…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
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

            if !suggestions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.self) { text in
                        Button { onSubmit(text) } label: {
                            Text(text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Palette.muted)
                                .lineLimit(1)
                        }
                        .buttonStyle(.pressable)
                        .disabled(isSending)
                    }
                }
            }
        }
        .onAppear { focused = true }
    }

    private var canSubmit: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let question = draft
        draft = ""
        onSubmit(question)
    }
}

// MARK: - The answer

/// What the shared thread has said since this surface opened: the stage it is
/// on while working, the answer as it streams, the passages it stands on, or
/// why there is none. Nothing older than `baseline` is drawn — that belongs to
/// the Library's own conversation.
struct NotchAskAnswer: View {
    @ObservedObject var chat: KnowledgeChatStore
    let baseline: Int
    let canAskAcrossSessions: Bool
    /// How tall the answer may grow before it scrolls. The canvas behind the
    /// notch is a fixed 460pt, and the setup's last card has more above the
    /// answer than the idle card does.
    var maxAnswerHeight: CGFloat = 240
    let onOpenMeeting: (UUID) -> Void

    private static let evidenceLimit = 2

    var body: some View {
        if !canAskAcrossSessions {
            upsell
        } else if let approval = chat.pendingApproval {
            ToolApprovalCard(
                approval: approval,
                onApprove: chat.approvePendingTools,
                onDeny: chat.denyPendingTools
            )
        } else if let answer = chat.answer(after: baseline) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    AssistantTextBubble(content: answer.content, showsBubble: false, isStreaming: chat.isStreaming)
                    if chat.isStreaming {
                        ThinkingIndicator(script: chat.thinkingScript)
                    } else if !answer.evidence.isEmpty {
                        evidence(answer.evidence)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxAnswerHeight)
        } else if chat.isSending {
            ThinkingIndicator(script: chat.thinkingScript, icon: chat.callingProvider?.iconName)
        } else if let failure = chat.failure {
            Text(failure.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidence(_ all: [KnowledgeChatStore.Excerpt]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("From your sessions", size: .compact)
            ForEach(Array(all.prefix(Self.evidenceLimit)), id: \.id) { item in
                Button { onOpenMeeting(item.meetingID) } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                            .lineLimit(1)
                        Text(item.date)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.muted)
                        Spacer(minLength: 4)
                        Image("nc-arrow-up-right")
                            .icon(9)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
    }

    private var upsell: some View {
        HStack(spacing: 10) {
            Image("nc-sparkle-3")
                .icon(13)
                .foregroundStyle(Theme.Palette.violet)
            Text("Asking across sessions is a Pro feature.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.graphite)
            Spacer(minLength: 8)
            NotchActionButton(title: "Upgrade") {
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            }
        }
    }
}
