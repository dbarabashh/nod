import Combine
import Foundation
import Supabase

/// A capability the UI can gate on. These are the only feature *keys* the
/// client knows about — the mapping of which plan grants which feature lives
/// server-side in `public.plans`, never here. Adding a key is needed only when
/// a feature ships new UI; re-pricing (which plan unlocks what) touches data,
/// not this enum.
enum Feature: String, CaseIterable {
    case liveTranscription = "live_transcription"
    case askSingleMeeting = "ask_single_meeting"
    /// The in-meeting live "Ask" box — free-form questions about the running
    /// transcript while recording. Pro-tier (granted to trial + pro, not starter).
    case askLive = "ask_live"
    case multilingual
    case unlimitedHistory = "unlimited_history"
    /// Cross-session "Ask Nod" — the personal knowledge base over all meetings
    /// (vector search in `session_embeddings`).
    case askAcrossMeetings = "ask_across_meetings"
    /// Narrowing cross-session questions to a label ("Ask within <label>").
    case labelScoping = "label_scoping"
    /// First-class action items — the per-meeting checklist + the cross-meeting
    /// Action Items aggregate with dedup. Granted on trial/Pro, not Starter.
    case actionItems = "action_items"
    /// Ambient screen context — reading the window the user is working in.
    /// Pro-tier. The gate that matters is the `screen_observations` RLS policy,
    /// because the client writes that table directly; this key drives the UI.
    case ambientContext = "ambient_context"
}

/// The resolved entitlement for the current user, as returned by the
/// `get_entitlement` RPC. The client treats `features` as opaque membership:
/// it asks "do I have X", not "which plan am I on". Server is the source of
/// truth — real limits (hours) are enforced in the LLM proxy; this object is
/// the UX mirror.
struct Entitlement: Decodable {
    enum Status: String {
        case trialing, active, pastDue, canceled, expired, none

        // Maps the server's snake_case status to the enum, defaulting unknown
        // values to `.none` so a new server-side status never crashes an old
        // client.
        init(raw: String) {
            switch raw {
            case "trialing": self = .trialing
            case "active": self = .active
            case "past_due": self = .pastDue
            case "canceled": self = .canceled
            case "expired": self = .expired
            default: self = .none
            }
        }
    }

    let plan: String
    /// The Paddle price the subscription is currently on (nil for trial / none).
    /// Lets the UI tell monthly from yearly so a same-plan cycle switch isn't
    /// mistaken for "current plan".
    let priceID: String?
    let status: Status
    let features: Set<String>
    let hoursUsed: Double
    let hoursLimit: Double
    /// The allowance in seconds, split so the paywall can say "8 hours + 5 you
    /// bought" instead of one blended number. `canStartMeeting` is the server's
    /// own verdict — the client never re-derives it from the parts.
    let includedSeconds: Double
    let topUpSeconds: Double
    let consumedSeconds: Double
    let remainingSeconds: Double
    let canStartMeeting: Bool?
    /// The cycle the subscription is actually on. Resolved server-side because a
    /// grandfathered price is hidden from the client catalogue, so the app cannot
    /// derive it from `priceID` alone.
    let billingCycle: String?
    let trialEndsAt: Date?
    let renewalDate: Date?
    private let limits: [String: Double]

    var isActive: Bool {
        status == .trialing || status == .active
    }

    var remainingHours: Double {
        max(0, hoursLimit - hoursUsed)
    }

    /// An exhausted allowance on an otherwise healthy plan — the one case the
    /// notch offers a top-up instead of the paywall.
    var isAllowanceExhausted: Bool {
        isActive && canStartMeeting == false
    }

    var hasPurchasedTopUp: Bool {
        topUpSeconds > 0
    }

    var deviceLimit: Int {
        Int(limits["devices"] ?? 0)
    }

    func can(_ feature: Feature) -> Bool {
        features.contains(feature.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case plan, status, features, limits
        case priceID = "price_id"
        case hoursUsed = "hours_used"
        case hoursLimit = "hours_limit"
        case includedSeconds = "included_seconds"
        case topUpSeconds = "top_up_seconds"
        case consumedSeconds = "consumed_seconds"
        case remainingSeconds = "remaining_seconds"
        case canStartMeeting = "can_start_meeting"
        case billingCycle = "billing_cycle"
        case trialEndsAt = "trial_ends_at"
        case renewalDate = "renewal_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? "none"
        priceID = try c.decodeIfPresent(String.self, forKey: .priceID)
        status = try Status(raw: c.decodeIfPresent(String.self, forKey: .status) ?? "none")
        features = try Set(c.decodeIfPresent([String].self, forKey: .features) ?? [])
        hoursUsed = try c.decodeIfPresent(Double.self, forKey: .hoursUsed) ?? 0
        hoursLimit = try c.decodeIfPresent(Double.self, forKey: .hoursLimit) ?? 0
        // Derive from hours when the server predates these fields, so an older
        // backend degrades to the previous behaviour instead of reading as zero.
        includedSeconds = try c.decodeIfPresent(Double.self, forKey: .includedSeconds) ?? hoursLimit * 3_600
        topUpSeconds = try c.decodeIfPresent(Double.self, forKey: .topUpSeconds) ?? 0
        consumedSeconds = try c.decodeIfPresent(Double.self, forKey: .consumedSeconds) ?? hoursUsed * 3_600
        remainingSeconds = try c.decodeIfPresent(Double.self, forKey: .remainingSeconds)
            ?? max(0, includedSeconds + topUpSeconds - consumedSeconds)
        canStartMeeting = try c.decodeIfPresent(Bool.self, forKey: .canStartMeeting)
        billingCycle = try c.decodeIfPresent(String.self, forKey: .billingCycle)
        limits = try c.decodeIfPresent([String: Double].self, forKey: .limits) ?? [:]
        // The RPC returns timestamptz as ISO-8601 strings; parse leniently so a
        // null/absent date is simply "no date", not a decode failure.
        trialEndsAt = try c.decodeIfPresent(String.self, forKey: .trialEndsAt).flatMap(ServerTimestamp.date)
        renewalDate = try c.decodeIfPresent(String.self, forKey: .renewalDate).flatMap(ServerTimestamp.date)
    }
}

/// Owns the current user's entitlement and re-resolves it from the server.
/// Feature gates in SwiftUI read `can(_:)`; it fails closed (no entitlement →
/// no feature) so a fetch error never silently unlocks a paid capability.
@MainActor
final class EntitlementService: ObservableObject {
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var loadFailed = false

    /// Fired whenever the resolved entitlement changes, so a service that must
    /// *act* on a feature (rather than render it) doesn't have to observe this
    /// object. Set once in the composition root: a `refresh()` happens from four
    /// places, and mirroring the result at each of them is three chances to
    /// forget.
    ///
    /// Carries the entitlement rather than nothing, because a consumer that acts
    /// has to tell two nils apart that `mayUse` deliberately conflates: **nil
    /// here means signed out** (only `clear()` passes it), while a *failed*
    /// refresh doesn't fire at all, leaving the last known answer in place. Fail
    /// open on a hiccup, fail closed on sign-out.
    var onChange: ((Entitlement?) -> Void)?

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func refresh() async {
        do {
            let result: Entitlement = try await supabase
                .rpc("get_entitlement")
                .execute()
                .value
            entitlement = result
            loadFailed = false
            Log.ui.info(
                "EntitlementService.refresh plan=\(result.plan) status=\(result.status.rawValue) hours=\(result.hoursUsed)/\(result.hoursLimit)"
            )
            onChange?(result)
        } catch {
            loadFailed = true
            Log.ui.error("EntitlementService.refresh failed: \(error.localizedDescription)")
        }
    }

    /// True only when the server has granted the feature to this user. Fails
    /// closed: an unresolved or locked entitlement denies everything.
    func can(_ feature: Feature) -> Bool {
        entitlement?.isActive == true && entitlement?.can(feature) == true
    }

    /// Whether a *UI surface* for the feature should be shown. Fails OPEN on an
    /// unresolved entitlement, the opposite of `can`: a subscriber whose
    /// entitlement fetch transiently failed must keep seeing their own data, and
    /// real limits are enforced server-side regardless.
    ///
    /// Lives here because it was written out longhand at every call site
    /// instead, and a gate copied per-view is a gate the next view forgets —
    /// which is how the per-meeting action-item checklist came to render for
    /// Starter users.
    func mayUse(_ feature: Feature) -> Bool {
        entitlement == nil || can(feature)
    }

    func clear() {
        entitlement = nil
        loadFailed = false
        onChange?(nil)
    }
}
