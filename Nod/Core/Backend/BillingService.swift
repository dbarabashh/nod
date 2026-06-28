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

/// Drives the paywall's purchase flow. It does NOT process payment: it fetches
/// the price catalog, asks the `create-checkout` Edge Function (which holds the
/// Paddle API key) for a hosted checkout URL, and opens it in the browser. The
/// user's plan only changes once Paddle's webhook lands and
/// `EntitlementService.refresh()` re-reads it — payment is never client-trusted.
@MainActor
final class BillingService: ObservableObject {
    @Published private(set) var prices: [PlanPrice] = []
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
