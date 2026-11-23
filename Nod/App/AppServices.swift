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
    /// When this run of the app began, for the length of it at the end.
    let launchedAt = Date()
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
    /// The link's state, published for the chat surfaces. Not a pre-flight
    /// gate — see `NetworkReachability`.
    let reachability: NetworkReachability
    let entityStore: EntityStore
    /// First-class action items extracted from each meeting's recap — checkable
    /// to-dos persisted in `action_items`, surfaced in the meeting body and the
    /// History aggregate.
    let actionItemStore: ActionItemStore
    /// The day's briefing — the calendar still ahead, the commitments still
    /// open, and the questions recent sessions left hanging.
    let knowledgeStore: KnowledgeStore
    /// The cross-session "Ask Nod" thread. One instance app-wide, so the
    /// Library dock and the launcher panel are two views onto one conversation.
    let knowledgeChat: KnowledgeChatStore
    /// A live spoken conversation's own bounded thread — see `voiceChat` in
    /// `init`.
    let voiceChat: KnowledgeChatStore
    /// Saved cross-session conversations, listed and reopened from the rail.
    let knowledgeThreads: KnowledgeThreadStore
    let agentStore: AgentStore
    /// Saved questions that ask themselves on a schedule, and what came of
    /// each run.
    let beats: BeatStore
    /// Answers those questions when they come due and this Mac is awake.
    let beatRunner: BeatRunner
    let labelStore: LabelStore
    /// Which finished meetings have been handed to a team or the organization.
    let meetingGrants: MeetingGrantStore
    /// Calendars connected through Integrations, which EventKit cannot see.
    let remoteCalendar: RemoteCalendar
    let entitlements: EntitlementService
    let billing: BillingService
    let referral: ReferralService
    let accountExport: AccountExportService
    let meetingMigration: MeetingMigration
    let connections: ConnectionService
    let integrations: IntegrationService
    let integrationCatalogue: IntegrationCatalogue
    let actionProposals: ActionProposalStore
    let rooms: RoomListenerService
    let organizations: OrganizationService
    /// Push side of shared access. Held here so the composition root can start it
    /// once a session exists and tear it down when one stops.
    let accessChannel: AccessChannel
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
    /// How much a connected product may be reached without a card.
    let toolApproval: ToolApprovalPreference
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
    /// Which theme Nod paints in, and whether its windows blur what's behind
    /// them. Applied to `NSApp` at launch and on every change.
    let appearance: AppearancePreference

    /// Construction ORDER is load-bearing — Supabase before the LLM client,
    /// auth before the stores that read it, callback wiring last.
    static func make() async -> AppServices {
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
        // Ahead of everything else, because everything else is what a stall
        // here would hold up — and ahead of the hotkeys in particular, since a
        // combination registered before `onTrigger` is wired is claimed
        // system-wide and answered by nobody.
        await warmSessionStorage(supabase)
        let hotkeys = HotkeyManager()
        let permissions = PermissionManager()
        let onboarding = OnboardingState()
        let audioCapture = AudioCaptureService()
        let languagePreference = LanguagePreference()
        let auth = AuthService(client: supabase)
        let llmClient = LLMProxyClient(supabase: supabase)
        // Free the single-device slot on every sign-out path (menu, forced
        // device-conflict), while the token is still valid.
        let transcriptStore = TranscriptStore(client: llmClient)
        let integrations = IntegrationService(supabase: supabase)
        let integrationCatalogue = IntegrationCatalogue(supabase: supabase)
        let rooms = RoomListenerService(supabase: supabase, llm: llmClient)
        let consent = ConsentPreference(
            supabase: supabase,
            auth: auth
        )
        let productAnalytics = ProductAnalytics(supabase: supabase, auth: auth)
        // Set here rather than taken in the initializer: `integrations` is built
        // before the analytics client exists, and reordering the graph to suit a
        // reporting dependency would put the tail before the dog.
        integrations.analytics = productAnalytics
        let onboardingTelemetry = OnboardingTelemetry(
            supabase: supabase,
            auth: auth,
            analytics: productAnalytics
        )
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
        let screenContext = ScreenContextService(
            supabase: supabase,
            exclusions: screenExclusions,
            analytics: productAnalytics
        )
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
        let meetingGrants = MeetingGrantStore(supabase: supabase)
        let remoteCalendar = RemoteCalendar(supabase: supabase)
        remoteCalendar.follow(integrations)
        let calendar = CalendarService()
        calendar.remote = remoteCalendar
        let organizations = OrganizationService(supabase: supabase)
        // The closure re-asks and then re-subscribes: a membership change is
        // both the thing to refresh for and the thing that changes which
        // audiences are worth listening to.
        weak var accessChannelBox: AccessChannel?
        let refresh = AccessRefresh(
            organizations: organizations,
            labels: labelStore,
            meetings: meetingStore,
            grants: meetingGrants,
            rooms: rooms
        )
        let accessChannel = AccessChannel(supabase: supabase) {
            await refresh.run()
            guard let organizations = refresh.organizations else { return }
            await accessChannelBox?.resubscribe(
                orgIDs: organizations.memberships.map(\.id),
                teamIDs: Array(organizations.myTeamIDs)
            )
        }
        accessChannelBox = accessChannel
        let entityStore = EntityStore(supabase: supabase)
        let actionItemStore = ActionItemStore(supabase: supabase) { reference, done in
            await integrations.setTaskClosed(done, reference: reference)
        }
        let actionProposals = ActionProposalStore(supabase: supabase)
        let knowledgeThreads = KnowledgeThreadStore(supabase: supabase)
        let retrievalFeedback = RetrievalFeedbackStore(supabase: supabase)
        let meetingOutbox = MeetingOutbox()
        Task { await meetingOutbox.attach(productAnalytics) }
        let modeStore = ModeStore()
        modeStore.analytics = productAnalytics
        actionItemStore.analytics = productAnalytics
        meetingStore.analytics = productAnalytics
        labelStore.analytics = productAnalytics
        organizations.analytics = productAnalytics
        calendar.analytics = productAnalytics
        let beats = BeatStore(supabase: supabase, auth: auth)
        beats.analytics = productAnalytics
        let toolApproval = ToolApprovalPreference()
        let toolApprovalLog = ToolApprovalLog(supabase: supabase, auth: auth)
        // Three chats, one recipe: the attended one on screen, and one
        // unattended store per background writer (beats, agents) so a run at
        // 09:00 can't clear a conversation somebody is typing into — and so a
        // new dependency is threaded in exactly one place.
        func makeChat(
            unattended: Bool,
            readsRunUnasked: Bool = false,
            // No default: a chat that shows cards has to be handed the
            // preference, or "Always allow" writes a decision nothing reads.
            // A chat whose reads run unasked shows no card and takes nil.
            toolApproval: ToolApprovalPreference?,
            toolLog: ToolApprovalLog? = nil,
            maxTurns: Int? = nil
        ) -> KnowledgeChatStore {
            KnowledgeChatStore(
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
                screenContext: screenContext,
                calendar: calendar,
                beats: beats,
                organizations: organizations,
                unattended: unattended,
                readsRunUnasked: readsRunUnasked,
                toolApproval: toolApproval,
                toolLog: toolLog,
                maxTurns: maxTurns
            )
        }
        let beatChat = makeChat(unattended: true, toolApproval: nil)
        // The agents' own unattended chat — see `makeChat`.
        let agentChat = makeChat(unattended: true, toolApproval: nil)
        // A live voice conversation's own thread — never the Library's. It
        // remembers the last five exchanges so a follow-up ("and tomorrow?")
        // resolves without carrying the whole call's history forward forever,
        // and it survives the live session itself ending (a slipped tap, a
        // dropped connection) since it lives here, not inside the session.
        let voiceChat = makeChat(unattended: false, readsRunUnasked: true, toolApproval: nil, maxTurns: 5)
        let knowledgeChat = makeChat(unattended: false, toolApproval: toolApproval, toolLog: toolApprovalLog)
        knowledgeChat.analytics = productAnalytics
        let agentStore = AgentStore(
            supabase: supabase,
            chat: agentChat,
            threads: knowledgeThreads,
            llm: llmClient,
            proposals: actionProposals
        )

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
            meetingOutbox: meetingOutbox,
            profileStore: profileStore,
            chatStore: ChatStore(
                supabase: supabase,
                llm: llmClient,
                integrations: integrations,
                toolApproval: toolApproval,
                toolLog: toolApprovalLog
            ),
            reachability: NetworkReachability(),
            entityStore: entityStore,
            actionItemStore: actionItemStore,
            knowledgeStore: knowledgeStore,
            knowledgeChat: knowledgeChat,
            voiceChat: voiceChat,
            knowledgeThreads: knowledgeThreads,
            agentStore: agentStore,
            beats: beats,
            beatRunner: BeatRunner(
                beats: beats,
                chat: beatChat,
                threads: knowledgeThreads,
                meetings: meetingStore,
                entitlements: entitlements,
                auth: auth
            ),
            labelStore: labelStore,
            meetingGrants: meetingGrants,
            remoteCalendar: remoteCalendar,
            entitlements: entitlements,
            billing: BillingService(supabase: supabase),
            referral: ReferralService(supabase: supabase),
            accountExport: AccountExportService(supabase: supabase),
            meetingMigration: MeetingMigration(
                supabase: supabase,
                auth: auth,
                meetingStore: meetingStore,
                outbox: meetingOutbox
            ),
            connections: ConnectionService(supabase: supabase),
            integrations: integrations,
            integrationCatalogue: integrationCatalogue,
            actionProposals: actionProposals,
            rooms: rooms,
            organizations: organizations,
            accessChannel: accessChannel,
            taskDrafts: TaskDraftComposer(
                llm: llmClient,
                meetings: meetingStore,
                language: languagePreference
            ),
            panelSharing: PanelSharingPreference(),
            proactivityPreference: ProactivityPreference(),
            launchBehavior: LaunchBehavior(),
            meetingDetection: MeetingDetectionPreference(),
            calendar: calendar,
            demoPlayback: DemoPlayback(),
            captureSurface: CaptureSurfacePreference(),
            toolApproval: toolApproval,
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
                entitlements: entitlements,
                calendar: remoteCalendar
            ),
            screenExclusions: screenExclusions,
            screenContext: screenContext,
            settingsFocus: SettingsFocus(),
            appearance: AppearancePreference()
        )
    }

    /// Reads the stored session once, off the main thread, so that the
    /// synchronous reads that follow — `AuthService.init`'s among them — are
    /// answered by `AuthSessionStorage`'s cache instead of the keychain.
    ///
    /// A session the login keychain still holds is fetched through securityd,
    /// which has been measured in seconds on a degraded keychain: long enough
    /// for the main thread to be reported as hung. On a global queue rather
    /// than a `Task`, because the call blocks its thread outright and the
    /// cooperative pool has only one thread per core to block.
    private static func warmSessionStorage(_ client: SupabaseClient) async {
        let started = ContinuousClock.now
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = client.auth.currentSession
                continuation.resume()
            }
        }
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.auth.info("session storage warm-up \(milliseconds)ms")
        // Nod is an accessory app with nothing on screen until this returns,
        // so a wait past the hang threshold is now invisible where it used to
        // file itself. Reported by hand, or the next one is never known about.
        if milliseconds >= 2000 {
            CrashReporting.note("session storage warm-up took \(milliseconds)ms")
        }
    }

    /// Drops everything the signed-out account put in memory, so the next
    /// person to sign in sees none of it.
    ///
    /// Here rather than at the sign-out call site, which is what let this go
    /// wrong: the list lived in `NodApp`, a hundred lines and a file away from
    /// where a store is added, and `knowledgeThreads` was never put on it. The
    /// chat sidebar then kept the last account's titles, and its load-once
    /// guard kept saying "already loaded" — so signing out, in as somebody
    /// else, and back again left an account looking at an empty chat list until
    /// the app was relaunched. `integrations` was missing for the same reason,
    /// and offered the next person the last one's Linear and calendar.
    ///
    /// A store that holds anything account-scoped belongs on this list. It is
    /// still a list somebody has to remember, but it is now the file they were
    /// already editing.
    func clearPerAccountState() async {
        meetingStore.clear()
        profileStore.clear()
        chatStore.clear()
        knowledgeChat.clear()
        voiceChat.clear()
        beatRunner.clear()
        agentStore.clear()
        knowledgeThreads.clear()
        beats.clear()
        actionItemStore.clear()
        actionProposals.clear()
        labelStore.clear()
        meetingGrants.clear()
        remoteCalendar.clear()
        entitlements.clear()
        emailPreferences.clear()
        organizations.clear()
        integrations.clear()
        // The channel carries this account's topics; leaving it open across a
        // sign-out would have the next person listening on the last one's.
        await accessChannel.teardown()
    }
}

/// What an access change has to go and re-ask, holding none of it strongly.
///
/// A value rather than a capture list: the subscription outlives any single
/// refresh, and a closure capturing five services keeps the whole graph alive
/// for as long as the channel is subscribed.
@MainActor
private struct AccessRefresh {
    weak var organizations: OrganizationService?
    weak var labels: LabelStore?
    weak var meetings: MeetingStore?
    weak var grants: MeetingGrantStore?
    weak var rooms: RoomListenerService?

    func run() async {
        await organizations?.refresh()
        await labels?.refresh()
        await grants?.refresh()
        // Somebody joining or leaving a live room pokes the host's own topic —
        // this is that poke arriving. Without it the host's "who is listening"
        // line has no source but a timer.
        if let hosting = meetings?.recordingMeetingID {
            await rooms?.refreshListeners(hostMeetingID: hosting)
            // The same poke carries a request that has not been answered yet:
            // somebody the server could not place in this meeting on its own is
            // waiting on the host, and this is the only thing that tells them.
            await rooms?.refreshPendingListeners(hostMeetingID: hosting)
        }
        // Both, together. Access to a shared folder and access to the sessions
        // inside it are revoked by the same act.
        await meetings?.refresh(force: true)
        // A session somebody trashed on their phone left the list and joined the
        // trash in one write; re-asking for only the list would take it off one
        // screen and never put it on the other.
        await meetings?.refreshTrashIfLoaded()
        // Hiding is a per-person fact rather than an access change, but it rides
        // the same `user:` topic and moves the same list.
        await meetings?.refreshHidden()
    }
}
