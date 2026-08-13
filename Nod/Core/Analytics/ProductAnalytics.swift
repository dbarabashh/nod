import Foundation
import Supabase

@MainActor
final class ProductAnalytics: ObservableObject {
    enum Event: String, Codable {
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
        case quickCapture = "quick_capture"
        case liveActivity = "live_activity"
        case meetingDetail = "meeting_detail"
        case ask
        case settings
    }

    enum Stage: String, Codable {
        case welcome
        case profile
        case permissions
        case tutorial
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

    enum ReasonCode: String, Codable {
        case permissionDenied = "permission_denied"
        case entitlementRequired = "entitlement_required"
        case hoursExhausted = "hours_exhausted"
        case vadUnavailable = "vad_unavailable"
        case audioStartFailed = "audio_start_failed"
        case interrupted
        case routeChanged = "route_changed"
        case transcriptionFailed = "transcription_failed"
        case persistenceFailed = "persistence_failed"
        case userCancelled = "user_cancelled"
        case authenticationFailed = "authentication_failed"
        case unknown
    }

    enum Surface: String, Codable {
        case onboarding
        case capture
        case home
        case library
        case meetingDetail = "meeting_detail"
        case ask
        case paywall
        case settings
        case share
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

    enum Outcome: String, Codable {
        case granted
        case declined
        case success
        case failure
        case cancelled
        case viewed
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
            billing: String? = nil
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
