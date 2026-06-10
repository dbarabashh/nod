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
                "Unlimited history, labels & search"
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
                "Label-scoped questions",
                "Early access + priority support"
            ]
        )
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                BillingCycleToggle(cycle: $cycle)
                    .frame(width: 240)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Self.plans, id: \.id) { plan in
                        planCard(plan)
                    }
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
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .padding(.top, 36)
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(WindowBackdrop().ignoresSafeArea())
        .task {
            await billing.loadPrices()
            await entitlements.refresh()
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

    // MARK: - Plan card

    private func planCard(_ plan: PlanCopy) -> some View {
        let price = billing.subscriptionPrice(plan: plan.id, cycle: cycle)
        let isCurrent = entitlements.entitlement?.plan == plan.id && entitlements.entitlement?.isActive == true

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
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
                }
            }
            Text(plan.tagline)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)

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
                .stroke(plan.highlighted ? Theme.Palette.violet.opacity(0.55) : Theme.Palette.border, lineWidth: plan.highlighted ? 1 : 0.5)
        )
    }

    private func ctaButton(plan: PlanCopy, price: PlanPrice?, isCurrent: Bool) -> some View {
        Button {
            if let id = price?.paddlePriceID {
                Task { await billing.startCheckout(priceID: id) }
            }
        } label: {
            HStack(spacing: 7) {
                if billing.isStartingCheckout {
                    ProgressView().controlSize(.small).tint(Theme.Palette.ink)
                }
                Text(isCurrent ? "Current plan" : "Choose \(plan.name)")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isCurrent ? Theme.Palette.muted : Theme.Palette.ink)
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
            shape.fill(Theme.Gradients.buttonBrand)
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
                    .foregroundStyle(Theme.Palette.violet)
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
        let symbol = price.currency == "USD" ? "$" : "\(price.currency) "
        let amount = price.displayAmount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(price.displayAmount))
            : String(price.displayAmount)
        return "\(symbol)\(amount)"
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
                    withAnimation(.easeInOut(duration: 0.2)) { cycle = option.id }
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
