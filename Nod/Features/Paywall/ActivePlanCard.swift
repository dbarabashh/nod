import AppKit
import SwiftUI

/// What the account is on right now, and the one action that changes it.
///
/// Split from the plan grid on purpose: someone opening Subscription is usually
/// answering "what am I paying and when does it renew", not shopping. The grid
/// below is for the second question.
struct ActivePlanCard: View {
    @ObservedObject var billing: BillingService
    @ObservedObject var entitlements: EntitlementService
    let cycle: String
    let upgradeTarget: PaywallPlan
    let hasWinbackOffer: Bool
    @Binding var referralCode: String
    @Binding var showReferralField: Bool
    let onChoose: (String) -> Void
    let onManage: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            summary
            rail
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(Theme.Palette.border, lineWidth: 0.5)
        )
    }

    // MARK: - Left: what you hold

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(planName)
                    .textStyle(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Palette.ink)
                if let state = stateChip {
                    StatusChip(text: state)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(priceLine)
                    .textStyle(Theme.Typography.ui)
                    .foregroundStyle(Theme.Palette.graphite)
                if let usage = usageLine {
                    Text(usage)
                        .textStyle(Theme.Typography.ui)
                        .foregroundStyle(Theme.Palette.graphite)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let footnote {
                    Text(footnote)
                        .textStyle(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.muted)
                }
                // The portal is bound to the caller's own Paddle customer, so
                // it is offered whenever they hold a personal subscription —
                // including while a workspace covers them, which is exactly when
                // somebody needs to find the plan they are still being charged
                // for and stop it.
                if hasPersonalSubscription {
                    Button(action: onManage) {
                        HStack(spacing: 6) {
                            if billing.isOpeningPortal {
                                ProgressView().controlSize(.small).tint(Theme.Palette.muted)
                            }
                            Text("Manage subscription")
                                .textStyle(Theme.Typography.secondary.weight(.medium))
                                .foregroundStyle(Theme.Palette.graphite)
                                .underline()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(billing.isOpeningPortal)
                    .help("Cancel, change plan, update your card, or view invoices")
                } else if isCoveredByWorkspace {
                    Text("Your workspace pays for this.")
                        .textStyle(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var planName: String {
        guard let plan = entitlements.entitlement?.plan, plan != "none" else { return "No plan" }
        return plan.capitalized
    }

    private var stateChip: String? {
        guard let ent = entitlements.entitlement else { return nil }
        switch ent.status {
        case .trialing:
            guard let ends = ent.trialEndsAt else { return "On free trial" }
            return "On free trial until \(PaywallFormat.fullDay(ends))"
        case .pastDue: return "Payment needs attention"
        case .canceled: return "Canceled"
        case .expired: return "Expired"
        case .active, .none: return nil
        }
    }

    /// A trial is charged nothing, so it says so rather than printing the price
    /// of a plan nobody has bought yet.
    private var priceLine: String {
        guard let ent = entitlements.entitlement, ent.isActive else {
            return "Pick a plan to keep capturing."
        }
        if ent.status == .trialing { return "$0 — full Pro access while you trial" }
        // Only the row they are actually on. A grandfathered or founding price is
        // hidden from the client catalogue, and printing the public one in its
        // place tells somebody paying $9 that they pay $15.
        guard let priceID = ent.priceID,
              let price = billing.prices.first(where: { $0.paddlePriceID == priceID })
        else {
            return ent.billingCycle == "monthly" ? "Billed monthly" : "Billed yearly"
        }
        let amount = PaywallFormat.currency(price) ?? "—"
        let cadence = price.billingCycle == "yearly" ? "yearly" : "monthly"
        if ent.payer == .organization, let seats = ent.seats {
            return "\(amount) per seat per month · \(seats) seat\(seats == 1 ? "" : "s") · billed \(cadence)"
        }
        return "\(amount) per month · billed \(cadence)"
    }

    private var usageLine: String? {
        guard let ent = entitlements.entitlement, ent.isActive else { return nil }
        if billing.hoursAreUnlimited(for: ent) {
            return String(format: "%.1f capture hours this period", ent.hoursUsed)
        }
        let used = ent.consumedSeconds / 3_600
        let total = (ent.includedSeconds + ent.topUpSeconds) / 3_600
        // The number is the whole workspace's, not this person's, and saying so
        // is the difference between "I have used a fifth of my hours" and the
        // truth.
        if ent.payer == .organization {
            return String(format: "%.1f of %.0f workspace hours used this period", used, total)
        }
        if ent.hasPurchasedTopUp {
            return String(format: "%.1f of %.0f hours used this period (includes bought hours)", used, total)
        }
        return String(format: "%.1f of %.0f hours used this period", used, total)
    }

    private var footnote: String? {
        guard let ent = entitlements.entitlement else { return nil }
        if ent.status == .trialing, let ends = ent.trialEndsAt {
            return "Trial ends automatically on \(PaywallFormat.fullDay(ends))."
        }
        if ent.status == .active, let renews = ent.renewalDate {
            return "Renews on \(PaywallFormat.fullDay(renews))."
        }
        return nil
    }

    // MARK: - Right: what happens next

    private var rail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(railAmount)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(railCaption)
                        .textStyle(Theme.Typography.meta)
                        .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 0)
                primaryAction
            }
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 0.5)
            HStack(spacing: 14) {
                referralAction
                offerIndicator
                Spacer(minLength: 0)
            }
            if showReferralField {
                referralField
            }
            if hasWinbackOffer {
                Text(
                    "Applies 15% to the first monthly Starter or Pro billing period. Expires 14 days after it was issued."
                )
                .textStyle(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(Theme.Palette.surface)
        )
    }

    /// The number and the button have to agree: on Pro it is what renews, and
    /// everywhere else it is what the button is about to charge.
    private var railPrice: PlanPrice? {
        if isOnUpgradeTarget, let ent = entitlements.entitlement {
            return billing.subscriptionPrice(plan: ent.plan, cycle: ent.billingCycle ?? cycle)
        }
        return billing.subscriptionPrice(plan: upgradeTarget.id, cycle: cycle)
    }

    private var railAmount: String {
        PaywallFormat.currency(railPrice) ?? "—"
    }

    private var railCaption: String {
        guard let price = railPrice else { return "total per month" }
        return price.billingCycle == "yearly" ? "per month, billed yearly" : "total per month"
    }

    private var isOnUpgradeTarget: Bool {
        isPaid && entitlements.entitlement?.plan == upgradeTarget.id
    }

    /// Somebody a workspace pays for gains nothing from a personal plan — the
    /// resolver keeps resolving them to the organization — so the rail stops
    /// offering one. The seats are bought from the Teams column instead.
    private var isCoveredByWorkspace: Bool {
        entitlements.entitlement?.payer == .organization
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isCoveredByWorkspace {
            EmptyView()
        } else {
            personalAction
        }
    }

    private var personalAction: some View {
        Button {
            if isOnUpgradeTarget {
                onManage()
            } else if let id = railPrice?.paddlePriceID {
                onChoose(id)
            }
        } label: {
            HStack(spacing: 6) {
                if billing.isStartingCheckout {
                    ProgressView().controlSize(.small).tint(Theme.GlassButton.text)
                }
                Text(isOnUpgradeTarget ? "Manage" : (isPaid ? "Upgrade" : "Choose \(upgradeTarget.name)"))
                    .textStyle(Theme.Typography.uiEmphasis.weight(.semibold))
                Image("nc-circle-arrow-up")
                    .icon(11)
            }
            .foregroundStyle(Theme.GlassButton.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassButtonSurface(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(billing.isStartingCheckout || (!isOnUpgradeTarget && railPrice == nil))
    }

    @ViewBuilder
    private var referralAction: some View {
        if isPaid {
            EmptyView()
        } else {
            Button("Have a referral code?") { showReferralField = true }
                .buttonStyle(.plain)
                .textStyle(Theme.Typography.secondary.weight(.medium))
                .foregroundStyle(Theme.Palette.graphite)
                .disabled(showReferralField)
                .opacity(showReferralField ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var offerIndicator: some View {
        if hasWinbackOffer {
            IconLabel(title: "Offer applied", icon: "nc-gift", size: 11)
                .textStyle(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.graphite)
        }
    }

    private var referralField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Friend's referral code", text: $referralCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .onChange(of: referralCode) { newValue in
                    let upper = newValue.uppercased()
                    if upper != referralCode { referralCode = upper }
                }
            Text("A friend's 6-letter Nod code, not a coupon. Applies −50% off your first month of Starter or Pro (monthly billing).")
                .textStyle(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    private var isPaid: Bool {
        let status = entitlements.entitlement?.status
        return status == .active || status == .pastDue
    }

    /// A Paddle subscription of their own, whoever is currently paying for the
    /// plan they resolve to.
    private var hasPersonalSubscription: Bool {
        billing.hasPersonalSubscription
    }
}

/// The state badge beside the plan name — trial expiry, a failed card, a
/// cancellation. Quieter than `PlanChip`: it reports, it doesn't sell.
struct StatusChip: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(Theme.Typography.secondary.weight(.medium))
            .foregroundStyle(Theme.Palette.graphite)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(Theme.Palette.surface))
            .overlay(Capsule(style: .continuous).stroke(Theme.Palette.border, lineWidth: 0.5))
    }
}

/// Three numbers about the period in flight, so the answer to "how much have I
/// used" doesn't require reading the plan card's prose.
struct SubscriptionPeriodTiles: View {
    @ObservedObject var billing: BillingService
    @ObservedObject var entitlements: EntitlementService

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            tile(title: isWorkspace ? "Workspace hours" : "Capture hours", value: usedHours)
            tile(title: "Remaining", value: remainingHours)
            tile(title: renewalTitle, value: renewalValue)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(Theme.Palette.border, lineWidth: 0.5)
        )
    }

    private var isWorkspace: Bool {
        entitlements.entitlement?.payer == .organization
    }

    private func tile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .textStyle(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usedHours: String {
        guard let ent = entitlements.entitlement else { return "—" }
        return String(format: "%.1f", ent.hoursUsed)
    }

    private var remainingHours: String {
        guard let ent = entitlements.entitlement, ent.isActive else { return "—" }
        if billing.hoursAreUnlimited(for: ent) { return "Unlimited" }
        return String(format: "%.1f", ent.remainingSeconds / 3_600)
    }

    /// A workspace subscription carries no trial end date, so its tile asks the
    /// question it can answer rather than printing a dash under "Trial ends".
    private var renewalTitle: String {
        guard let ent = entitlements.entitlement else { return "Renews" }
        return ent.status == .trialing && ent.payer != .organization ? "Trial ends" : "Renews"
    }

    private var renewalValue: String {
        guard let ent = entitlements.entitlement else { return "—" }
        let date = ent.status == .trialing && ent.payer != .organization
            ? ent.trialEndsAt
            : ent.renewalDate
        guard let date else { return "—" }
        return PaywallFormat.day(date)
    }
}

/// The bottom of the page, where the self-serve ladder runs out. Teams is on the
/// page now, so this is what sits above it: a conversation, and nothing else —
/// there is no enterprise plan to name.
struct TeamsContactCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Larger organization?")
                    .textStyle(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Text("Tell us how your company works and we'll come back with options.")
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
            Button {
                guard let url = URL(string: "mailto:dmytro@hellonod.app?subject=Nod%20for%20teams") else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Text("Talk to us")
                    .textStyle(Theme.Typography.secondary.weight(.semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Palette.surfaceStrong)
                            .overlay(Capsule(style: .continuous).stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(Theme.Palette.border, lineWidth: 0.5)
        )
    }
}
