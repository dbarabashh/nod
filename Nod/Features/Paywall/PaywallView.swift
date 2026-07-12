import SwiftUI

/// The in-app upgrade surface. Reads the current entitlement (to show what the
/// user has now) and the price catalog, and hands a chosen `price_id` to
/// `BillingService` to open a Paddle checkout. Plan bullet lists mirror
/// `docs/pricing.md` — this is a marketing surface, so the copy lives here
/// rather than being derived from the server feature flags.
///
/// Styling follows the Library window: `WindowBackdrop` vibrancy, the same pill
/// segmented control, `Theme.Palette` surfaces/borders, and the brand-gradient
/// CTA — so the paywall reads as the same product, not a system-styled bolt-on.
struct PaywallView: View {
    @ObservedObject var billing: BillingService
    @ObservedObject var entitlements: EntitlementService

    @State private var cycle = "yearly"
    @State private var referralCode = ""
    @State private var showReferralField = false

    private struct PlanCopy {
        let id: String
        let name: String
        let tagline: String
        let highlighted: Bool
        let badge: String?
        let features: [String]
    }

    private static let plans: [PlanCopy] = [
        PlanCopy(
            id: "starter", name: "Starter",
            tagline: "Your AI notetaker, fully unlocked.",
            highlighted: false, badge: nil,
            features: [
                "15 meeting hours / month",
                "1 device",
                "Records you and the other side",
                "Live transcription, summaries & action items",
                "Ask Nod about any meeting",
                "Unlimited history, folders & search"
            ]
        ),
        PlanCopy(
            id: "pro", name: "Pro",
            tagline: "For people who live in meetings.",
            highlighted: true, badge: "Most popular",
            features: [
                "50 meeting hours / month",
                "Up to 3 devices",
                "Everything in Starter, plus:",
                "Ask Nod across all meetings — your knowledge base",
                "Folder-scoped questions",
                "Early access + priority support"
            ]
        )
    ]

    // Embeddable content — lives inside the Settings → Subscription pane, which
    // supplies its own ScrollView, title, and window chrome.
    var body: some View {
        VStack(spacing: 20) {
            header
            BillingCycleToggle(cycle: $cycle)
                .frame(width: 240)
            HStack(alignment: .top, spacing: 14) {
                ForEach(Self.plans, id: \.id) { plan in
                    planCard(plan)
                }
            }
            if isPaid {
                manageButton
            } else {
                referralField
            }
            if let error = billing.lastError {
                Text(error)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.danger)
                    .multilineTextAlignment(.center)
            }
            Text(
                "Checkout opens in your browser. Your plan updates here automatically once payment completes — billed via our Merchant of Record, taxes included, cancel anytime."
            )
            .font(.system(size: 11.5, weight: .regular))
            .foregroundStyle(Theme.Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .task {
            await billing.loadPrices()
            await entitlements.refresh()
        }
        .onAppear {
            // Attribution B: a code captured from a nod://referral deep link
            // pre-fills the field and reveals it. Single-use so it isn't re-applied.
            // Only consume when the field can actually be shown — a paid user has
            // no referral field, so don't silently swallow the pending code.
            guard !isPaid else { return }
            if let pending = ReferralService.consumePendingCode() {
                referralCode = pending
                showReferralField = true
            }
        }
    }

    // MARK: - Referral code (attribution A)

    @ViewBuilder
    private var referralField: some View {
        if showReferralField {
            VStack(spacing: 6) {
                TextField("Referral code", text: $referralCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(maxWidth: 220)
                    .onChange(of: referralCode) { newValue in
                        let upper = newValue.uppercased()
                        if upper != referralCode { referralCode = upper }
                    }
                Text("Applies −50% off your first month (monthly billing).")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        } else {
            Button("Have a referral code?") { showReferralField = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.graphite)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(statusHeadline)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.Palette.ink)
            if let sub = statusSubline {
                Text(sub)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }

    private var statusHeadline: String {
        guard let ent = entitlements.entitlement else { return "Choose your plan" }
        switch ent.status {
        case .trialing: return "You're on the free trial"
        case .active: return "You're on \(ent.plan.capitalized)"
        case .pastDue: return "Your payment needs attention"
        case .canceled, .expired, .none: return "Pick a plan to keep Nod"
        }
    }

    private var statusSubline: String? {
        guard let ent = entitlements.entitlement else { return nil }
        if ent.status == .trialing, let ends = ent.trialEndsAt {
            let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: ends).day ?? 0)
            return "\(days) day\(days == 1 ? "" : "s") left · full Pro access"
        }
        if ent.isActive {
            return String(format: "%.1f of %.0f hours used this period", ent.hoursUsed, ent.hoursLimit)
        }
        return nil
    }

    /// A paid (not trial) subscription has a Paddle customer to manage. Includes
    /// `past_due` so a subscriber whose card failed can still reach the portal to
    /// fix it. Trial users have nothing to cancel, so the button stays hidden.
    private var isPaid: Bool {
        let status = entitlements.entitlement?.status
        return status == .active || status == .pastDue
    }

    private var manageButton: some View {
        Button {
            Task { await billing.openCustomerPortal() }
        } label: {
            HStack(spacing: 6) {
                if billing.isOpeningPortal {
                    ProgressView().controlSize(.small).tint(Theme.Palette.muted)
                }
                Text("Manage subscription")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.graphite)
                    .underline()
            }
        }
        .buttonStyle(.plain)
        .disabled(billing.isOpeningPortal)
        .help("Cancel, change plan, update your card, or view invoices")
    }

    // MARK: - Plan card

    private func planCard(_ plan: PlanCopy) -> some View {
        let price = billing.subscriptionPrice(plan: plan.id, cycle: cycle)
        // Match on the exact price, not just the plan, so the OTHER billing cycle
        // of the current plan reads "Switch to …" (a real in-place change) rather
        // than a disabled "Current plan".
        let isCurrent = isPaid
            && price?.paddlePriceID != nil
            && entitlements.entitlement?.priceID == price?.paddlePriceID

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(plan.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
                if let badge = plan.badge {
                    Text(badge.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Theme.GlassButton.fill))
                }
            }
            Text(plan.tagline)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(priceLabel(price))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.ink)
                Text("/mo")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Text(cycle == "yearly" ? "billed yearly" : "billed monthly")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)

            ctaButton(plan: plan, price: price, isCurrent: isCurrent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.features, id: \.self) { feature in
                    featureRow(feature)
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(plan.highlighted ? Theme.GlassButton.border : Theme.Palette.border, lineWidth: plan.highlighted ? 1 : 0.5)
        )
    }

    private func ctaButton(plan: PlanCopy, price: PlanPrice?, isCurrent: Bool) -> some View {
        // Already subscribed → switching plans updates the one subscription in
        // place (no second checkout). Not subscribed → a fresh checkout.
        let label = isCurrent ? "Current plan" : (isPaid ? "Switch to \(plan.name)" : "Choose \(plan.name)")
        return Button {
            guard let id = price?.paddlePriceID else { return }
            Task {
                let outcome = await billing.startCheckout(priceID: id, referralCode: referralCode)
                if outcome == .planChanged { await entitlements.refresh() }
            }
        } label: {
            HStack(spacing: 7) {
                if billing.isStartingCheckout {
                    ProgressView().controlSize(.small).tint(plan.highlighted ? Theme.GlassButton.text : Theme.Palette.ink)
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isCurrent ? Theme.Palette.muted : (plan.highlighted ? Theme.GlassButton.text : Theme.Palette.ink))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(ctaBackground(highlighted: plan.highlighted, isCurrent: isCurrent))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || price == nil || billing.isStartingCheckout)
    }

    @ViewBuilder
    private func ctaBackground(highlighted: Bool, isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
        if isCurrent {
            shape.fill(Theme.Palette.surface)
                .overlay(shape.stroke(Theme.Palette.border, lineWidth: 0.5))
        } else if highlighted {
            shape.fill(Theme.GlassButton.fill)
                .overlay(shape.stroke(Theme.GlassButton.border, lineWidth: Theme.GlassButton.borderWidth))
        } else {
            shape.fill(Theme.Palette.surfaceStrong)
                .overlay(shape.stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
        }
    }

    private func featureRow(_ feature: String) -> some View {
        let isHeader = feature.hasSuffix("plus:")
        return HStack(alignment: .top, spacing: 8) {
            if !isHeader {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 14)
            }
            Text(feature)
                .font(.system(size: isHeader ? 10.5 : 12.5, weight: isHeader ? .semibold : .regular))
                .tracking(isHeader ? 0.4 : 0)
                .textCase(isHeader ? .uppercase : nil)
                .foregroundStyle(isHeader ? Theme.Palette.muted : Theme.Palette.graphite)
        }
    }

    private func priceLabel(_ price: PlanPrice?) -> String {
        guard let price else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = price.currency
        if price.displayAmount.truncatingRemainder(dividingBy: 1) == 0 {
            formatter.maximumFractionDigits = 0
        }
        return formatter.string(from: NSNumber(value: price.displayAmount))
            ?? "\(price.currency) \(price.displayAmount)"
    }
}

// MARK: - Billing-cycle toggle

/// Mirrors the Library `SegmentedControl`: a `surface` track with a sliding
/// `surfaceStrong` pill (matched geometry) and `ink`/`muted` text — so the
/// paywall's tabs read identically to the rest of the app instead of the blue
/// system `.segmented` style.
private struct BillingCycleToggle: View {
    @Binding var cycle: String
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
                    if option.id == "yearly" {
                        Text("−35%")
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
