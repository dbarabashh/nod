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
    let audioCapture: AudioCaptureService
    let llmClient: OpenRouterClient
    let transcriptStore: TranscriptStore
    let languagePreference: LanguagePreference
    let supabase: SupabaseClient
    let auth: AuthService
    let consent: ConsentPreference
    let meetingStore: MeetingStore
    let profileStore: ProfileStore
    let chatStore: ChatStore
    let entityStore: EntityStore
    let knowledgeStore: KnowledgeStore
    let labelStore: LabelStore
    let entitlements: EntitlementService
    let billing: BillingService
    let panelSharing: PanelSharingPreference
    let updateGate: UpdateGate
    let hotkeys: HotkeyManager

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
        let llmClient = OpenRouterClient(supabase: supabase)
        // Free the single-device slot on every sign-out path (menu, forced
        // device-conflict), while the token is still valid.
        auth.onSignOut = { [weak llmClient] in await llmClient?.releaseDevice() }
        let transcriptStore = TranscriptStore(client: llmClient)
        let consent = ConsentPreference(
            supabase: supabase,
            auth: auth
        )

        audioCapture.onMicBuffer = { [weak transcriptStore] buffer in
            transcriptStore?.appendMicBuffer(buffer)
        }
        audioCapture.onSystemBuffer = { [weak transcriptStore] buffer in
            transcriptStore?.appendSystemBuffer(buffer)
        }

        return AppServices(
            permissions: permissions,
            onboarding: onboarding,
            audioCapture: audioCapture,
            llmClient: llmClient,
            transcriptStore: transcriptStore,
            languagePreference: languagePreference,
            supabase: supabase,
            auth: auth,
            consent: consent,
            meetingStore: MeetingStore(supabase: supabase),
            profileStore: ProfileStore(supabase: supabase, auth: auth),
            chatStore: ChatStore(supabase: supabase, llm: llmClient),
            entityStore: EntityStore(supabase: supabase),
            knowledgeStore: KnowledgeStore(llm: llmClient),
            labelStore: LabelStore(supabase: supabase, auth: auth),
            entitlements: EntitlementService(supabase: supabase),
            billing: BillingService(supabase: supabase),
            panelSharing: PanelSharingPreference(),
            updateGate: UpdateGate(supabase: supabase),
            hotkeys: hotkeys
        )
    }
}
