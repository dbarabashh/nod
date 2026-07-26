import Foundation
import Supabase

/// Every long-lived service, constructed exactly once per launch by
/// `make()` and owned by AppDelegate. Non-optional fields replace the old
/// twenty optional properties + per-window `guard let` walls: once the
/// struct exists, the whole graph exists.
@MainActor
struct AppServices {
    let permissions: PermissionManager
    let onboarding: OnboardingState
    /// Server-side funnel log for the onboarding steps — the only signal we
    /// have for where a new user stops, since `OnboardingState` is local-only.
    let onboardingTelemetry: OnboardingTelemetry
    let audioCapture: AudioCaptureService
    let llmClient: LLMProxyClient
    let transcriptStore: TranscriptStore
    let languagePreference: LanguagePreference
    let supabase: SupabaseClient
    let auth: AuthService
    let consent: ConsentPreference
    let meetingStore: MeetingStore
    /// Durable on-disk WAL + retry queue for meeting persistence — replayed on
    /// launch so an interrupted or failed save isn't lost with the process.
    let meetingOutbox: MeetingOutbox
    let profileStore: ProfileStore
    let chatStore: ChatStore
    let entityStore: EntityStore
    /// First-class action items extracted from each meeting's recap — checkable
    /// to-dos persisted in `action_items`, surfaced in the meeting body and the
    /// History aggregate.
    let actionItemStore: ActionItemStore
    let knowledgeStore: KnowledgeStore
    /// The cross-session "Ask Nod" thread. One instance app-wide, so the
    /// Library dock and the launcher panel are two views onto one conversation.
    let knowledgeChat: KnowledgeChatStore
    /// Saved cross-session conversations, listed and reopened from the rail.
    let knowledgeThreads: KnowledgeThreadStore
    let labelStore: LabelStore
    let entitlements: EntitlementService
    let billing: BillingService
    let referral: ReferralService
    let accountExport: AccountExportService
    let connections: ConnectionService
    let panelSharing: PanelSharingPreference
    /// What launch puts on screen — main window, capture panel, or nothing.
    let launchBehavior: LaunchBehavior
    /// Whether Nod offers to record a call it sees starting, and which apps it
    /// stays quiet about. The detector itself lives with the panel's session.
    let meetingDetection: MeetingDetectionPreference
    let updateGate: UpdateGate
    let hotkeys: HotkeyManager
    /// User's meeting modes (recap/reply/kind presets), shared by the panel chip
    /// and the Settings editor.
    let modeStore: ModeStore
    /// Offline transcript import from Granola's local cache — a low-cost
    /// migration path off a direct competitor.
    let granolaImporter: GranolaImporter
    /// Apps and websites the user has put off-limits to screen reading.
    let screenExclusions: ScreenExclusions
    /// Ambient screen capture. Constructed always, running only when the user
    /// has switched it on — see `ScreenContextDefaults`.
    let screenContext: ScreenContextService
    /// Pending "open Settings on this pane" request, shared by the deep links
    /// that raise it and the window that renders Settings.
    let settingsFocus: SettingsFocus

    /// Construction ORDER is load-bearing — Supabase before the LLM client,
    /// auth before the stores that read it, callback wiring last.
    static func make() -> AppServices {
        // Constructing HotkeyManager registers the Carbon hotkeys; keep it
        // first so registration timing matches the old lazy `.shared` touch
        // at the top of applicationDidFinishLaunching.
        let hotkeys = HotkeyManager()
        let permissions = PermissionManager()
        let onboarding = OnboardingState()
        let audioCapture = AudioCaptureService()
        let languagePreference = LanguagePreference()
        // Supabase client must exist before the LLM client — all LLM traffic
        // is JWT-authenticated through the `llm-proxy` Edge Function (#11).
        // Opt into the new authStateChanges behavior — the SDK emits the
        // locally stored session immediately as `.initialSession`, even if
        // expired, and refreshes in the background. AuthService treats an
        // expired session as nil so the UI doesn't flip to "signed in"
        // with an unusable token. See supabase-swift PR #822.
        let supabase = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
        let auth = AuthService(client: supabase)
        let llmClient = LLMProxyClient(supabase: supabase)
        // Free the single-device slot on every sign-out path (menu, forced
        // device-conflict), while the token is still valid.
        auth.onSignOut = { [weak llmClient] in await llmClient?.releaseDevice() }
        let transcriptStore = TranscriptStore(client: llmClient)
        let consent = ConsentPreference(
            supabase: supabase,
            auth: auth
        )
        let onboardingTelemetry = OnboardingTelemetry(supabase: supabase, auth: auth)

        audioCapture.onMicBuffer = { [weak transcriptStore] buffer in
            transcriptStore?.appendMicBuffer(buffer)
        }
        audioCapture.onSystemBuffer = { [weak transcriptStore] buffer in
            transcriptStore?.appendSystemBuffer(buffer)
        }

        let meetingStore = MeetingStore(supabase: supabase)
        let profileStore = ProfileStore(supabase: supabase, auth: auth)
        let knowledgeStore = KnowledgeStore(llm: llmClient)
        let screenExclusions = ScreenExclusions()
        let screenContext = ScreenContextService(supabase: supabase, exclusions: screenExclusions)
        let labelStore = LabelStore(supabase: supabase, auth: auth)
        let entityStore = EntityStore(supabase: supabase)
        let actionItemStore = ActionItemStore(supabase: supabase)
        let knowledgeThreads = KnowledgeThreadStore(supabase: supabase)
        let retrievalFeedback = RetrievalFeedbackStore(supabase: supabase)

        return AppServices(
            permissions: permissions,
            onboarding: onboarding,
            onboardingTelemetry: onboardingTelemetry,
            audioCapture: audioCapture,
            llmClient: llmClient,
            transcriptStore: transcriptStore,
            languagePreference: languagePreference,
            supabase: supabase,
            auth: auth,
            consent: consent,
            meetingStore: meetingStore,
            meetingOutbox: MeetingOutbox(),
            profileStore: profileStore,
            chatStore: ChatStore(supabase: supabase, llm: llmClient),
            entityStore: entityStore,
            actionItemStore: actionItemStore,
            knowledgeStore: knowledgeStore,
            knowledgeChat: KnowledgeChatStore(
                llm: llmClient,
                knowledge: knowledgeStore,
                meetings: meetingStore,
                labels: labelStore,
                profile: profileStore,
                language: languagePreference,
                entities: entityStore,
                actionItems: actionItemStore,
                threads: knowledgeThreads,
                feedback: retrievalFeedback,
                screenContext: screenContext
            ),
            knowledgeThreads: knowledgeThreads,
            labelStore: labelStore,
            entitlements: EntitlementService(supabase: supabase),
            billing: BillingService(supabase: supabase),
            referral: ReferralService(supabase: supabase),
            accountExport: AccountExportService(supabase: supabase),
            connections: ConnectionService(supabase: supabase),
            panelSharing: PanelSharingPreference(),
            launchBehavior: LaunchBehavior(),
            meetingDetection: MeetingDetectionPreference(),
            updateGate: UpdateGate(supabase: supabase),
            hotkeys: hotkeys,
            modeStore: ModeStore(),
            granolaImporter: GranolaImporter(
                meetingStore: meetingStore,
                auth: auth,
                language: languagePreference
            ),
            screenExclusions: screenExclusions,
            screenContext: screenContext,
            settingsFocus: SettingsFocus()
        )
    }
}
