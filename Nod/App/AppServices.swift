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
    let productAnalytics: ProductAnalytics
    let emailPreferences: EmailPreferenceService
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
    let integrations: IntegrationService
    let taskDrafts: TaskDraftComposer
    let panelSharing: PanelSharingPreference
    /// How eagerly the live meeting analyst interrupts — see
    /// `ProactivityPreference.Level`.
    let proactivityPreference: ProactivityPreference
    /// What launch puts on screen — main window, capture panel, or nothing.
    let launchBehavior: LaunchBehavior
    /// Whether Nod offers to record a call it sees starting, and which apps it
    /// stays quiet about. The detector itself lives with the panel's session.
    let meetingDetection: MeetingDetectionPreference
    /// Reads the user's own calendar, on the device, so a detected call can be
    /// named. Off until switched on in Settings.
    let calendar: CalendarService
    /// Arms the scripted landing-page demo. Reads its own defaults, so a
    /// recording session survives relaunches between takes.
    let demoPlayback: DemoPlayback
    let captureSurface: CaptureSurfacePreference
    let updateGate: UpdateGate
    /// Which Sparkle channel this account may see builds from. Refreshed at
    /// launch so the answer is cached before Sparkle's first update check.
    let releaseChannel: ReleaseChannelStore
    let hotkeys: HotkeyManager
    /// User's meeting modes (recap/reply/kind presets), shared by the panel chip
    /// and the Settings editor.
    let modeStore: ModeStore
    /// Offline transcript import from Granola's local cache — a low-cost
    /// migration path off a direct competitor.
    let granolaImporter: GranolaImporter
    /// Rebuilds recaps for meetings whose generation never landed.
    let summaryRegeneration: SummaryRegeneration
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
                    storage: AuthSessionStorage(),
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
        let auth = AuthService(client: supabase)
        let llmClient = LLMProxyClient(supabase: supabase)
        // Free the single-device slot on every sign-out path (menu, forced
        // device-conflict), while the token is still valid.
        let transcriptStore = TranscriptStore(client: llmClient)
        let integrations = IntegrationService(supabase: supabase)
        let consent = ConsentPreference(
            supabase: supabase,
            auth: auth
        )
        let onboardingTelemetry = OnboardingTelemetry(supabase: supabase, auth: auth)
        let productAnalytics = ProductAnalytics(supabase: supabase, auth: auth)
        let emailPreferences = EmailPreferenceService(supabase: supabase, auth: auth, analytics: productAnalytics)
        // Every sign-out path frees the device slot and drops the previous
        // account's email choices, so the next person to sign in starts blank.
        auth.onSignOut = { [weak llmClient, weak emailPreferences] in
            await llmClient?.releaseDevice()
            emailPreferences?.clear()
        }

        audioCapture.onMicBuffer = { [weak transcriptStore] buffer in
            transcriptStore?.appendMicBuffer(buffer)
        }
        audioCapture.onSystemBuffer = { [weak transcriptStore] buffer in
            transcriptStore?.appendSystemBuffer(buffer)
        }

        let meetingStore = MeetingStore(supabase: supabase)
        let profileStore = ProfileStore(supabase: supabase, auth: auth)
        let knowledgeStore = KnowledgeStore(llm: llmClient, supabase: supabase)
        // A trashed or restored meeting changes which chunks are retrievable;
        // the cache is keyed only on query text and can't notice that itself.
        meetingStore.onTrashChange.subscribe { [weak knowledgeStore] in knowledgeStore?.invalidateCache() }
        let screenExclusions = ScreenExclusions()
        let screenContext = ScreenContextService(supabase: supabase, exclusions: screenExclusions)
        let entitlements = EntitlementService(supabase: supabase)
        // Ambient capture has to *act* on the entitlement, not just render it, so
        // it's mirrored here once instead of at each of the four `refresh()`
        // call sites. `mayUse` (not `can`) on purpose: a transient lookup failure
        // must not stop a paying subscriber's capture, and the
        // `screen_observations` RLS policy is the gate that actually holds.
        entitlements.onChange = { [weak screenContext] entitlement in
            guard let screenContext else { return }
            // nil is sign-out, so capture stops. A *failed* refresh never fires
            // this, which is where the fail-open lives: the last known answer
            // stands rather than a hiccup revoking a subscriber's feature.
            screenContext.setEntitled(entitlement?.isActive == true && entitlement?.can(.ambientContext) == true)
        }
        let labelStore = LabelStore(supabase: supabase, auth: auth)
        let entityStore = EntityStore(supabase: supabase)
        let actionItemStore = ActionItemStore(supabase: supabase) { reference, done in
            await integrations.setTaskClosed(done, reference: reference)
        }
        let knowledgeThreads = KnowledgeThreadStore(supabase: supabase)
        let retrievalFeedback = RetrievalFeedbackStore(supabase: supabase)
        let modeStore = ModeStore()

        return AppServices(
            permissions: permissions,
            onboarding: onboarding,
            onboardingTelemetry: onboardingTelemetry,
            productAnalytics: productAnalytics,
            emailPreferences: emailPreferences,
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
                integrations: integrations,
                screenContext: screenContext
            ),
            knowledgeThreads: knowledgeThreads,
            labelStore: labelStore,
            entitlements: entitlements,
            billing: BillingService(supabase: supabase),
            referral: ReferralService(supabase: supabase),
            accountExport: AccountExportService(supabase: supabase),
            connections: ConnectionService(supabase: supabase),
            integrations: integrations,
            taskDrafts: TaskDraftComposer(
                llm: llmClient,
                meetings: meetingStore,
                language: languagePreference
            ),
            panelSharing: PanelSharingPreference(),
            proactivityPreference: ProactivityPreference(),
            launchBehavior: LaunchBehavior(),
            meetingDetection: MeetingDetectionPreference(),
            calendar: CalendarService(),
            demoPlayback: DemoPlayback(),
            captureSurface: CaptureSurfacePreference(),
            updateGate: UpdateGate(supabase: supabase),
            releaseChannel: ReleaseChannelStore(supabase: supabase, auth: auth),
            hotkeys: hotkeys,
            modeStore: modeStore,
            granolaImporter: GranolaImporter(
                meetingStore: meetingStore,
                auth: auth,
                language: languagePreference
            ),
            summaryRegeneration: SummaryRegeneration(
                llm: llmClient,
                meetingStore: meetingStore,
                actionItemStore: actionItemStore,
                knowledgeStore: knowledgeStore,
                profileStore: profileStore,
                modeStore: modeStore,
                entitlements: entitlements
            ),
            screenExclusions: screenExclusions,
            screenContext: screenContext,
            settingsFocus: SettingsFocus()
        )
    }
}
