import SwiftUI

// MARK: - Session kind picker

/// Three-way segmented control for what the next recording is. Icon-over-
/// caption segments so the labels fit the compact panel width. The selection
/// drives audio-stream choice, the recap framing, and which live cards show —
/// and whether the meeting-only mode control appears in the header.
struct SessionKindPicker: View {
    @Binding var selection: SessionKind

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
            withAnimation(.easeOut(duration: 0.14)) { selection = kind }
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
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : .clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
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
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .scaleEffect(pressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.10), value: pressed)
            .animation(.hoverReveal(reduceMotion: reduceMotion), value: hovered)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
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
                    Image(systemName: "sparkles")
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .disabled(!enabled || isGenerating)
    }
}
