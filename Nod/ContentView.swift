import AppKit
import Supabase
import SwiftUI

// MARK: - State

/// Compact vs wide panel footprint. Shared by `ContentView` (layout) and
/// `AppDelegate` (initial NSPanel size) so the two can't drift out of sync.
enum PanelWidth {
    static let compact: CGFloat = 320
    static let wide: CGFloat = 640
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var session: MeetingSession
    @EnvironmentObject private var audioCapture: AudioCaptureService
    @EnvironmentObject private var language: LanguagePreference
    @EnvironmentObject private var consent: ConsentPreference
    @EnvironmentObject private var updateGate: UpdateGate
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var hotkey: HotkeyManager

    /// Reports the panel's desired width as the layout switches between the
    /// compact single-column state and the wide two-column state. The
    /// AppDelegate resizes the NSPanel so its clickable footprint (and the
    /// transparent dead-zone over apps behind it) shrinks when only the
    /// command column is showing. Optional so the SwiftUI #Preview still
    /// builds with a bare `ContentView()`.
    var onPreferredWidthChange: ((CGFloat) -> Void)?

    /// Force the floating panel to repaint its full content. The panel is a
    /// transparent, fixed-height, buffered `NSPanel`: when tall content (the
    /// pre-meeting card) is replaced by shorter content (the recording pills),
    /// the exposed region keeps the old pixels in the backing store until some
    /// later redraw (a per-second `elapsed` tick) happens to repaint it — which
    /// is the "the start card lingers behind for a couple seconds" glitch.
    /// Invoked whenever the measured content height changes (see
    /// `PanelContentHeightKey`) so the clear happens on any content reshape.
    var onRedrawNeeded: (() -> Void)?

    /// When meeting is active, the left column shows the full controls by
    /// default. User can tap the chevron in StatusHeader to collapse to the
    /// tiny REC capsule, then tap that to re-expand.
    @State private var expanded: Bool = true
    /// True while the recording-consent modal is on screen; gates startMeeting()
    /// before audio capture begins. See issue #4.
    @State private var showConsentDisclaimer: Bool = false
    /// True while the per-meeting language confirm is on screen. Shown when the
    /// user taps Start so a stale language pin can't silently carry into a new
    /// meeting; on confirm we fall through to the consent gate / recording.
    @State private var showLanguagePrompt: Bool = false
    /// Whether to show the language confirm on Start. User-toggleable from the
    /// popup's checkbox and Settings → General.
    @AppStorage(MeetingLanguagePromptDefaults.defaultsKey) private var confirmLanguageBeforeMeeting: Bool = MeetingLanguagePromptDefaults.defaultValue

    /// The panel widens to two columns only when there's something to show
    /// on the right — a ready response or the consent modal (centred in the
    /// full width). Recording with no open response stays compact. The
    /// save-error toast renders inline under the left column, so it doesn't
    /// trigger the wide layout.
    private var isWide: Bool {
        if showConsentDisclaimer { return true }
        switch session.response {
        case .ready, .streaming: return true
        default: return false
        }
    }

    private var contentWidth: CGFloat {
        isWide ? PanelWidth.wide : PanelWidth.compact
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 12) {
                leftColumn
                    .frame(width: 288, alignment: .topLeading)

                // Present only in the wide state, so the compact layout is
                // just the 288-wide command column and never overflows the
                // 320 window. The window snaps to its new width (see
                // AppDelegate) so content width and window width stay
                // consistent — no frame where the content is wider than the
                // window (which NSHostingController renders as a slide/clip).
                if isWide {
                    responseColumn
                        .frame(width: 308, alignment: .topLeading)
                }
            }
            .padding([.horizontal, .bottom], 16)
            // Extra top room so a header icon's hover tooltip can sit above the
            // row without being clipped by the panel's top edge.
            .padding(.top, PanelTooltip.reservedTopSpace)
            // Measure the natural content height so any reshape (recording
            // pills replacing the taller pre-meeting card, a response card
            // opening/closing, …) triggers a panel repaint — see
            // `onRedrawNeeded`. Measured before the fill frame below so it's the
            // content's own height, not the stretched window height.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
                }
            )
            // Fill the window and anchor leading so content lines up at the
            // left edge regardless of the window's current width.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.clear)
            // While the consent modal is up, the card sits on top with no
            // backdrop — disable the columns underneath so a click in the
            // gap around the card can't accidentally hit a control.
            .allowsHitTesting(!showConsentDisclaimer)

            if showConsentDisclaimer {
                ConsentDisclaimerView(
                    strings: .english,
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showConsentDisclaimer = false
                        }
                    },
                    onAcknowledge: { dontShowAgain in
                        // Always log the legal acknowledgement; "Don't show
                        // again" only controls the local UX gate.
                        consent.acknowledge(persistGate: dontShowAgain)
                        withAnimation(.easeOut(duration: 0.15)) {
                            showConsentDisclaimer = false
                        }
                        beginRecording()
                    }
                )
                .zIndex(1)
            }

            if case .recommended = updateGate.status {
                VStack {
                    UpdateBanner(
                        onUpdate: { updateGate.startUpdate() },
                        onDismiss: { updateGate.dismissRecommended() }
                    )
                    Spacer(minLength: 0)
                }
                .zIndex(3)
            }

            if updateGate.status == .required {
                UpdateRequiredOverlay(onUpdate: { updateGate.startUpdate() })
                    .zIndex(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { onPreferredWidthChange?(contentWidth) }
        .onChange(of: isWide) { _ in onPreferredWidthChange?(contentWidth) }
        // Repaint the panel whenever the content's natural height changes, so
        // the shorter content can't leave stale pixels in the transparent
        // panel's backing store. Driven by the measured height above rather than
        // a specific state transition, so every present and future content swap
        // is covered without a per-feature hook.
        .onPreferenceChange(PanelContentHeightKey.self) { _ in onRedrawNeeded?() }
        .task { await session.runSecondsTimer() }
        .onReceive(NotificationCenter.default.publisher(for: .nodSuggestHotkey)) { _ in
            // Global hotkey fired. Only act if a meeting is recording and we
            // aren't already generating a Suggest reply (debounce duplicate
            // fast presses).
            guard session.meeting == .recording, !session.isGenerating(for: .suggestReply) else { return }
            session.generate(kind: .suggestReply)
        }
    }

    /// Default state during a meeting is collapsed: shows only the REC capsule.
    /// Idle (pre-meeting) state always shows the full pre-meeting card layout.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            leftColumnContent

            // Sits directly under the command card (Start meeting / the last
            // pill) instead of pinned to the window bottom, so there's no gap
            // between the controls and the sync warning.
            if let saveErrorToast = session.saveErrorToast, !session.pendingMeetingSaves.isEmpty {
                SaveErrorToast(
                    message: saveErrorToast,
                    canRetry: true,
                    onRetry: session.retryPendingSaves,
                    onDismiss: session.dismissSaveError
                )
            }
        }
    }

    @ViewBuilder
    private var leftColumnContent: some View {
        if session.meeting != .idle, !expanded {
            CollapsedCapsule(
                meeting: session.meeting,
                elapsed: elapsedString,
                language: language.current,
                onExpand: {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = true }
                },
                onRecordToggle: session.toggleRecording,
                onEnd: session.endMeeting
            )
        } else {
            mainColumn
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader(
                audioCapture: audioCapture,
                showMicPicker: session.meeting == .idle && session.selectedKind.capturesMic,
                meeting: session.meeting,
                elapsed: elapsedString,
                language: language.current,
                onLanguageSelect: { language.current = $0 },
                onCollapse: session.meeting != .idle ? {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = false }
                } : nil
            )

            switch session.meeting {
            case .idle:
                SessionKindPicker(selection: $session.selectedKind)
                if showLanguagePrompt {
                    MeetingLanguagePrompt(
                        language: language.current,
                        askEachTime: $confirmLanguageBeforeMeeting,
                        onStart: { startMeeting() },
                        onCancel: { setLanguagePrompt(false) }
                    )
                } else {
                    StartMeetingButton(
                        title: session.selectedKind.startActionTitle,
                        icon: session.selectedKind.icon,
                        action: {
                            confirmLanguageBeforeMeeting ? setLanguagePrompt(true) : startMeeting()
                        }
                    )
                }

            case .recording, .paused:
                // One primary action (Catch me up — absorbs the old "Recap
                // so far"; they answered the same "summarise what happened"
                // need). The rest are a quieter secondary tier with glyphs
                // that name the action instead of decorative colour dots.
                HeroButton(
                    isGenerating: session.isGenerating(for: .hero),
                    enabled: session.meeting == .recording,
                    action: { session.generate(kind: .hero) }
                )

                // Reply coaching only makes sense for a two-party meeting —
                // a solo memo or a podcast has no incoming turn to answer.
                if session.selectedKind.supportsReplyCoaching {
                    SuggestionPill(
                        label: "Suggest reply",
                        icon: "arrowshape.turn.up.left.fill",
                        isGenerating: session.isGenerating(for: .suggestReply),
                        enabled: session.meeting == .recording,
                        hotkeyHint: hotkey.combo(for: .suggestReply).displayString,
                        action: { session.generate(kind: .suggestReply) }
                    )
                }
                SuggestionPill(
                    label: "Key points",
                    icon: "list.bullet",
                    isGenerating: session.isGenerating(for: .keyPoints),
                    enabled: session.meeting == .recording,
                    action: { session.generate(kind: .keyPoints) }
                )
                if session.selectedKind.supportsReplyCoaching {
                    SuggestionPill(
                        label: "Suggest follow-up questions",
                        icon: "questionmark.bubble.fill",
                        isGenerating: session.isGenerating(for: .followUp),
                        enabled: session.meeting == .recording,
                        action: { session.generate(kind: .followUp) }
                    )
                }
            }

            if session.meeting != .idle {
                StatusRow(
                    meeting: session.meeting,
                    micMuted: session.micMuted,
                    showMic: session.selectedKind.capturesMic,
                    onRecordToggle: session.toggleRecording,
                    onMicToggle: session.toggleMic,
                    onEnd: session.endMeeting
                )
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
    }

    private var responseColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let card = responseCard {
                ResponseCard(
                    kind: card.kind.rawValue,
                    text: card.text,
                    streaming: card.streaming,
                    onCopy: { latest in copy(latest) },
                    onDismiss: { session.dismissResponse() },
                    onAIEdit: nil
                )
                // Fade in place — the panel is already widening rightward to
                // make room, so a horizontal slide read as the card "flying in
                // from the left" across the command column.
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        // Animate the card's appearance/disappearance, not every streamed delta —
        // keying the animation on `response` would re-run it on each token and
        // jitter the growing text.
        .animation(.easeOut(duration: 0.18), value: responseCardVisible)
    }

    /// The card to show for the current response, if any — a finished answer or
    /// a streaming one in flight.
    private var responseCard: (kind: GenerationKind, text: String, streaming: Bool)? {
        switch session.response {
        case let .ready(kind, text): (kind, text, false)
        case let .streaming(kind, text): (kind, text, true)
        default: nil
        }
    }

    private var responseCardVisible: Bool {
        responseCard != nil
    }

    // MARK: - Derived

    private var elapsedString: String {
        String(format: "%02d:%02d", session.elapsed / 60, session.elapsed % 60)
    }

    // MARK: - Actions

    private func setLanguagePrompt(_ shown: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { showLanguagePrompt = shown }
    }

    private func startMeeting() {
        // Subscription gate: a locked account (trial ended / canceled) can't
        // record — the proxy 403s transcription anyway, so send them to the
        // paywall instead of failing mid-meeting. An unresolved entitlement
        // (nil — not yet loaded or a transient lookup failure) falls through to
        // the server so a paying user is never blocked client-side.
        if entitlements.entitlement?.isActive == false {
            Log.ui.info("startMeeting blocked — entitlement not active; opening paywall")
            NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            return
        }
        // Consent gate: show the disclaimer modal before any audio capture
        // on the user's first meeting. See issue #4.
        if !consent.isAccepted {
            withAnimation(.easeOut(duration: 0.15)) {
                showConsentDisclaimer = true
            }
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        // Clear the language prompt here (not in the button's own action) so it
        // disappears in the same update that swaps to the recording layout —
        // dismissing it separately first left it mid-removal when the idle
        // branch was yanked, ghosting behind the new content.
        showLanguagePrompt = false
        expanded = true
        session.beginRecording()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("→ Copied to clipboard")
    }
}

/// Carries the floating content's natural height up to `ContentView`'s body so
/// a change can trigger a panel repaint (see `onRedrawNeeded`).
private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Input Device Picker

/// Microphone chooser as a single icon in the panel header (next to Library).
/// The menu lists available inputs and pins the active one — selection writes
/// straight to `audioCapture.preferredInputUID`, same as before; only the
/// trigger moved from a full-width row to this compact glyph.
private struct MicInputPicker: View {
    @ObservedObject var audioCapture: AudioCaptureService
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        // Chrome is drawn separately and matched to `PanelIconButton` (the
        // Library glyph) so the two header icons are pixel-identical; a
        // transparent `Menu` is overlaid only for the click. Putting the chrome
        // inside the Menu's label drops its circle background — `.borderlessButton`
        // re-renders and hugs the label across macOS versions.
        ZStack {
            // `waveform`, not `mic.fill` — a mic glyph collides with the
            // mute toggle (`StatusRow` uses mic/mic.slash) and reads as
            // "mute me" rather than "choose input device".
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.10)))

            Menu {
                menuItems
            } label: {
                Color.clear
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(width: 22, height: 22)
        .help("Microphone — choose input device")
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var menuItems: some View {
        Button(action: { audioCapture.preferredInputUID = nil }) {
            Label("System Default", systemImage: audioCapture.preferredInputUID == nil ? "checkmark" : "")
        }
        Divider()
        ForEach(devices) { device in
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
        Button("Refresh", action: refresh)
    }

    private func refresh() {
        devices = AudioDeviceCatalog.inputDevices()
    }
}

// MARK: - Status Header

private struct StatusHeader: View {
    /// Drives the live level meter (`inputLevel`) and backs the header's mic
    /// chooser, so it's observed directly rather than threaded through props.
    @ObservedObject var audioCapture: AudioCaptureService
    /// Whether the mic chooser icon shows — only when the session captures the
    /// mic and we're pre-meeting, matching where the old picker row appeared.
    let showMicPicker: Bool
    let meeting: MeetingState
    let elapsed: String
    let language: AppLanguage
    let onLanguageSelect: (AppLanguage) -> Void
    var onCollapse: (() -> Void)?
    @State private var pulsing = false
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
            // Only label active states (REC/PAUSED) — idle is the default,
            // and the Start button beneath is its own affordance. "READY"
            // is shouty and didn't carry information the user couldn't
            // infer from the rest of the panel.
            if meeting != .idle {
                Text(meeting.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(meeting.statusTint)
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.50))
                if meeting == .recording {
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
        .onAppear { pulsing = true }
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
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { revealWidth = geo.size.width }
                    .onChange(of: geo.size.width) { revealWidth = $0 }
            })
            .frame(width: iconsExpanded ? revealWidth : 0, alignment: .trailing)
            .opacity(iconsExpanded ? 1 : 0)
            // No clip: the 0-width frame + opacity hide the collapsed icons
            // (and `allowsHitTesting` keeps the invisible ones from catching
            // clicks), so a hover tooltip can extend any direction uncut.
            .allowsHitTesting(iconsExpanded)

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
            Image("NTemplate")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
                .foregroundColor(.white.opacity(0.85))
        case .recording:
            Circle()
                .fill(Color(red: 0.95, green: 0.25, blue: 0.30))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.Palette.warning)
                .frame(width: 8, height: 8)
        }
    }
}

/// Compact 4-bar input meter. Bars light progressively with the live mic
/// peak so a glance confirms audio is flowing. Purely a display — no state,
/// redrawn by its `level` input (~10×/sec from the audio tap).
private struct LevelMeter: View {
    let level: Float
    private static let thresholds: [Float] = [0.02, 0.06, 0.14, 0.30]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.thresholds, id: \.self) { threshold in
                Capsule()
                    .fill(Color.white.opacity(level >= threshold ? 0.85 : 0.18))
                    .frame(width: 2.5, height: 9)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .help("Microphone level")
    }
}

/// Small circular icon button shared by the panel's chrome — the
/// collapse chevron in `StatusHeader` and the pause / end / expand
/// controls in `CollapsedCapsule`. Single source of truth so collapse
/// and expand stay visually identical.
private struct PanelIconButton: View {
    let systemName: String
    var tint: Color = .white.opacity(0.6)
    var fill: Color = .white.opacity(0.10)
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Screen-share visibility as a single icon (no label, to stay compact like the
/// other header buttons): a monitor with an amber eye — open when Nod appears in
/// a screen share, crossed when it's hidden. Tap to flip.
private struct ScreenShareButton: View {
    @EnvironmentObject private var pref: PanelSharingPreference
    private static let amber = Color(hex: 0xFFB454)

    var body: some View {
        let visible = pref.visibleWhenSharing
        Button(action: { pref.visibleWhenSharing.toggle() }) {
            ZStack {
                ScreenFrameShape()
                    .stroke(
                        Color.white.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                    )
                // The eye almond is drawn at a fixed centre; toggling only adds
                // the slash, so the icon never shifts between states.
                EyeShape(crossed: !visible)
                    .stroke(
                        Self.amber,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
            }
            .frame(width: 16.5, height: 16.5)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .panelTooltip(visible ? "Visible when sharing" : "Hidden when sharing")
    }
}

/// Maps a point in the icons' shared 24×24 artwork space into `rect`.
private func pt24(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
}

/// The monitor outline (screen + stand) behind the eye, traced from the supplied
/// 24×24 artwork so it scales crisply and tints with the other header icons.
private struct ScreenFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                origin: pt24(4, 5, in: rect),
                size: CGSize(width: 16 / 24 * rect.width, height: 12 / 24 * rect.height)
            ),
            cornerSize: CGSize(width: 2.5 / 24 * rect.width, height: 2.5 / 24 * rect.height)
        )
        path.move(to: pt24(12, 17, in: rect)); path.addLine(to: pt24(12, 20, in: rect))
        path.move(to: pt24(10, 20, in: rect)); path.addLine(to: pt24(14, 20, in: rect))
        return path
    }
}

/// The amber eye inside the monitor — an almond traced in the same 24×24 space,
/// plus a diagonal slash when `crossed` (Nod hidden from shares).
private struct EyeShape: Shape {
    var crossed: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = pt24(7, 11, in: rect)
        let right = pt24(17, 11, in: rect)
        path.move(to: left)
        path.addQuadCurve(to: right, control: pt24(12, 4.8, in: rect))
        path.addQuadCurve(to: left, control: pt24(12, 17.2, in: rect))
        if crossed {
            path.move(to: pt24(7.5, 6.5, in: rect))
            path.addLine(to: pt24(16.5, 15.5, in: rect))
        }
        return path
    }
}

/// Decelerating ease-out (cubic-bézier 0.22, 1, 0.36, 1 — "easeOutQuint") for a
/// purposeful, settled reveal rather than a flat ease-in-out feel. Reduce Motion
/// collapses it to a quick crossfade with no long deceleration.
private extension Animation {
    static func panelReveal(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .timingCurve(0.22, 1, 0.36, 1, duration: 0.34)
    }
}

/// A small label that fades in just above a header icon while the pointer is
/// over it — a one-word reminder of what the icon does.
private struct PanelTooltip: ViewModifier {
    /// How far the capsule floats above its icon. The panel reserves
    /// `reservedTopSpace` of top inset (see `ContentView`) so the lifted capsule
    /// clears the window's top edge — keep `reservedTopSpace` ≥ `lift` + the
    /// capsule's own height, or tooltips clip again.
    static let lift: CGFloat = 24
    static let reservedTopSpace: CGFloat = 30

    let text: String
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { show = hovering }
            }
            .overlay(alignment: .top) {
                if show {
                    Text(text)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.82)))
                        .offset(y: -Self.lift)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    func panelTooltip(_ text: String) -> some View {
        modifier(PanelTooltip(text: text))
    }
}

private struct PanelMenuButton: View {
    var body: some View {
        Menu {
            Button("Settings…") {
                NotificationCenter.default.post(name: .nodOpenSettings, object: nil)
            }
            Divider()
            Button("Hide Panel") {
                NotificationCenter.default.post(name: .nodHidePanel, object: nil)
            }
            Divider()
            Button("Quit Nod") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More — Settings, Hide Panel, Quit Nod")
    }
}

private struct CollapsedCapsule: View {
    let meeting: MeetingState
    let elapsed: String
    let language: AppLanguage
    let onExpand: () -> Void
    let onRecordToggle: () -> Void
    let onEnd: () -> Void
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            indicator
            Text(meeting.statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(meeting.statusTint)
            Text(elapsed)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
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

            Spacer(minLength: 6)

            PanelIconButton(
                systemName: meeting == .paused ? "play.fill" : "pause.fill",
                tint: meeting == .paused
                    ? Color(red: 0.62, green: 0.90, blue: 0.72)
                    : .white.opacity(0.80),
                help: meeting == .paused ? "Resume" : "Pause",
                action: onRecordToggle
            )
            PanelIconButton(
                systemName: "stop.fill",
                tint: Color(red: 0.95, green: 0.45, blue: 0.50),
                fill: Color(red: 0.55, green: 0.18, blue: 0.22).opacity(0.40),
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
        .onAppear { pulsing = true }
    }

    @ViewBuilder private var indicator: some View {
        switch meeting {
        case .recording:
            Circle()
                .fill(Color(red: 0.95, green: 0.25, blue: 0.30))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.Palette.warning)
                .frame(width: 8, height: 8)
        case .idle:
            // Shouldn't render in idle — leftColumn guards this — but safe fallback.
            Circle().fill(Color.white.opacity(0.3)).frame(width: 8, height: 8)
        }
    }
}

private struct LanguagePicker: View {
    let current: AppLanguage
    let onSelect: (AppLanguage) -> Void

    var body: some View {
        // A round 22×22 icon that matches the mic / Library glyphs in the
        // header, but its "glyph" is the active language's 2-letter code so the
        // current language still reads at a glance. The chrome is drawn
        // separately and a transparent `Menu` is overlaid only for the click —
        // the Menu wraps a real `Picker` so SwiftUI keeps selection semantics
        // (VoiceOver announces the choice) and the non-activating panel doesn't
        // eat the first click. Putting the chrome inside the Menu label drops
        // its circle background, same quirk handled in `MicInputPicker`.
        ZStack {
            Text(current.chipLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.10)))

            Menu {
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
            } label: {
                Color.clear
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(width: 22, height: 22)
        .help("Switch Nod language — applies to summaries, titles, cards, and answers")
    }
}

/// Raycast-style command pill. Frosted dark capsule, neutral mic glyph,
/// "Start meeting" label. The glyph is deliberately NOT a red record dot —
/// red is reserved for the active REC state, and a red dot on the *start*
/// affordance reads for a beat as "already recording".
/// No kbd-shortcut badge — `.keyboardShortcut` on a `.nonactivatingPanel`
/// doesn't fire because the panel rarely becomes key; showing a hint for a
/// non-functional shortcut is worse than no hint.
private struct StartMeetingButton: View {
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
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 42)
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

/// Three-way segmented control for what the next recording is. Icon-over-
/// caption segments so the labels fit the compact panel width. The selection
/// drives audio-stream choice, the recap framing, and which live cards show.
private struct SessionKindPicker: View {
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
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        )
    }

    private func segment(_ kind: SessionKind) -> some View {
        let isSelected = selection == kind
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { selection = kind }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(kind.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

// MARK: - Hero

private struct HeroButton: View {
    let isGenerating: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var shimmering = false

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
                        .opacity(shimmering ? 0.65 : 1.0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: shimmering)
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
        .onAppear { shimmering = true }
    }
}

// MARK: - Suggestion pill

private struct SuggestionPill: View {
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

// MARK: - Status Row

private struct StatusRow: View {
    let meeting: MeetingState
    let micMuted: Bool
    var showMic: Bool = true
    let onRecordToggle: () -> Void
    let onMicToggle: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(action: onRecordToggle) {
                Image(systemName: meeting == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(meeting == .paused
                        ? Color(red: 0.62, green: 0.90, blue: 0.72)
                        : .white.opacity(0.85))
            }

            if showMic {
                StatusIcon(action: onMicToggle) {
                    Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(micMuted
                            ? Color(red: 0.95, green: 0.55, blue: 0.55)
                            : .white.opacity(0.85))
                }
            }

            Spacer(minLength: 0)

            Button(action: onEnd) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("End")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.50))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.55, green: 0.18, blue: 0.22).opacity(0.4))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color(red: 0.95, green: 0.45, blue: 0.50).opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusIcon<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.17, blue: 0.22))
                content
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

/// Blocking screen shown when the running build is below the server
/// `minimum_build` — a backend change has made this version unusable, so the
/// only path forward is to update. Covers the whole panel and eats input.
private struct UpdateRequiredOverlay: View {
    let onUpdate: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(DesignTokens.Palette.electricBlue)
                Text("Update to keep using Nod")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(
                    "This version is out of date. Update to the latest to keep recording and summarizing — your meetings are saved to your account, so nothing is lost."
                )
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                Button(action: onUpdate) {
                    Text("Update & Relaunch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.GlassButton.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 280)
            .background(
                ZStack {
                    PanelMaterial()
                    Color.black.opacity(0.25)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            )
            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
            .padding(16)
        }
    }
}

/// Dismissible nudge for a build below `recommended_build` but still usable.
private struct UpdateBanner: View {
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DesignTokens.Palette.electricBlue)
            Text("A new version of Nod is available")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Update", action: onUpdate)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DesignTokens.Palette.electricBlue)
                .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                PanelMaterial()
                Color.black.opacity(0.18)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct SaveErrorToast: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(2)

            Spacer(minLength: 8)

            if canRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(
            ZStack {
                PanelMaterial()
                Theme.Palette.bgSoft.opacity(0.50)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}

#Preview {
    let llm = OpenRouterClient()
    let language = LanguagePreference()
    // Use a dedicated UserDefaults suite so previewing the Acknowledge flow
    // doesn't taint the developer's installed app's consent state.
    let previewDefaults = UserDefaults(suiteName: "nod.preview.consent") ?? .standard
    let supabase = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.anonKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)
        )
    )
    let auth = AuthService(client: supabase)
    let audioCapture = AudioCaptureService()
    let transcriptStore = TranscriptStore(client: llm)
    let meetingStore = MeetingStore(supabase: supabase)
    let profileStore = ProfileStore(supabase: supabase, auth: auth)
    let session = MeetingSession(
        audioCapture: audioCapture,
        store: transcriptStore,
        llm: llm,
        meetingStore: meetingStore,
        entityStore: EntityStore(supabase: supabase),
        knowledgeStore: KnowledgeStore(llm: llm),
        language: language,
        auth: auth,
        profileStore: profileStore,
        outbox: MeetingOutbox()
    )
    return ContentView()
        .environmentObject(session)
        .environmentObject(audioCapture)
        .environmentObject(language)
        .environmentObject(ConsentPreference(defaults: previewDefaults))
        .environmentObject(UpdateGate(supabase: supabase))
        .environmentObject(EntitlementService(supabase: supabase))
        .environmentObject(HotkeyManager())
        .environmentObject(PanelSharingPreference())
        .background(Color.gray.opacity(0.3))
}
