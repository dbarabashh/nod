import SwiftUI

// MARK: - Live indicator

/// The active-capture indicator. Keeps the brand "N" inside a soft live ring
/// instead of a stark red dot, so an in-progress session reads as "Nod is
/// working for you", not a surveillance REC light. The ring "breathes" — a
/// slow (~4.4s cycle), low-amplitude ease-in-out pulse tuned near resting-breath
/// cadence so it reads as ambient/alive in peripheral vision without capturing
/// attention. (Calm-technology / pre-attentive research: it's fast, abrupt,
/// high-contrast motion that pulls focus — slow smooth change stays peripheral.)
/// Sky-blue (brand), not alarm red, and fully static under Reduce Motion.
private struct LiveGlyph: View {
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.brand.opacity(ringOpacity), lineWidth: 1.4)
                .scaleEffect(reduceMotion ? 1 : (breathing ? 1.05 : 0.99))
            NodMark(size: 10, opacity: 0.90)
        }
        .frame(width: 18, height: 18)
        .onAppear { if !reduceMotion { breathing = true } }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
            value: breathing
        )
    }

    /// Low-contrast opacity sweep — the ring fades between a faint and a soft
    /// presence rather than blinking on/off, keeping salience low.
    private var ringOpacity: Double {
        if reduceMotion { return 0.6 }
        return breathing ? 0.7 : 0.32
    }
}

/// The brand "N" mark, template-tinted. Shared by the idle header indicator and
/// the live-capture ring so the asset name and rendering setup live in one place.
private struct NodMark: View {
    let size: CGFloat
    let opacity: Double

    var body: some View {
        Image("NTemplate")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundColor(.white.opacity(opacity))
    }
}

/// The paused-state indicator glyph, shared by the expanded header and the
/// collapsed capsule so the two can't drift.
private struct PausedGlyph: View {
    var body: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Theme.Palette.warning)
            .frame(width: 18, height: 18)
    }
}

// MARK: - Input device picker

/// Microphone chooser as a single icon in the panel header (next to Library).
/// The menu lists available inputs and pins the active one — selection writes
/// straight to `audioCapture.preferredInputUID`, same as before; only the
/// trigger moved from a full-width row to this compact glyph.
private struct MicInputPicker: View {
    @ObservedObject var audioCapture: AudioCaptureService

    var body: some View {
        HeaderMenuGlyph {
            // `waveform`, not `mic.fill` — a mic glyph collides with the
            // mute toggle (`StatusRow` uses mic/mic.slash) and reads as
            // "mute me" rather than "choose input device".
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .headerGlyphCircle()
        } menu: {
            menuItems
        }
        .help("Microphone — choose input device")
        // The list is kept live by the service's device listener; this just
        // guarantees a fresh scan the moment the picker appears.
        .onAppear { audioCapture.refreshInputs() }
    }

    @ViewBuilder private var menuItems: some View {
        Button(action: { audioCapture.preferredInputUID = nil }) {
            HStack {
                Text("System Default")
                Spacer()
                if audioCapture.preferredInputUID == nil {
                    Image(systemName: "checkmark")
                }
            }
        }
        Divider()
        ForEach(audioCapture.availableInputs) { device in
            Button(action: { audioCapture.preferredInputUID = device.uid }) {
                HStack {
                    Text(device.name + (device.isDefault ? "  (default)" : ""))
                    Spacer()
                    if device.uid == audioCapture.preferredInputUID {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        Divider()
        Button("Refresh") { audioCapture.refreshInputs() }
    }
}

// MARK: - Status header

struct StatusHeader: View {
    /// Drives the live level meter (`inputLevel`) and backs the header's mic
    /// chooser, so it's observed directly rather than threaded through props.
    @ObservedObject var audioCapture: AudioCaptureService
    /// Backs the header's mode control — a picker pre-meeting, a read-only glyph
    /// once recording.
    @ObservedObject var modeStore: ModeStore
    let onManageModes: () -> Void
    /// Whether the mode control shows — modes apply to meetings only, so it's
    /// hidden for voice notes and media captures.
    let showMode: Bool
    /// Whether the mic chooser icon shows — only when the session captures the
    /// mic and we're pre-meeting, matching where the old picker row appeared.
    let showMicPicker: Bool
    let meeting: MeetingState
    let kind: SessionKind
    let elapsed: String
    let language: AppLanguage
    let onLanguageSelect: (AppLanguage) -> Void
    var onCollapse: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Secondary controls stay minimized and reveal while the pointer is over
    /// the trailing cluster. `revealWidth` is the group's measured full width, so
    /// the reveal is a single width interpolation (0 → full) rather than views
    /// being inserted/removed.
    @State private var iconsExpanded = false
    @State private var revealWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            indicator
            // No status word in idle — the Start button beneath is its own
            // affordance, and a label there carried nothing the rest of the
            // panel didn't already show. Active states get a per-kind word.
            if meeting != .idle {
                // The status word is the first thing to yield when the trailing
                // icons reveal on hover — hiding it (rather than letting it wrap
                // to two lines) frees the width the icons need.
                if !iconsExpanded {
                    Text(meeting.statusLabel(for: kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(meeting.statusTint)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.50))
                    .lineLimit(1)
                    .fixedSize()
                // Mic level only where the mic is actually captured — `media`
                // is listen-only (no [Me] capture), so the meter would sit dead.
                if meeting == .recording, kind.capturesMic {
                    LevelMeter(level: audioCapture.inputLevel)
                }
            }
            Spacer(minLength: 0)
            trailingControls
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        // Frosted material with no border by default — the pills read as a
        // clean Raycast-style command surface. An amber border appears only
        // while paused so the "stopped" state reads at a glance, without
        // relying on the small label alone.
        .background(
            PanelMaterial()
                .clipShape(Capsule(style: .continuous))
                .overlay(Capsule().stroke(
                    meeting == .paused ? Theme.Palette.warning.opacity(0.55) : Color.clear,
                    lineWidth: meeting == .paused ? 1 : 0
                ))
        )
        // Reveal the secondary icons when the pointer is anywhere over the whole
        // header strip, not just the icon cluster.
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.panelReveal(reduceMotion: reduceMotion)) { iconsExpanded = hovering }
        }
    }

    // Secondary actions stay minimized and reveal on hover (HIG pointing-devices:
    // "reveal/hide controls that minimize"). The reveal group's width interpolates
    // 0 → full as one smooth motion — nothing is added or removed — while the
    // "…" menu and collapse chevron stay pinned and uncovered on the trailing edge.
    private var trailingControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if showMicPicker {
                    MicInputPicker(audioCapture: audioCapture)
                        .panelTooltip("Mic")
                }
                PanelIconButton(
                    systemName: "rectangle.stack",
                    help: "Library",
                    action: { NotificationCenter.default.post(name: .nodOpenLibrary, object: nil) }
                )
                .panelTooltip("Library")
                ScreenShareButton()
            }
            .fixedSize()
            .readingWidth(into: $revealWidth)
            .frame(width: iconsExpanded ? revealWidth : 0, alignment: .trailing)
            .opacity(iconsExpanded ? 1 : 0)
            // No clip: the 0-width frame + opacity hide the collapsed icons
            // (and `allowsHitTesting` keeps the invisible ones from catching
            // clicks), so a hover tooltip can extend any direction uncut.
            .allowsHitTesting(iconsExpanded)

            // Mode applies to meetings only. When shown it stays pinned in both
            // states: pre-meeting it's a picker the user chooses from; once
            // recording it's a read-only glyph that reports the active mode.
            if showMode {
                ModeHeaderControl(
                    store: modeStore,
                    interactive: meeting == .idle,
                    onManage: onManageModes
                )
                .panelTooltip(modeStore.selected.name)
            }

            // Language is the key pre-meeting choice, so it stays pinned and
            // visible by default (not tucked into the reveal group) — and
            // disappears once the meeting starts and it's locked in.
            if meeting == .idle {
                LanguagePicker(current: language, onSelect: onLanguageSelect)
                    .panelTooltip("Language")
            }
            PanelMenuButton()
                .panelTooltip("More")
            if let onCollapse {
                PanelIconButton(
                    systemName: "chevron.up",
                    help: "Collapse",
                    action: onCollapse
                )
                .panelTooltip("Collapse")
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        switch meeting {
        case .idle:
            NodMark(size: 13, opacity: 0.85)
        case .recording:
            LiveGlyph()
        case .paused:
            PausedGlyph()
        }
    }
}

// MARK: - Collapsed capsule

struct CollapsedCapsule: View {
    let meeting: MeetingState
    let kind: SessionKind
    let elapsed: String
    let language: AppLanguage
    let onExpand: () -> Void
    let onRecordToggle: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            indicator
            // Fixed 246pt capsule: pin the timer and language chip at their
            // intrinsic size and let the status word be the one that truncates,
            // so a longer per-kind label ("Transcribing") can't wrap the row to
            // a second line or clip the time.
            Text(meeting.statusLabel(for: kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(meeting.statusTint)
                .lineLimit(1)
            Text(elapsed)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            Text(language.chipLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .fixedSize()

            Spacer(minLength: 6)

            PanelIconButton(
                systemName: meeting == .paused ? "play.fill" : "pause.fill",
                tint: meeting == .paused
                    ? Theme.Palette.controlResume
                    : .white.opacity(0.80),
                help: meeting == .paused ? "Resume" : "Pause",
                action: onRecordToggle
            )
            PanelIconButton(
                systemName: "stop.fill",
                tint: Theme.Palette.controlEnd,
                fill: Theme.Palette.controlEndSurface.opacity(0.40),
                help: "End meeting",
                action: onEnd
            )
            PanelIconButton(
                systemName: "chevron.down",
                help: "Expand",
                action: onExpand
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Pin to the same width as the expanded column (suggestion pills /
        // StatusHeader) so collapsing and expanding doesn't resize the
        // top control.
        .frame(width: 246)
        .background(
            ZStack {
                PanelMaterial()
                Color.black.opacity(0.18)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
    }

    @ViewBuilder private var indicator: some View {
        switch meeting {
        case .recording:
            LiveGlyph()
        case .paused:
            PausedGlyph()
        case .idle:
            // Shouldn't render in idle — leftColumn guards this — but safe fallback.
            Circle().fill(Color.white.opacity(0.3)).frame(width: 8, height: 8)
        }
    }
}

// MARK: - Language picker

private struct LanguagePicker: View {
    let current: AppLanguage
    let onSelect: (AppLanguage) -> Void

    var body: some View {
        // A round 22×22 icon matching the other header glyphs, but its "glyph"
        // is the active language's 2-letter code so the current language reads at
        // a glance. The Menu wraps a real `Picker` so SwiftUI keeps selection
        // semantics (VoiceOver announces the choice).
        HeaderMenuGlyph {
            Text(current.chipLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.white.opacity(0.78))
                .headerGlyphCircle()
        } menu: {
            Picker("Nod language", selection: Binding(
                get: { current },
                set: { onSelect($0) }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help("Switch Nod language — applies to summaries, titles, cards, and answers")
    }
}

// MARK: - Mode header control

/// The meeting mode in the panel header. Pre-meeting it's a `Menu` picker (the
/// mode's glyph in the shared 22×22 header circle, opening the mode list plus
/// "Manage Modes…"); once recording it's the same glyph rendered read-only so it
/// can't be changed mid-meeting — it just reports the active mode. Uses the
/// shared `HeaderMenuGlyph` chrome so the header icons stay pixel-consistent.
private struct ModeHeaderControl: View {
    @ObservedObject var store: ModeStore
    let interactive: Bool
    let onManage: () -> Void

    var body: some View {
        if interactive {
            HeaderMenuGlyph {
                glyph
            } menu: {
                Picker("Mode", selection: Binding(
                    get: { store.selectedID },
                    set: { store.select($0) }
                )) {
                    ForEach(store.modes) { mode in
                        Label(mode.name, systemImage: mode.icon).tag(mode.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Manage Modes…", action: onManage)
            }
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: store.selected.icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(interactive ? 0.78 : 0.45))
            .headerGlyphCircle()
    }
}
