import AppKit
import Supabase
import SwiftUI

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var session: MeetingSession
    @EnvironmentObject private var audioCapture: AudioCaptureService
    @EnvironmentObject private var language: LanguagePreference
    @EnvironmentObject private var consent: ConsentPreference
    @EnvironmentObject private var updateGate: UpdateGate
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var hotkey: HotkeyManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// The user's meeting modes and the active one. Selecting a mode sets the
    /// session's kind and mirrors its recap/reply framing into the existing
    /// defaults the generation paths already read; authoring lives in Settings.
    @EnvironmentObject private var modeStore: ModeStore
    /// True while the recording-consent modal is on screen; gates startMeeting()
    /// before audio capture begins. See issue #4.
    @State private var showConsentDisclaimer: Bool = false
    /// True while the per-meeting language confirm is on screen. Shown when the
    /// user taps Start so a stale language pin can't silently carry into a new
    /// meeting; on confirm we fall through to the consent gate / recording.
    @State private var showLanguagePrompt: Bool = false
    /// Draft text in the live "Ask" box during a recording. Cleared on send.
    @State private var askText: String = ""
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

    /// Live Ask is a Pro capability. Fail OPEN on an unresolved entitlement (nil /
    /// load failure): the paywall is the real gate, so a Pro user whose fetch
    /// transiently failed isn't wrongly locked out. Mirrors `KnowledgeChatView`.
    private var canAskLive: Bool {
        entitlements.entitlement == nil || entitlements.can(.askLive)
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
                        withAnimation(.standard(reduceMotion: reduceMotion)) {
                            showConsentDisclaimer = false
                        }
                    },
                    onAcknowledge: { dontShowAgain in
                        // Always log the legal acknowledgement; "Don't show
                        // again" only controls the local UX gate.
                        consent.acknowledge(persistGate: dontShowAgain)
                        withAnimation(.standard(reduceMotion: reduceMotion)) {
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

            if let prompt = session.autoEndPrompt {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    InactivityPrompt(
                        prompt: prompt,
                        keepTitle: session.selectedKind.continueActionTitle,
                        onKeep: session.keepRecording,
                        onEnd: session.endMeeting
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .zIndex(2)
                .transition(.edgeSlide(.bottom, reduceMotion: reduceMotion))
            }
        }
        .animation(.momentum(reduceMotion: reduceMotion), value: session.autoEndPrompt != nil)
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
        // Both, and not just the change: the auto-detect card can be clicked
        // while this view has never been mounted (the panel is built at launch
        // but only shown on request), so the request is picked up on whichever
        // of the two happens second.
        .onAppear(perform: consumeAutoStart)
        .onChange(of: session.wantsAutoStart) { _ in consumeAutoStart() }
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
                kind: session.selectedKind,
                elapsed: elapsedString,
                language: language.current,
                onExpand: {
                    withAnimation(.standard(reduceMotion: reduceMotion)) { expanded = true }
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
                modeStore: modeStore,
                onManageModes: { NotificationCenter.default.post(name: .nodOpenModes, object: nil) },
                showMode: session.selectedKind == .meeting,
                showMicPicker: session.meeting == .idle && session.selectedKind.capturesMic,
                meeting: session.meeting,
                kind: session.selectedKind,
                elapsed: elapsedString,
                language: language.current,
                onLanguageSelect: { language.current = $0 },
                onCollapse: session.meeting != .idle ? {
                    withAnimation(.standard(reduceMotion: reduceMotion)) { expanded = false }
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
                // The live Ask box — type a free-form question about what's being
                // said when the fixed pills don't cover it. Sits above them as the
                // open-ended entry point; the pills below are the one-tap shortcuts.
                AskComposer(
                    text: $askText,
                    enabled: session.meeting == .recording,
                    isBusy: session.isGenerating(for: .ask),
                    locked: !canAskLive,
                    onSend: { question in
                        // Pro-gated. Non-Pro sees the box (discovery) but a send
                        // opens the paywall instead of asking — same invisible
                        // gate as Start meeting.
                        guard canAskLive else {
                            NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                            return
                        }
                        session.ask(question)
                    }
                )

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
        .animation(.standard(reduceMotion: reduceMotion), value: responseCardVisible)
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
        withAnimation(.standard(reduceMotion: reduceMotion)) { showLanguagePrompt = shown }
    }

    /// Something outside the panel — the auto-detect card — asked to record.
    /// It takes the same route as the Start button, language confirm included:
    /// a detected meeting is still a meeting the user has to be told about
    /// before Nod listens to it.
    private func consumeAutoStart() {
        guard session.wantsAutoStart, session.meeting == .idle else { return }
        session.clearAutoStartRequest()
        if confirmLanguageBeforeMeeting {
            setLanguagePrompt(true)
        } else {
            startMeeting()
        }
    }

    private func startMeeting() {
        Task { @MainActor in
            // Subscription gate. The proxy serves `transcribe` even on a lapsed
            // plan (it never cuts a live meeting), so this client check is the
            // ONLY thing that blocks a NEW meeting — refresh first so it reflects
            // a lapse that happened since the last sync, not a stale cache. An
            // unresolved entitlement (nil — never loaded, or a refresh that just
            // failed) falls through so a paying user is never blocked on a blip.
            await entitlements.refresh()
            if entitlements.entitlement?.isActive == false {
                Log.ui.info("startMeeting blocked — entitlement not active; opening paywall")
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                return
            }
            // Consent gate: show the disclaimer modal before any audio capture
            // on the user's first meeting. See issue #4.
            if !consent.isAccepted {
                withAnimation(.standard(reduceMotion: reduceMotion)) {
                    showConsentDisclaimer = true
                }
                return
            }
            beginRecording()
        }
    }

    private func beginRecording() {
        // Clear the language prompt here (not in the button's own action) so it
        // disappears in the same update that swaps to the recording layout —
        // dismissing it separately first left it mid-removal when the idle
        // branch was yanked, ghosting behind the new content.
        showLanguagePrompt = false
        // Drop any half-typed Ask draft so it can't carry into the new meeting,
        // same discipline as showLanguagePrompt above.
        askText = ""
        expanded = true
        session.beginRecording()
    }

    private func copy(_ text: String) {
        NSPasteboard.copyRichText(markdown: text)
        Log.ui.info("Copied response to clipboard")
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

#Preview {
    let llm = LLMProxyClient()
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
    let modeStore = ModeStore()
    let session = MeetingSession(
        audioCapture: audioCapture,
        store: transcriptStore,
        llm: llm,
        meetingStore: meetingStore,
        entityStore: EntityStore(supabase: supabase),
        knowledgeStore: KnowledgeStore(llm: llm, supabase: supabase),
        actionItemStore: ActionItemStore(supabase: supabase),
        language: language,
        auth: auth,
        profileStore: profileStore,
        outbox: MeetingOutbox(),
        modeStore: modeStore,
        screenExclusions: ScreenExclusions(defaults: previewDefaults)
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
        .environmentObject(modeStore)
        .background(Color.gray.opacity(0.3))
}
