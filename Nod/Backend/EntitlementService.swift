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
    case multilingual
    case unlimitedHistory = "unlimited_history"
    /// Cross-session "Ask Nod" — the personal knowledge base over all meetings
    /// (vector search in `session_embeddings`).
    case askAcrossMeetings = "ask_across_meetings"
    /// Narrowing cross-session questions to a label ("Ask within <label>").
    case labelScoping = "label_scoping"
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
    let trialEndsAt: Date?
    let renewalDate: Date?
    private let limits: [String: Double]

    var isActive: Bool {
        status == .trialing || status == .active
    }

    var remainingHours: Double {
        max(0, hoursLimit - hoursUsed)
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
        limits = try c.decodeIfPresent([String: Double].self, forKey: .limits) ?? [:]
        // The RPC returns timestamptz as ISO-8601 strings; parse leniently so a
        // null/absent date is simply "no date", not a decode failure.
        trialEndsAt = try Self.date(from: c.decodeIfPresent(String.self, forKey: .trialEndsAt))
        renewalDate = try Self.date(from: c.decodeIfPresent(String.self, forKey: .renewalDate))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return isoFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Owns the current user's entitlement and re-resolves it from the server.
/// Feature gates in SwiftUI read `can(_:)`; it fails closed (no entitlement →
/// no feature) so a fetch error never silently unlocks a paid capability.
@MainActor
final class EntitlementService: ObservableObject {
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var loadFailed = false

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

    func clear() {
        entitlement = nil
        loadFailed = false
    }
}
