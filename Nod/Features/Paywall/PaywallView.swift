import SwiftUI

/// One purchasable plan as the paywall talks about it. The features live in
/// `PlanComparison`; this is only what a column header needs to say.
struct PaywallPlan: Identifiable {
    let id: String
    let name: String
    let highlighted: Bool
    let badge: String?
    /// A workspace plan is priced per seat and bought by the seat, so its column
    /// prints "per seat" and asks how many before it offers to charge anything.
    var isPerSeat = false
    /// Paddle enforces this on the price itself; the client refuses to go below
    /// it so nobody reaches checkout only to be turned back.
    var minimumSeats = 1
}

enum PaywallFormat {
    /// Yearly rows carry the monthly equivalent, so both cycles print the same
    /// shape and the "billed yearly" line underneath carries the difference.
    static func currency(_ price: PlanPrice?) -> String? {
        guard let price else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = price.currency
        if price.displayAmount.truncatingRemainder(dividingBy: 1) == 0 {
            formatter.maximumFractionDigits = 0
        }
        return formatter.string(from: NSNumber(value: price.displayAmount))
            ?? "\(price.currency) \(price.displayAmount)"
    }

    static func perMonth(_ price: PlanPrice?) -> String {
        guard let amount = currency(price) else { return "—" }
        return "\(amount)/mo"
    }

    static func perSeat(_ price: PlanPrice?) -> String {
        guard let amount = currency(price) else { return "—" }
        return "\(amount)/mo per seat"
    }

    /// A whole number with its thousands separator: seats, credits, hours.
    static func count(_ value: Double) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    /// `Aug 12` — a date inside the period at hand.
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// `Aug 12, 2027` — a date that may be a year away.
    static func fullDay(_ date: Date) -> String {
        fullDayFormatter.string(from: date)
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let fullDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

/// The in-app subscription surface, in the order somebody actually asks about
/// it: what am I on, what have I used, what else is there.
///
/// It reads the current entitlement and the price catalog, and hands a chosen
/// `price_id` to `BillingService` to open a Paddle checkout. The comparison
/// copy mirrors `docs/pricing.md` — this is a marketing surface, so it lives
/// here rather than being derived from the server feature flags. The two values
/// the server owns, hours and devices, are the exception and are read from
/// `public.plans`.
struct PaywallView: View {
    @ObservedObject var billing: BillingService
    @ObservedObject var entitlements: EntitlementService
    /// Absent in previews and for someone in no organization. Decides only
    /// whether the credits card offers a workspace pack — buying for the
    /// workspace is an owner's or admin's act, and the server refuses the rest.
    var organizations: OrganizationService?
    @EnvironmentObject private var analytics: ProductAnalytics

    @State private var cycle = "yearly"
    @State private var referralCode = ""
    @State private var showReferralField = false
    @State private var hasWinbackOffer = false
    /// Starts at the workspace plan's minimum and is re-seeded from the seats the
    /// organization already holds, so an admin of a twelve-seat workspace is not
    /// offered a button that silently drops them to three.
    @State private var seats = PaywallView.workspacePlan.minimumSeats
    /// Once somebody has chosen a number, it is theirs. A background entitlement
    /// refresh must not walk a typed 20 back down to the 5 seats they are
    /// replacing.
    @State private var hasChosenSeats = false

    static let plans: [PaywallPlan] = [
        PaywallPlan(id: "starter", name: "Starter", highlighted: false, badge: nil),
        PaywallPlan(id: "pro", name: "Pro", highlighted: true, badge: "Most popular"),
        PaywallPlan(
            id: "teams", name: "Teams", highlighted: false, badge: nil,
            isPerSeat: true, minimumSeats: 3
        )
    ]

    /// Named, not indexed: the rail's button buys this, and a reordering of
    /// `plans` must not quietly change what somebody is charged for.
    private static let upgradeTarget = plans.first { $0.id == "pro" } ?? plans[0]

    /// The page stops widening past this. A subscription page is read, not
    /// scanned across a monitor: left unbounded, the comparison's labels and its
    /// columns drift a screen apart and the plan card's rail floats away from
    /// the prose it belongs to.
    private static let contentWidth: CGFloat = 900

    // Embeddable content — lives inside the Settings → Subscription pane, which
    // supplies its own ScrollView, title, and window chrome.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Active plan") {
                ActivePlanCard(
                    billing: billing,
                    entitlements: entitlements,
                    cycle: cycle,
                    upgradeTarget: Self.upgradeTarget,
                    hasWinbackOffer: hasWinbackOffer,
                    referralCode: $referralCode,
                    showReferralField: $showReferralField,
                    onChoose: choose,
                    onManage: manage
                )
            }
            section("This period") {
                SubscriptionPeriodTiles(billing: billing, entitlements: entitlements)
                EntitlementCreditsCard(entitlements: entitlements, billing: billing, organizations: organizations)
            }
            comparison
            if let error = billing.lastError {
                Text(error)
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.danger)
            }
            TeamsContactCard()
            Text(
                "Checkout opens in your browser. Your plan updates here automatically once payment completes — billed via our Merchant of Record, taxes included, cancel anytime."
            )
            .textStyle(Theme.Typography.meta)
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Self.contentWidth, alignment: .leading)
        .task {
            analytics.record(
                .paywallViewed,
                properties: .init(
                    entryPoint: .settings,
                    surface: .paywall,
                    outcome: .viewed
                ),
                oncePerSession: "settings"
            )
            await billing.loadPrices()
            await entitlements.refresh()
        }
        // `@Published` emits in `willSet`, so the new value arrives here and not
        // from re-reading the service.
        .onReceive(entitlements.$entitlement) { entitlement in
            syncSeats(with: entitlement)
        }
        .onAppear {
            hasWinbackOffer = BillingService.hasPendingWinbackOffer
            if hasWinbackOffer { cycle = "monthly" }
            // Attribution B: a code captured from a nod://referral deep link
            // pre-fills the field and reveals it. Single-use so it isn't re-applied.
            // Only consume when the field can actually be shown — a paid user has
            // no referral field, so don't silently swallow the pending code.
            guard !isPaid, !hasWinbackOffer else { return }
            if let pending = ReferralService.consumePendingCode() {
                referralCode = pending
                showReferralField = true
            }
        }
    }

    static let workspacePlan = plans.first { $0.isPerSeat } ?? plans[0]

    /// Never below the plan's minimum, and never below what the workspace is
    /// already paying for — reducing seats is a deliberate act, not the default
    /// state of a screen somebody opened.
    private func syncSeats(with entitlement: Entitlement?) {
        guard !hasChosenSeats else { return }
        seats = max(Self.workspacePlan.minimumSeats, entitlement?.seats ?? 0)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Compare all plans")
                    .textStyle(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
                BillingCycleToggle(cycle: $cycle, annualDiscountPercent: annualDiscountPercent)
                    .frame(width: 210)
            }
            PlanComparisonTable(
                billing: billing,
                plans: Self.plans,
                seats: $seats,
                onSeatsEdited: { hasChosenSeats = true },
                cycle: cycle,
                currentPlan: entitlements.entitlement?.plan,
                currentPriceID: entitlements.entitlement?.priceID,
                currentCycle: entitlements.entitlement?.billingCycle,
                isPaid: isPaid,
                isBusy: billing.isStartingCheckout,
                onChoose: choose
            )
        }
    }

    // MARK: - Actions

    private func choose(_ priceID: String) {
        let isPerSeat = billing.prices.first { $0.paddlePriceID == priceID }
            .map { price in Self.plans.contains { $0.id == price.plan && $0.isPerSeat } } ?? false
        Task {
            let outcome = await billing.startCheckout(
                priceID: priceID,
                referralCode: (hasWinbackOffer || isPerSeat) ? nil : referralCode,
                offer: hasWinbackOffer && !isPerSeat ? "winback" : nil,
                seats: isPerSeat ? seats : nil
            )
            if outcome == .planChanged { await entitlements.refresh() }
        }
    }

    private func manage() {
        Task { await billing.openCustomerPortal() }
    }

    /// Percentage saved by paying yearly, computed from the catalogue: the number
    /// used to be hardcoded, which would quietly lie the moment prices change.
    private var annualDiscountPercent: Int? {
        let discounts = Self.plans.map { plan -> Int? in
            guard let yearly = billing.subscriptionPrice(plan: plan.id, cycle: "yearly"),
                  let monthly = billing.subscriptionPrice(plan: plan.id, cycle: "monthly")
            else { return nil }
            return PaywallPriceMath.annualDiscountPercent(
                monthlyPrice: monthly.displayAmount,
                annualMonthlyEquivalent: yearly.displayAmount
            )
        }
        return PaywallPriceMath.commonAnnualDiscountPercent(discounts)
    }

    /// True when this card is the plan AND cycle the subscriber is already on.
    ///
    /// An exact price match wins. Otherwise a grandfathered subscriber — whose
    /// price is no longer in the catalogue — matches on plan plus the cycle the
    /// server reported, so their own cycle reads "current plan" while the other
    /// one stays an offered switch.
    ///
    /// A card is only ever locked when we can name the cycle. Matching on the plan
    /// alone locked BOTH cycle cards, so anyone on Pro monthly who wanted Pro
    /// yearly found the button dead — and a hand-granted plan, which has no Paddle
    /// price at all, could never buy anything. The header already says which plan
    /// they're on, so leaving both cards live loses nothing.
    nonisolated static func isCurrentSelection(
        isPaid: Bool,
        currentPlan: String?,
        currentPriceID: String?,
        currentCycle: String?,
        visiblePriceIDs: Set<String>,
        selectedPlan: String,
        selectedPriceID: String?,
        selectedCycle: String
    ) -> Bool {
        guard isPaid else { return false }
        if let currentPriceID, currentPriceID == selectedPriceID { return true }
        guard currentPlan == selectedPlan else { return false }
        if let currentPriceID, visiblePriceIDs.contains(currentPriceID) { return false }
        guard let currentCycle else { return false }
        return currentCycle == selectedCycle
    }

    /// Whole numbers read as plan limits ("8"), fractions keep one decimal so a
    /// limit set to 7.5 doesn't render as "8".
    static func hoursText(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
    }

    /// A paid (not trial) subscription has a Paddle customer to manage. Includes
    /// `past_due` so a subscriber whose card failed can still reach the portal to
    /// fix it. Trial users have nothing to cancel, so the button stays hidden.
    private var isPaid: Bool {
        let status = entitlements.entitlement?.status
        return status == .active || status == .pastDue
    }
}

// MARK: - Billing-cycle toggle

/// Mirrors the Library `SegmentedControl`: a `surface` track with a sliding
/// `surfaceStrong` pill (matched geometry) and `ink`/`muted` text — so the
/// paywall's tabs read identically to the rest of the app instead of the blue
/// system `.segmented` style.
private struct BillingCycleToggle: View {
    @Binding var cycle: String
    /// Nil when the plans disagree on the discount, so we print no badge rather
    /// than a number that is wrong for one of them.
    let annualDiscountPercent: Int?
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let options: [(id: String, label: String)] = [
        ("yearly", "Yearly"),
        ("monthly", "Monthly")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.options, id: \.id) { option in
                let isSelected = cycle == option.id
                HStack(spacing: 5) {
                    Text(option.label)
                    if option.id == "yearly", let annualDiscountPercent {
                        Text("−\(annualDiscountPercent)%")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.muted)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.Palette.surfaceStrong)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard cycle != option.id else { return }
                    withAnimation(.standard(reduceMotion: reduceMotion)) { cycle = option.id }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }
}

enum PaywallPriceMath {
    static func annualDiscountPercent(monthlyPrice: Double, annualMonthlyEquivalent: Double) -> Int? {
        guard monthlyPrice > 0, annualMonthlyEquivalent < monthlyPrice else { return nil }
        return Int(((1 - annualMonthlyEquivalent / monthlyPrice) * 100).rounded())
    }

    /// One badge for the whole toggle, so it is only shown when every plan really
    /// discounts by the same amount.
    static func commonAnnualDiscountPercent(_ discounts: [Int?]) -> Int? {
        let values = discounts.compactMap { $0 }
        guard !discounts.isEmpty, values.count == discounts.count, Set(values).count == 1 else { return nil }
        return values.first
    }
}

#Preview("Teams contact") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
            PlanChip(text: "Your plan", promotional: false)
            PlanChip(text: "Most popular", promotional: true)
            StatusChip(text: "On free trial until Oct 5, 2026")
        }
        TeamsContactCard()
    }
    .padding(24)
    .frame(width: 620)
    .background(Theme.Palette.bg)
}
