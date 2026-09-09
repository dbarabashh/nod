import SwiftUI

/// The last thing the window asks: say hi, and hear Nod say hi back — by
/// name, in the person's language. Small on purpose: the point is the key
/// they held to say it, which is the key they will hold from any app from
/// now on, and a hello is the shortest thing worth holding it for.
struct TalkStep: View {
    @ObservedObject var rehearsal: TalkRehearsal
    let firstName: String?
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var typed = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(
                "Hold the keys, say hi, then let go. I'm listening the whole time you hold them — and that's how you'll ask me anything, from any app."
            )
            .multilineTextAlignment(.center)
            .font(.system(size: 13))
            .foregroundStyle(Theme.Palette.inkSecondary)
            .frame(maxWidth: 440)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 28)

            if let answer {
                ReadBackCard(answer: answer)
                    .padding(.bottom, 18)
            } else {
                HStack(spacing: 18) {
                    Text("Hold")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Palette.inkSecondary)
                    HStack(spacing: 14) {
                        ForEach(Array(rehearsal.combo.keyCaps.enumerated()), id: \.offset) { _, cap in
                            KeyCap(
                                symbol: cap.symbol,
                                name: cap.name,
                                isPressed: rehearsal.phase == .listening,
                                invites: rehearsal.phase == .waiting
                            )
                        }
                    }
                    Text("and say")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Palette.inkSecondary)
                }
                .padding(.bottom, 18)

                SpeechBubble(text: bubbleText, isListening: rehearsal.phase == .listening)
                    .padding(.bottom, 14)
            }

            Text(status)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .frame(height: 18)
                .contentTransition(.opacity)
                .padding(.bottom, 14)

            if answer == nil {
                TypedAlternative(text: $typed, isFocused: $isTyping, isEnabled: canType) {
                    rehearsal.submit(typed)
                }
                .frame(maxWidth: 440)
            }

            Spacer(minLength: 0)

            OnboardingPrimaryButton("Continue", action: onContinue)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.45)
                .padding(.bottom, 10)

            Button("Skip for now", action: onSkip)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.inkSecondary)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: rehearsal.phase)
        .onAppear { rehearsal.arm(firstName: firstName) }
        .onDisappear { rehearsal.disarm() }
    }

    private var title: String {
        guard let firstName else { return "Say hi" }
        return "Say hi, \(firstName)"
    }

    private var canContinue: Bool {
        answer != nil && !rehearsal.isSpeaking
    }

    private var answer: TalkRehearsal.Answer? {
        if case let .answered(answer) = rehearsal.phase { return answer }
        return nil
    }

    private var canType: Bool {
        switch rehearsal.phase {
        case .waiting, .failed: true
        case .listening, .transcribing, .answered: false
        }
    }

    private var bubbleText: String {
        guard let firstName else { return "“Hey, my name is…”" }
        return "“Hey, my name is \(firstName)”"
    }

    private var status: String {
        switch rehearsal.phase {
        case .waiting: "waiting for you…"
        case .listening: "listening…"
        case .transcribing: "one sec…"
        case .answered: ""
        case let .failed(reason): reason
        }
    }
}

/// What was said and what Nod said back, in place of the keys once it has
/// heard them.
private struct ReadBackCard: View {
    let answer: TalkRehearsal.Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image("nc-mic")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                Text("“\(answer.heard)”")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .lineLimit(2)
            }
            Text(answer.reply)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: 480, alignment: .leading)
        .skySurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// The way in without a microphone. A quiet office, a denied mic, or simply
/// a preference — the read-back is the point, not the key.
private struct TypedAlternative: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isEnabled: Bool
    let onSubmit: () -> Void

    private var canSend: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("…or type it here", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1 ... 3)
                .focused(isFocused)
                .onSubmit(onSubmit)
            Button(action: onSubmit) {
                Image("nc-paper-plane-2")
                    .icon(11)
                    .foregroundStyle(Theme.GlassButton.text)
                    .frame(width: 24, height: 24)
                    .glassButtonSurface(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .skySurface(RoundedRectangle(cornerRadius: 12, style: .continuous), fill: 0.1)
        .disabled(!isEnabled)
    }
}

private struct KeyCap: View {
    let symbol: String
    let name: String?
    let isPressed: Bool
    /// Nothing has happened yet: the key presses itself every so often, so
    /// the instruction is shown rather than only read.
    let invites: Bool

    @State private var isBobbing = false

    private static let radius: CGFloat = 22
    private static let travel: CGFloat = 4

    private var isDown: Bool {
        isPressed || (invites && isBobbing)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(symbol)
                .font(.system(size: name == nil ? 32 : 28, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
            if let name {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.inkSecondary)
            }
        }
        .frame(width: 100, height: 100)
        .keyCapGlass(cornerRadius: Self.radius)
        .shadow(
            color: DesignTokens.Shadow.ink(light: 0.22, dark: 0.22).opacity(isDown ? 0.1 : 0.22),
            radius: isDown ? 6 : 14,
            y: isDown ? 3 : 10
        )
        .scaleEffect(isDown ? 0.96 : 1)
        .offset(y: isDown ? Self.travel : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isDown)
        .task(id: invites) {
            guard invites else {
                isBobbing = false
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { return }
                isBobbing = true
                try? await Task.sleep(nanoseconds: 260_000_000)
                isBobbing = false
            }
        }
    }
}

private extension View {
    /// Liquid Glass where the system has it; a frosted stand-in before
    /// macOS 26, on the same shape, so the key reads the same either way.
    @ViewBuilder
    func keyCapGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.Palette.overlay.opacity(0.35), lineWidth: 0.5))
        }
    }
}

private struct SpeechBubble: View {
    let text: String
    let isListening: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isListening {
                ListeningPulse()
            } else {
                Image("nc-mic")
                    .icon(13)
                    .foregroundStyle(Theme.Palette.ink)
            }
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .skySurface(Capsule(style: .continuous))
        .frame(maxWidth: 440)
    }
}

#Preview {
    WelcomeBackdrop {
        TalkStep(
            rehearsal: TalkRehearsal(
                combo: HotkeyAction.holdToAsk.defaultCombo,
                audioCapture: AudioCaptureService(),
                permissions: PermissionManager(),
                llmClient: LLMProxyClient(),
                telemetry: OnboardingTelemetry(analytics: .preview),
                language: LanguagePreference()
            ),
            firstName: "Dima",
            onContinue: {},
            onSkip: {}
        )
        .frame(width: 720, height: 660)
    }
}
