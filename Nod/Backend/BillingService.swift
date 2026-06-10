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
    let overageHours: Double?
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
        case overageHours = "overage_hours"
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

    func startCheckout(priceID: String) async {
        guard !isStartingCheckout else { return }
        isStartingCheckout = true
        lastError = nil
        defer { isStartingCheckout = false }

        struct Request: Encodable { let price_id: String }
        struct CheckoutResponse: Decodable { let url: URL }

        do {
            let response: CheckoutResponse = try await supabase.functions.invoke(
                "create-checkout",
                options: FunctionInvokeOptions(body: Request(price_id: priceID))
            )
            Log.ui.info("BillingService.startCheckout opening \(response.url.absoluteString)")
            NSWorkspace.shared.open(response.url)
        } catch {
            Log.ui.error("BillingService.startCheckout failed: \(error.localizedDescription)")
            lastError = "Couldn't start checkout. Please try again."
        }
    }
}
