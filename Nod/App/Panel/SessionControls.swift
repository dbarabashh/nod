import SwiftUI

// MARK: - Session kind picker

/// Three-way segmented control for what the next recording is. Icon-over-
/// caption segments so the labels fit the compact panel width. The selection
/// drives audio-stream choice, the recap framing, and which live cards show —
/// and whether the meeting-only mode control appears in the header.
struct SessionKindPicker: View {
    @Binding var selection: SessionKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Ties the single selection pill to whichever segment is active, so it
    /// slides between them on a `.standard` spring instead of one plate fading
    /// out while another fades in — the native segmented-control feel.
    @Namespace private var selectionIndicator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SessionKind.allCases) { kind in
                segment(kind)
            }
        }
        .padding(3)
        .background(
            ZStack {
                PanelMaterial()
                Color.white.opacity(0.05)
            }
            .clipShape(Capsule(style: .continuous))
        )
    }

    private func segment(_ kind: SessionKind) -> some View {
        let isSelected = selection == kind
        return Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) { selection = kind }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(kind.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                if isSelected {
                    let pill = Capsule(style: .continuous).fill(Color.white.opacity(0.10))
                    // Reduce Motion: skip the matched-geometry slide (a translation
                    // is the vestibular motion the setting opts out of) and just
                    // fill the active segment in place.
                    if reduceMotion {
                        pill
                    } else {
                        pill.matchedGeometryEffect(id: "selection", in: selectionIndicator)
                    }
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.pressable)
        .help(helpText(kind))
    }

    private func helpText(_ kind: SessionKind) -> String {
        switch kind {
        case .meeting: "Record both sides of a call — your mic and the other participants."
        case .voiceNote: "Capture your own voice only — think out loud, get it summarized."
        case .media: "Transcribe what's playing on your Mac — a video, podcast, or talk."
        }
    }
}

// MARK: - Start button

/// Raycast-style command pill. Frosted dark capsule, neutral mic glyph,
/// "Start meeting" label. The glyph is deliberately NOT a red record dot —
/// red is reserved for the active REC state, and a red dot on the *start*
/// affordance reads for a beat as "already recording".
/// No kbd-shortcut badge — `.keyboardShortcut` on a `.nonactivatingPanel`
/// doesn't fire because the panel rarely becomes key; showing a hint for a
/// non-functional shortcut is worse than no hint.
struct StartMeetingButton: View {
    var title: String = "Start meeting"
    var icon: String = "mic.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 38)
            .glassButtonSurface(Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .linkCursor()
    }
}

// MARK: - Ask composer

/// The live "Ask" box shown while recording. A single-line field where the user
/// types a free-form question about what's being said when the fixed cards
/// (Catch me up, Key points) don't cover it. Return — or the send button — fires
/// it; the answer streams into the response card the pills also use.
///
/// Sized to the 246-wide pill column so it reads as the primary member of the
/// action stack. The floating panel `canBecomeKey` (see FloatingPanel), so
/// clicking the field focuses it and accepts typing without activating the app.
struct AskComposer: View {
    @Binding var text: String
    let enabled: Bool
    let isBusy: Bool
    /// True for users without the Pro entitlement: the box still shows (feature
    /// discovery), but the trailing affordance is a lock and any send routes to
    /// the paywall (handled by `onSend`) instead of asking.
    var locked: Bool = false
    let onSend: (String) -> Void
    @FocusState private var focused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        enabled && !isBusy && !trimmed.isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DesignTokens.Palette.electricBlue)
                .frame(width: 12)

            TextField(locked ? "Ask anything — Pro" : "Ask anything…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .focused($focused)
                // Skip autocorrect/spell services on this field — they add
                // nothing for a short prompt (and would "fix" names/jargon), and
                // not loading them keeps the first focus off the audio-stalling path.
                .disableAutocorrection(true)
                .disabled(!enabled)
                .onSubmit(send)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: 246, alignment: .leading)
        .background(
            ZStack {
                PanelMaterial()
                Color.white.opacity(0.05)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .opacity(enabled ? 1.0 : 0.55)
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.7))
                .frame(width: 12, height: 12)
        } else if locked {
            Button(action: send) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignTokens.Palette.electricBlue.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Ask is a Pro feature — upgrade to use it")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(canSend ? DesignTokens.Palette.electricBlue : .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Ask Nod about the conversation so far")
        }
    }

    private func send() {
        // Locked users can send with empty text — the tap's job is to surface the
        // paywall, which `onSend` does; keep whatever they typed rather than wiping.
        if locked {
            onSend(trimmed)
            return
        }
        guard canSend else { return }
        onSend(trimmed)
        text = ""
    }
}

// MARK: - Hero

struct HeroButton: View {
    let isGenerating: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(Theme.GlassButton.text)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignTokens.Palette.electricBlue)
                }

                Text(isGenerating ? "Recalling…" : "Catch me up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Match SuggestionPill width for a tidy stacked-pill column.
            .frame(width: 246, alignment: .leading)
            .glassButtonSurface(Capsule(style: .continuous))
            .opacity(enabled ? 1.0 : 0.55)
        }
        .buttonStyle(.pressable)
        .disabled(!enabled || isGenerating)
    }
}

// MARK: - Suggestion pill

struct SuggestionPill: View {
    let label: String
    let icon: String
    let isGenerating: Bool
    let enabled: Bool
    var hotkeyHint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(Theme.Palette.ink)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 12)
                }

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let hotkeyHint {
                    Text(hotkeyHint)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Palette.ink.opacity(0.50))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Width sized to the longest label ("Suggest follow-up questions").
            // Flatter, lighter treatment than the HeroButton — these are the
            // secondary tier, so no gradient / drop shadow, just a faint
            // translucent fill that reads as "also available".
            .frame(width: 246, alignment: .leading)
            .background(
                ZStack {
                    PanelMaterial()
                    Color.white.opacity(0.04)
                }
                .clipShape(Capsule(style: .continuous))
            )
            .opacity(enabled ? 1.0 : 0.55)
        }
        .buttonStyle(.pressable)
        .disabled(!enabled || isGenerating)
    }
}
