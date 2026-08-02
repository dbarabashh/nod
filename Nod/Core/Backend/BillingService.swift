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
    @Published private(set) var isOpeningPortal = false
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

    func hoursAreUnlimited(plan: String) -> Bool {
        planLimits.first { $0.plan == plan }?.hoursAreUnlimited ?? false
    }

    /// Subscription prices for `plan` (Starter/Pro), keyed by cycle, used by the
    /// paywall cards. Overage packs are filtered out — they're surfaced from the
    /// over-cap banner, not the plan grid.
    func subscriptionPrice(plan: String, cycle: String) -> PlanPrice? {
        prices.first { $0.plan == plan && $0.billingCycle == cycle && $0.kind == "subscription" }
    }

    /// `opened` — a checkout URL was launched in the browser (new subscriber).
    /// `planChanged` — the existing subscription was switched in place (no
    /// browser); the caller should re-resolve the entitlement. `failed` — error.
    enum CheckoutOutcome { case opened, planChanged, failed }

    /// `referralCode` is attribution only — the server applies the friend's −50%
    /// (monthly prices only) and stamps it for the webhook to credit the referrer.
    /// An empty/blank code is sent as nil so the server doesn't carry noise.
    func startCheckout(priceID: String, referralCode: String? = nil) async -> CheckoutOutcome {
        guard !isStartingCheckout else { return .failed }
        isStartingCheckout = true
        lastError = nil
        defer { isStartingCheckout = false }

        let ref = referralCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Request: Encodable { let price_id: String; let ref: String? }
        // create-checkout returns either { url } (new subscription → open it) or
        // { updated: true } (existing subscription changed in place).
        struct Response: Decodable { let url: URL?; let updated: Bool? }

        do {
            let response: Response = try await supabase.functions.invoke(
                "create-checkout",
                options: FunctionInvokeOptions(
                    body: Request(price_id: priceID, ref: (ref?.isEmpty == false) ? ref : nil)
                )
            )
            if let url = response.url {
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
            lastError = "Couldn't start checkout. Please try again."
            return .failed
        }
    }

    /// Opens Paddle's hosted customer portal (cancel, update card, invoices).
    /// As MoR, Paddle owns this surface — the app just hands the user off.
    func openCustomerPortal() async {
        guard !isOpeningPortal else { return }
        isOpeningPortal = true
        lastError = nil
        defer { isOpeningPortal = false }

        struct PortalResponse: Decodable { let url: URL }

        do {
            let response: PortalResponse = try await supabase.functions.invoke("customer-portal")
            Log.ui.info("BillingService.openCustomerPortal opening portal")
            NSWorkspace.shared.open(response.url)
        } catch {
            Log.ui.error("BillingService.openCustomerPortal failed: \(error.localizedDescription)")
            lastError = "Couldn't open subscription management. Please try again."
        }
    }
}
