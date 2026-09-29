import Foundation
import Supabase

@MainActor
final class ProductAnalytics: ObservableObject {
    enum Event: String, Codable, CaseIterable {
        case appOpened = "app_opened"
        case captureStartRequested = "capture_start_requested"
        case captureStarted = "capture_started"
        case captureStopped = "capture_stopped"
        case captureFailed = "capture_failed"
        case captureDiscarded = "capture_discarded"
        case summaryViewed = "summary_viewed"
        case transcriptViewed = "transcript_viewed"
        case actionItemsViewed = "action_items_viewed"
        case contentCopied = "content_copied"
        case meetingExported = "meeting_exported"
        case aiActionCompleted = "ai_action_completed"
        case paywallViewed = "paywall_viewed"
        case allowanceGateViewed = "allowance_gate_viewed"
        case allowanceGateAction = "allowance_gate_action"
        case referralLinkShared = "referral_link_shared"
        case emailConsentSaved = "email_consent_saved"
        /// A product was linked or unlinked. Adoption of the thing a meeting is
        /// no longer the only input to.
        case integrationConnected = "integration_connected"
        case integrationRevoked = "integration_revoked"
        /// A live question was pointed at a connected product. Says whether the
        /// integrations *answer*, which linking alone never showed.
        case lookupRouted = "lookup_routed"
        /// Somebody was shown what a write would do and said yes or no. The one
        /// number that says whether the approval gate protects more than it
        /// interrupts.
        case toolCallReviewed = "tool_call_reviewed"
        /// The screen-reading switch moved. Absence of `screen_observations` is
        /// ambiguous — off, paused, blocklisted, or the Mac simply shut — and
        /// only the transition tells them apart.
        case ambientContextToggled = "ambient_context_toggled"
        /// A commitment moved by a hand or a rule. The product after the
        /// recording is this loop, and nothing else counts whether it turns.
        case actionItemActed = "action_item_acted"
        /// A beat was made, switched or removed; a report of one was read.
        case beatChanged = "beat_changed"
        case beatReportOpened = "beat_report_opened"
        /// The recap's framing was changed by hand.
        case modeChanged = "mode_changed"
        /// A question went to memory, and how it was aimed: at a pinned
        /// session, a project, the thread it continues, or everything.
        case questionAsked = "question_asked"
        case memoryActivationViewed = "memory_activation_viewed"
        case memoryActivationActed = "memory_activation_acted"
        /// An answer's source was opened — the one sign the excerpts were
        /// worth reading, which the answer's length never says.
        case answerSourceOpened = "answer_source_opened"
        /// Something left the account for somebody else, or stopped.
        case meetingShared = "meeting_shared"
        case shareRevoked = "share_revoked"
        case teamMemberInvited = "team_member_invited"
        case inviteAccepted = "invite_accepted"
        /// The Mac's own calendar was allowed or refused.
        case calendarConnected = "calendar_connected"
        /// "Record this one?" answered on Today, the cheapest way in.
        case meetingAttendanceAnswered = "meeting_attendance_answered"
        /// A failure the person saw. Sentry sees crashes; this sees the quiet
        /// kind — a recap that never came, a sync that did not land.
        case errorShown = "error_shown"
        /// How the app is reached and for how long, beyond the fact of a launch.
        case notchOpened = "notch_opened"
        case hotkeyUsed = "hotkey_used"
        case appSessionEnded = "app_session_ended"
        /// The update row was taken up; a support tile was opened.
        case updateInstallClicked = "update_install_clicked"
        case supportOpened = "support_opened"
    }

    enum EntryPoint: String, Codable {
        case appLaunch = "app_launch"
        case menuBar = "menu_bar"
        case mainWindow = "main_window"
        case floatingPanel = "floating_panel"
        case hotkey
        case deepLink = "deep_link"
        case notch
        case home
        case library
        case meetingDetail = "meeting_detail"
        case ask
        case settings
    }

    enum Stage: String, Codable {
        case welcome
        case profile
        case permissions
        case consent
        case authentication
        case entitlement
        case vad
        case audio
        case capture
        case transcription
        case persistence
        case finalization
    }

    enum ReasonCode: String, Codable, CaseIterable {
        case permissionDenied = "permission_denied"
        case entitlementRequired = "entitlement_required"
        case hoursExhausted = "hours_exhausted"
        case audioStartFailed = "audio_start_failed"
        case interrupted
        case userCancelled = "user_cancelled"
        case authenticationFailed = "authentication_failed"
        case summaryFailed = "summary_failed"
        case syncFailed = "sync_failed"
        case integrationFailed = "integration_failed"
        case creditsExhausted = "credits_exhausted"
        case searchFailed = "search_failed"
        case unknown
    }

    enum Surface: String, Codable, CaseIterable {
        case onboarding
        case capture
        case home
        case library
        case meetingDetail = "meeting_detail"
        case ask
        case paywall
        case settings
        case share
        case beats
    }

    /// The one bounded word an event may carry beyond its outcome: a beat's
    /// cadence, a preset mode, how a question was aimed, who a share went to,
    /// which hotkey, how long the app stayed open, which support tile. One
    /// key rather than seven, so the validator and the dashboard read one
    /// column; every value is a product word, never a person's.
    enum Detail: String, Codable, CaseIterable {
        case memoryOff = "memory_off"
        case memoryPermission = "memory_permission"
        case memoryPaused = "memory_paused"
        case memoryChecking = "memory_checking"
        case memoryWaiting = "memory_waiting"
        case memoryReady = "memory_ready"
        case memoryFailed = "memory_failed"
        case daily, weekdays, weekly, monthly
        case general, interview
        case salesCall = "sales_call"
        case oneOnOne = "one_on_one"
        case standup, custom
        case pinned, project
        case followUp = "follow_up"
        case open
        case link, team, organization
        case togglePanel = "toggle_panel"
        case askNod = "ask_nod"
        case holdToAsk = "hold_to_ask"
        case under1m = "under_1m"
        case oneTo10m = "1_10m"
        case tenTo60m = "10_60m"
        case over1h = "over_1h"
        case bug, feature
    }

    enum ContentType: String, Codable {
        case summary
        case transcript
        case actionItems = "action_items"
        case answer
        case meeting
        case markdown
    }

    enum AIFeature: String, Codable {
        case catchUp = "catch_up"
        case suggestReply = "suggest_reply"
        case keyPoints = "key_points"
        case followUp = "follow_up"
        case liveAsk = "live_ask"
        case meetingAsk = "meeting_ask"
        case knowledgeAsk = "knowledge_ask"
        case recap
        case summaryRegeneration = "summary_regeneration"
    }

    enum Outcome: String, Codable, CaseIterable {
        case granted
        case declined
        case success
        case failure
        case cancelled
        case viewed
        /// The product answered and had nothing. Distinct from `failure` on
        /// purpose: "your Linear is quiet" and "your Linear is unreachable" are
        /// opposite pieces of news, and a funnel that flattens them measures the
        /// wrong thing to go and fix.
        case empty
        /// Never attempted — somebody in the room is not a colleague.
        case refused
        case enabled
        case disabled
        case paused
        case done, reopened, delegated, asked, filed
        case autoClosed = "auto_closed"
        case created, deleted
    }

    struct Properties: Codable {
        var platform: String?
        var appVersion: String?
        var sessionKind: String?
        var entryPoint: EntryPoint?
        var stage: Stage?
        var reasonCode: ReasonCode?
        var surface: Surface?
        var contentType: ContentType?
        var aiFeature: AIFeature?
        var outcome: Outcome?
        var plan: String?
        var billing: String?
        /// Which connected product, as `IntegrationProvider.rawValue`. Bounded
        /// by that enum and nothing else — never a URL, an account name, or a
        /// workspace.
        var provider: String?
        var detail: Detail?

        init(
            sessionKind: String? = nil,
            entryPoint: EntryPoint? = nil,
            stage: Stage? = nil,
            reasonCode: ReasonCode? = nil,
            surface: Surface? = nil,
            contentType: ContentType? = nil,
            aiFeature: AIFeature? = nil,
            outcome: Outcome? = nil,
            plan: String? = nil,
            billing: String? = nil,
            provider: String? = nil,
            detail: Detail? = nil
        ) {
            self.sessionKind = sessionKind
            self.entryPoint = entryPoint
            self.stage = stage
            self.reasonCode = reasonCode
            self.surface = surface
            self.contentType = contentType
            self.aiFeature = aiFeature
            self.outcome = outcome
            self.plan = plan
            self.billing = billing
            self.provider = provider
            self.detail = detail
        }

        enum CodingKeys: String, CodingKey {
            case platform
            case appVersion = "app_version"
            case sessionKind = "session_kind"
            case entryPoint = "entry_point"
            case stage
            case reasonCode = "reason_code"
            case surface
            case contentType = "content_type"
            case aiFeature = "ai_feature"
            case outcome
            case plan
            case billing
            case provider
            case detail
        }
    }

    let appSessionID = UUID()

    /// Product analytics is first-party, bounded and never shared, so it runs on
    /// legitimate interest rather than consent — but it must be switchable off,
    /// and switching off has to drop what is already queued instead of merely
    /// stopping new events.
    @Published var isOptedOut: Bool {
        didSet {
            guard isOptedOut != oldValue else { return }
            defaults.set(isOptedOut, forKey: Self.optOutKey)
            if isOptedOut {
                queue.removeAll()
                deduplicationKeys.removeAll()
                persistQueue()
                optOutHandler?()
                Log.ui.info("product analytics opted out — queue discarded")
            }
        }
    }

    private static let optOutKey = "analytics.productEventsOptedOut"

    private let supabase: SupabaseClient
    private let auth: AuthService
    private let defaults: UserDefaults
    private var queue: [QueuedEvent]
    private var deduplicationKeys: Set<String> = []
    private var isFlushing = false
    private var optOutHandler: (() -> Void)?

    /// One for previews: no session, so nothing it records ever leaves.
    static var preview: ProductAnalytics {
        let client = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
        return ProductAnalytics(
            supabase: client,
            auth: AuthService(client: client),
            defaults: UserDefaults(suiteName: "preview") ?? .standard
        )
    }

    init(supabase: SupabaseClient, auth: AuthService, defaults: UserDefaults = .standard) {
        self.supabase = supabase
        self.auth = auth
        self.defaults = defaults
        isOptedOut = defaults.bool(forKey: Self.optOutKey)
        if let data = defaults.data(forKey: Self.queueKey),
           let stored = try? JSONDecoder().decode([QueuedEvent].self, from: data) {
            queue = stored
        } else {
            queue = []
        }
    }

    func record(
        _ event: Event,
        captureID: UUID? = nil,
        properties: Properties = Properties(),
        oncePerSession key: String? = nil
    ) {
        guard !isOptedOut, let userID = auth.currentSupabaseSession?.user.id else { return }
        if let key {
            let deduplicationKey = "\(userID.uuidString):\(event.rawValue):\(key)"
            guard deduplicationKeys.insert(deduplicationKey).inserted else { return }
        }
        var enriched = properties
        enriched.platform = "macos"
        enriched.appVersion = Self.appVersion
        let payload = Payload(
            id: UUID(),
            occurredAt: ISO8601DateFormatter().string(from: Date()),
            appSessionID: appSessionID,
            captureID: captureID,
            event: event,
            platform: "macos",
            appVersion: Self.appVersion,
            properties: enriched
        )
        queue.append(QueuedEvent(userID: userID, payload: payload))
        persistQueue()
        Task { await flush() }
    }

    func onOptOut(_ handler: @escaping () -> Void) {
        optOutHandler = handler
        if isOptedOut {
            handler()
        }
    }

    func flush() async {
        guard !isOptedOut, !isFlushing, let userID = auth.currentSupabaseSession?.user.id else { return }
        let batch = Array(queue.filter { $0.userID == userID }.prefix(25))
        guard !batch.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        do {
            let params = BatchParams(pEvents: batch.map(\.payload))
            try await supabase.rpc("record_product_events", params: params).execute()
            let sent = Set(batch.map(\.payload.id))
            queue.removeAll { sent.contains($0.payload.id) }
            persistQueue()
            if queue.contains(where: { $0.userID == userID }) {
                Task { await flush() }
            }
        } catch {
            Log.ui.error("product analytics flush failed — \(error.localizedDescription)")
        }
    }

    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: Self.queueKey)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }

    private static let queueKey = "analytics.product-events.queue.v1"
}

extension ProductAnalytics {
    func recordMeetingInteraction(
        _ event: Event,
        contentType: ContentType,
        meeting: Meeting,
        outcome: Outcome,
        oncePerSession: String? = nil
    ) {
        record(
            event,
            properties: .init(
                sessionKind: meeting.kind.rawValue,
                entryPoint: .meetingDetail,
                surface: .meetingDetail,
                contentType: contentType,
                outcome: outcome
            ),
            oncePerSession: oncePerSession
        )
    }
}

private struct QueuedEvent: Codable {
    let userID: UUID
    let payload: ProductAnalytics.Payload
}

private extension ProductAnalytics {
    struct Payload: Codable {
        let id: UUID
        let occurredAt: String
        let appSessionID: UUID
        let captureID: UUID?
        let event: Event
        let platform: String
        let appVersion: String
        let properties: Properties

        enum CodingKeys: String, CodingKey {
            case id
            case occurredAt = "occurred_at"
            case appSessionID = "app_session_id"
            case captureID = "capture_id"
            case event
            case platform
            case appVersion = "app_version"
            case properties
        }
    }

    struct BatchParams: Encodable {
        let pEvents: [Payload]

        enum CodingKeys: String, CodingKey {
            case pEvents = "p_events"
        }
    }
}
