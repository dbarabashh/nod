import AppKit
import Foundation
import Supabase

/// One purchasable Paddle price, read from `public.plan_prices`. The catalog is
/// data: the paywall renders from these rows and posts `paddlePriceID` back to
/// `create-checkout` — re-pricing or adding a cycle never touches the binary.
struct PlanPrice: Decodable, Identifiable {
    let paddlePriceID: String
    let plan: String
    let billingCycle: String
    let kind: String
    let displayAmount: Double
    let currency: String
    let sortOrder: Int
    /// Stable catalogue name, independent of the Paddle id — the top-up flow
    /// asks for a pack by sku so a re-created price doesn't need a client build.
    let sku: String?
    /// One-time packs only: hours this purchase adds to the current period.
    let topUpHours: Double?
    /// One-time packs only: integration credits this purchase adds instead.
    let topUpCredits: Double?

    var id: String {
        paddlePriceID
    }

    enum CodingKeys: String, CodingKey {
        case paddlePriceID = "paddle_price_id"
        case plan
        case billingCycle = "billing_cycle"
        case kind
        case displayAmount = "display_amount"
        case currency
        case sortOrder = "sort_order"
        case sku
        case topUpHours = "top_up_hours"
        case topUpCredits = "top_up_credits"
    }
}

/// A plan's metered ceiling, read from `public.plans`. The paywall renders the
/// hours line from this rather than from a string in the binary: the entitlement
/// only carries the *current* plan's limit, so a hardcoded "50 meeting hours"
/// sold Pro on a number the server had already changed.
struct PlanLimits: Decodable {
    let plan: String
    let limits: [String: Double]
    /// Pro is sold as unlimited hours, bounded by the fair-use terms rather than
    /// by a number. `hours_per_month` still carries the enforcement ceiling, so
    /// this is what keeps a surface from printing it.
    let hoursAreUnlimited: Bool

    var hoursPerMonth: Double? {
        limits["hours_per_month"]
    }

    var devices: Double? {
        limits["devices"]
    }

    enum CodingKeys: String, CodingKey {
        case plan, limits
        case hoursAreUnlimited = "hours_are_unlimited"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(String.self, forKey: .plan)
        limits = try c.decodeIfPresent([String: Double].self, forKey: .limits) ?? [:]
        // Absent on a client that predates the column — treat as metered, which
        // is the safe direction: it prints a real number rather than promising
        // unlimited on a plan that isn't.
        hoursAreUnlimited = try c.decodeIfPresent(Bool.self, forKey: .hoursAreUnlimited) ?? false
    }
}

/// Drives the paywall's purchase flow. It does NOT process payment: it fetches
/// the price catalog, asks the `create-checkout` Edge Function (which holds the
/// Paddle API key) for a hosted checkout URL, and opens it in the browser. The
/// user's plan only changes once Paddle's webhook lands and
/// `EntitlementService.refresh()` re-reads it — payment is never client-trusted.
@MainActor
final class BillingService: ObservableObject {
    @Published private(set) var prices: [PlanPrice] = []
    @Published private(set) var planLimits: [PlanLimits] = []
    @Published private(set) var isStartingCheckout = false
    @Published private(set) var isStartingTopUp = false
    @Published private(set) var isOpeningPortal = false
    /// Whether this person holds a Paddle subscription of their own, which is a
    /// different question from whose plan they resolve to: a workspace can cover
    /// somebody who is still being charged for a personal plan, and that is
    /// exactly when they need to be able to reach it.
    @Published private(set) var hasPersonalSubscription = false
    @Published var lastError: String?

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func loadPrices() async {
        do {
            let rows: [PlanPrice] = try await supabase
                .from("plan_prices")
                .select()
                .eq("active", value: true)
                .order("sort_order")
                .execute()
                .value
            prices = rows
            Log.ui.info("BillingService.loadPrices count=\(rows.count)")
        } catch {
            Log.ui.error("BillingService.loadPrices failed: \(error.localizedDescription)")
        }
        await loadPlanLimits()
        await loadPersonalSubscription()
    }

    /// Read through RLS ("users read own subscription"), so it can only ever
    /// answer about the caller. Failure leaves the flag as it was rather than
    /// hiding a link somebody needs.
    private func loadPersonalSubscription() async {
        struct Row: Decodable {
            let paddleSubscriptionID: String?
            let status: String

            enum CodingKeys: String, CodingKey {
                case paddleSubscriptionID = "paddle_subscription_id"
                case status
            }
        }
        do {
            let rows: [Row] = try await supabase
                .from("subscriptions")
                .select("paddle_subscription_id,status")
                .execute()
                .value
            hasPersonalSubscription = rows.contains {
                $0.paddleSubscriptionID != nil && $0.status != "canceled" && $0.status != "expired"
            }
        } catch {
            Log.ui.error("BillingService.loadPersonalSubscription failed: \(error.localizedDescription)")
        }
    }

    /// Loaded alongside the prices, from the same pane's one refresh. Failure is
    /// survivable: the paywall drops the hours line rather than showing a stale
    /// number, which is the whole point of not keeping one in the binary.
    private func loadPlanLimits() async {
        do {
            planLimits = try await supabase
                .from("plans")
                .select("plan,limits,hours_are_unlimited")
                .execute()
                .value
        } catch {
            Log.ui.error("BillingService.loadPlanLimits failed: \(error.localizedDescription)")
        }
    }

    func hoursPerMonth(plan: String) -> Double? {
        planLimits.first { $0.plan == plan }?.hoursPerMonth
    }

    func devices(plan: String) -> Double? {
        planLimits.first { $0.plan == plan }?.devices
    }

    func hoursAreUnlimited(plan: String) -> Bool {
        planLimits.first { $0.plan == plan }?.hoursAreUnlimited ?? false
    }

    /// Metering as it applies to THIS subscription rather than to the plan in the
    /// catalogue. Somebody who bought Pro while it promised unlimited hours keeps
    /// that promise after the plan starts publishing a ceiling, and the server
    /// says so per subscription; the plan is the fallback for a server that
    /// predates the override.
    func hoursAreUnlimited(for entitlement: Entitlement) -> Bool {
        entitlement.hoursAreUnlimited || hoursAreUnlimited(plan: entitlement.plan)
    }

    /// Subscription prices for `plan` (Starter/Pro), keyed by cycle, used by the
    /// paywall cards. Overage packs are filtered out — they're surfaced from the
    /// over-cap banner, not the plan grid.
    func subscriptionPrice(plan: String, cycle: String) -> PlanPrice? {
        prices.first { $0.plan == plan && $0.billingCycle == cycle && $0.kind == "subscription" }
    }

    /// The hour pack this plan sells, if it sells one. Absent until somebody has
    /// created the real Paddle price: the `plan_prices` policy only shows a row
    /// that is `active and available_for_new_checkout`, so a placeholder never
    /// reaches a client and the allowance gate simply offers one door instead of
    /// two.
    func topUpOffer(plan: String) -> PlanPrice? {
        prices.first { $0.plan == plan && $0.kind == "topup" && $0.topUpHours != nil && $0.sku != nil }
    }

    /// The credit pack this plan sells, if it sells one — same rule as the hour
    /// pack: absent until the real Paddle price exists.
    func creditPackOffer(plan: String) -> PlanPrice? {
        prices.first { $0.plan == plan && $0.kind == "topup" && $0.topUpCredits != nil && $0.sku != nil }
    }

    /// `opened` — a checkout URL was launched in the browser (new subscriber).
    /// `planChanged` — the existing subscription was switched in place (no
    /// browser); the caller should re-resolve the entitlement. `failed` — error.
    enum CheckoutOutcome { case opened, planChanged, failed }

    /// `referralCode` is attribution only — the server applies the friend's −50%
    /// (monthly prices only) and stamps it for the webhook to credit the referrer.
    /// An empty/blank code is sent as nil so the server doesn't carry noise.
    /// `seats` is required by a workspace plan and meaningless to a personal one,
    /// so it is sent only when present — an older function ignores it either way.
    func startCheckout(
        priceID: String,
        referralCode: String? = nil,
        offer: String? = nil,
        seats: Int? = nil
    ) async -> CheckoutOutcome {
        guard !isStartingCheckout else { return .failed }
        isStartingCheckout = true
        lastError = nil
        defer { isStartingCheckout = false }

        let ref = referralCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Request: Encodable { let price_id: String; let ref: String?; let offer: String?; let seats: Int? }
        // create-checkout returns either { url } (new subscription → open it) or
        // { updated: true } (existing subscription changed in place).
        struct Response: Decodable { let url: URL?; let updated: Bool? }

        do {
            let response: Response = try await supabase.functions.invoke(
                "create-checkout",
                options: FunctionInvokeOptions(
                    body: Request(
                        price_id: priceID,
                        ref: (ref?.isEmpty == false) ? ref : nil,
                        offer: offer,
                        seats: seats
                    )
                )
            )
            if let url = response.url {
                if offer == "winback" { Self.clearPendingWinbackOffer() }
                Log.ui.info("BillingService.startCheckout opening \(url.absoluteString)")
                NSWorkspace.shared.open(url)
                return .opened
            }
            if response.updated == true {
                Log.ui.info("BillingService.startCheckout changed plan in place")
                return .planChanged
            }
            lastError = "Couldn't start checkout. Please try again."
            return .failed
        } catch {
            Log.ui.error("BillingService.startCheckout failed: \(error.localizedDescription)")
            lastError = Self.checkoutErrorMessage(error)
            return .failed
        }
    }

    /// Where a pack was bought from, for the funnel only.
    enum TopUpSurface: String {
        case capture, settings
    }

    /// Buys a pack — hours or credits — for the CURRENT period. Never
    /// automatic, never recurring: the person chooses it in the allowance gate
    /// or on a billing page.
    func startTopUp(sku: String, surface: TopUpSurface) async -> CheckoutOutcome {
        guard !isStartingTopUp else { return .failed }
        isStartingTopUp = true
        lastError = nil
        defer { isStartingTopUp = false }

        struct Request: Encodable {
            let sku: String
            let surface: String
        }
        struct Response: Decodable { let url: URL }

        do {
            let response: Response = try await supabase.functions.invoke(
                "create-topup-checkout",
                options: FunctionInvokeOptions(body: Request(sku: sku, surface: surface.rawValue))
            )
            Log.ui.info("BillingService.startTopUp sku=\(sku) opening checkout")
            NSWorkspace.shared.open(response.url)
            return .opened
        } catch {
            Log.ui.error("BillingService.startTopUp sku=\(sku) failed: \(error.localizedDescription)")
            lastError = Self.topUpErrorMessage(error)
            return .failed
        }
    }

    /// The server refuses a referral for specific, explainable reasons. Saying
    /// which one turns a dead end into something the person can act on.
    private static func checkoutErrorMessage(_ error: Error) -> String {
        let fallback = "Couldn't start checkout. Please try again."
        switch ServerError.functionCode(error) {
        case "invalid_referral":
            return "That referral code isn't valid. Check it and try again."
        case "self_referral":
            return "You can't use your own referral code."
        case "already_paid":
            return "Referral discounts are only for a first Nod subscription."
        case "seats_invalid":
            return "Choose how many seats your workspace needs."
        case "seats_below_members":
            return "That is fewer seats than there are people in the workspace."
        case "no_active_workspace":
            return "Switch to the workspace you want to pay for, then try again."
        case "not_a_workspace_admin":
            return "Only an owner or admin of the workspace can buy seats."
        case "already_redeemed":
            return "A referral offer has already been used on this account."
        case "offer_not_eligible":
            return "This offer is available on monthly Starter or Pro while the email offer is valid."
        case "pricing_unconfigured", "referral_unavailable", "offer_unavailable":
            return "This offer isn't available right now. Please try again later."
        default:
            return fallback
        }
    }

    private static let pendingWinbackOfferKey = "billing.pendingWinbackOffer"

    static var hasPendingWinbackOffer: Bool {
        UserDefaults.standard.bool(forKey: pendingWinbackOfferKey)
    }

    static func storePendingWinbackOffer() {
        UserDefaults.standard.set(true, forKey: pendingWinbackOfferKey)
    }

    static func clearPendingWinbackOffer() {
        UserDefaults.standard.removeObject(forKey: pendingWinbackOfferKey)
    }

    private static func topUpErrorMessage(_ error: Error) -> String {
        switch ServerError.functionCode(error) {
        case "topup_not_eligible":
            "Extra capture hours are only available on an active Starter plan."
        case "no_active_usage_period":
            "Your billing period is about to roll over — your capture hours reset then."
        case "topup_unconfigured", "topup_unavailable":
            "Extra capture hours aren't available right now. Please try again later."
        default:
            "Couldn't start the capture-hours checkout. Please try again."
        }
    }

    /// Opens Paddle's hosted customer portal (cancel, update card, invoices).
    /// As MoR, Paddle owns this surface — the app just hands the user off.
    /// The workspace's portal rather than the caller's own. Refused server-side
    /// for anybody but an owner or admin, because it cancels the plan every
    /// colleague is working on.
    func openWorkspacePortal() async {
        await openPortal(scope: "organization")
    }

    func openCustomerPortal() async {
        await openPortal(scope: nil)
    }

    private func openPortal(scope: String?) async {
        guard !isOpeningPortal else { return }
        isOpeningPortal = true
        lastError = nil
        defer { isOpeningPortal = false }

        struct PortalResponse: Decodable { let url: URL }

        struct Request: Encodable { let scope: String? }

        do {
            let response: PortalResponse = try await supabase.functions.invoke(
                "customer-portal",
                options: FunctionInvokeOptions(body: Request(scope: scope))
            )
            Log.ui.info("BillingService.openPortal scope=\(scope ?? "personal") opening portal")
            NSWorkspace.shared.open(response.url)
        } catch {
            Log.ui.error("BillingService.openPortal failed: \(error.localizedDescription)")
            lastError = Self.portalErrorMessage(error)
        }
    }

    private static func portalErrorMessage(_ error: Error) -> String {
        // A plan granted by hand has no Paddle customer behind it, so the portal
        // has nothing to open. Telling that person to "try again" sends them round
        // a loop that cannot succeed.
        if ServerError.functionCode(error) == "no_paddle_customer" {
            return "This plan wasn't bought through checkout, so there's no billing to manage. Email dmytro@hellonod.app if you need a change."
        }
        return "Couldn't open subscription management. Please try again."
    }
}
