import SwiftUI

/// One row of the plan-comparison matrix. A row says the same thing about every
/// plan, so the copy is written once and each column answers it.
///
/// `hours` and `devices` are deliberately not literals: they are the two values
/// `public.plans` can change under us, and a number typed here once sold Pro on
/// 50 hours after the server had already cut it. They resolve at render time.
struct PlanFeature: Identifiable {
    enum Value {
        case yes
        case no
        case hours
        /// The same number, said the way a workspace buys it.
        case hoursPerSeat
        case devices
        case integrations
    }

    let title: String
    let values: [String: Value]

    var id: String {
        title
    }

    func value(for plan: String) -> Value {
        values[plan] ?? .no
    }
}

enum PlanComparison {
    /// Mirrors the feature table in `docs/pricing.md`. Titles are short on
    /// purpose — every row is one line tall so the columns stay aligned.
    static let features: [PlanFeature] = [
        PlanFeature(title: "Unlimited memory", values: ["starter": .yes, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Capture hours / month", values: ["starter": .hours, "pro": .hours, "teams": .hoursPerSeat]),
        PlanFeature(title: "Devices", values: ["starter": .devices, "pro": .devices, "teams": .devices]),
        PlanFeature(title: "Live transcription & summaries", values: ["starter": .yes, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Records you and the other side", values: ["starter": .yes, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Audio is never stored", values: ["starter": .yes, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Speaker labels", values: ["starter": .yes, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Ask about a single session", values: ["starter": .yes, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Ask across everything", values: ["starter": .no, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Project-scoped questions", values: ["starter": .no, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Ask Nod live", values: ["starter": .no, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Screen context", values: ["starter": .no, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Integrations", values: ["starter": .integrations, "pro": .integrations, "teams": .integrations]),
        PlanFeature(title: "Early access + priority support", values: ["starter": .no, "pro": .yes, "teams": .yes]),
        PlanFeature(title: "Shared workspace memory", values: ["starter": .no, "pro": .no, "teams": .yes]),
        PlanFeature(title: "Pooled hours across seats", values: ["starter": .no, "pro": .no, "teams": .yes]),
        PlanFeature(title: "Central billing and admin", values: ["starter": .no, "pro": .no, "teams": .yes])
    ]

    /// Examples of what each tier reaches, not the whole catalogue. Starter
    /// carries `integrations_core` — the calendar and where notes are exported
    /// to; everything above it carries `integrations_all` as well, which is the
    /// row's actual difference. Every provider named here ships a brand mark, so
    /// the paywall never waits on the broker's logo CDN.
    static func integrations(for plan: String) -> [IntegrationProvider] {
        let core: [IntegrationProvider] = [.googleCalendar, .notion, .googleDrive]
        guard plan != "starter" else { return core }
        return core + [.slack, .linear, .jira]
    }

    /// Whether the row ends in a plus. The catalogue is not the limit above
    /// Starter — a tool Nod has no adapter for can be asked for, and the plans
    /// that get one built are the ones that say so here.
    static func offersCustomIntegrations(_ plan: String) -> Bool {
        plan != "starter"
    }
}

/// The matrix: one column per plan, one row per capability, the plan you hold
/// tinted for its whole height.
///
/// Built from columns rather than a `Grid` because the tint belongs to the
/// column, not to thirteen separate cells — the fixed `rowHeight` is what keeps
/// the labels and the ticks on the same line.
struct PlanComparisonTable: View {
    @ObservedObject var billing: BillingService
    let plans: [PaywallPlan]
    /// How many seats a per-seat plan is being bought for. Lives here because the
    /// number and the button that spends it belong in the same column.
    @Binding var seats: Int
    /// Told once the number stops being ours to choose for them.
    let onSeatsEdited: () -> Void
    let cycle: String
    let currentPlan: String?
    let currentPriceID: String?
    let currentCycle: String?
    let isPaid: Bool
    let isBusy: Bool
    let onChoose: (String) -> Void

    private let rowHeight: CGFloat = 32
    private let headerHeight: CGFloat = 128
    private let columnWidth: CGFloat = 148

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            labelColumn
            ForEach(plans) { plan in
                planColumn(plan)
            }
        }
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: headerHeight)
            SectionLabel("Features")
                .frame(height: rowHeight, alignment: .leading)
            ForEach(PlanComparison.features) { feature in
                Text(feature.title)
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.graphite)
                    .lineLimit(1)
                    .frame(height: rowHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planColumn(_ plan: PaywallPlan) -> some View {
        let isCurrentPlan = isPaid && currentPlan == plan.id

        return VStack(spacing: 0) {
            columnHeader(plan, isCurrentPlan: isCurrentPlan)
                .frame(height: headerHeight)
            Color.clear.frame(height: rowHeight)
            ForEach(PlanComparison.features) { feature in
                cell(feature.value(for: plan.id), plan: plan.id)
                    .frame(height: rowHeight)
            }
        }
        .frame(width: columnWidth)
        .padding(.bottom, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(isCurrentPlan ? Theme.Palette.surface : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(isCurrentPlan ? Theme.Palette.border : .clear, lineWidth: 0.5)
        )
    }

    private func columnHeader(_ plan: PaywallPlan, isCurrentPlan: Bool) -> some View {
        let price = billing.subscriptionPrice(plan: plan.id, cycle: cycle)
        let isCurrent = PaywallView.isCurrentSelection(
            isPaid: isPaid,
            currentPlan: currentPlan,
            currentPriceID: currentPriceID,
            currentCycle: currentCycle,
            visiblePriceIDs: Set(billing.prices.map(\.paddlePriceID)),
            selectedPlan: plan.id,
            selectedPriceID: price?.paddlePriceID,
            selectedCycle: cycle
        )

        return VStack(spacing: 6) {
            Text(plan.name)
                .textStyle(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.ink)
            Text(plan.isPerSeat ? PaywallFormat.perSeat(price) : PaywallFormat.perMonth(price))
                .textStyle(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.muted)
            if isCurrentPlan {
                PlanChip(text: "Your plan", promotional: false)
                    .padding(.top, 2)
            } else if let badge = plan.badge {
                PlanChip(text: badge, promotional: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if plan.isPerSeat {
                seatStepper(minimum: plan.minimumSeats)
            }
            columnButton(plan, price: price, isCurrent: isCurrent, isSamePlan: isCurrentPlan)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func columnButton(
        _ plan: PaywallPlan,
        price: PlanPrice?,
        isCurrent: Bool,
        isSamePlan: Bool
    ) -> some View {
        Button {
            guard let id = price?.paddlePriceID else { return }
            onChoose(id)
        } label: {
            Text(label(plan: plan, isCurrent: isCurrent, isSamePlan: isSamePlan))
                .textStyle(Theme.Typography.secondary.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(
                    isCurrent
                        ? Theme.Palette.muted
                        : (plan.highlighted ? Theme.GlassButton.text : Theme.Palette.ink)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(background(highlighted: plan.highlighted, isCurrent: isCurrent))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || price == nil || isBusy)
    }

    /// A workspace buys a number of seats, so the number is chosen before the
    /// button is pressed rather than on a screen after it.
    private func seatStepper(minimum: Int) -> some View {
        HStack(spacing: 0) {
            stepperButton("nc-minus", enabled: seats > minimum) {
                seats = max(minimum, seats - 1)
                onSeatsEdited()
            }
            Text("\(seats)")
                .textStyle(Theme.Typography.uiEmphasis)
                .foregroundStyle(Theme.Palette.ink)
                .frame(maxWidth: .infinity)
                .monospacedDigit()
            stepperButton("nc-plus", enabled: seats < 500) {
                seats += 1
                onSeatsEdited()
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Seats")
        .accessibilityValue("\(seats)")
    }

    private func stepperButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon)
                .icon(9)
                .foregroundStyle(enabled ? Theme.Palette.ink : Theme.Palette.muted.opacity(0.4))
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// "Switch to Pro" on the plan they already hold reads as a no-op, so when
    /// only the billing cycle differs the button names the cycle instead.
    private func label(plan: PaywallPlan, isCurrent: Bool, isSamePlan: Bool) -> String {
        if isCurrent { return "Current" }
        if plan.isPerSeat { return seats == 1 ? "Buy 1 seat" : "Buy \(seats) seats" }
        guard isPaid else { return "Choose \(plan.name)" }
        guard isSamePlan else { return "Switch to \(plan.name)" }
        return cycle == "yearly" ? "Switch to yearly" : "Switch to monthly"
    }

    @ViewBuilder
    private func background(highlighted: Bool, isCurrent: Bool) -> some View {
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

    @ViewBuilder
    private func cell(_ value: PlanFeature.Value, plan: String) -> some View {
        switch value {
        case .yes:
            Image("nc-check")
                .icon(11)
                .foregroundStyle(Theme.Palette.ink)
        case .no:
            Image("nc-xmark")
                .icon(10)
                .foregroundStyle(Theme.Palette.muted.opacity(0.55))
        case .hours:
            valueText(hoursText(plan: plan))
        case .hoursPerSeat:
            valueText(hoursText(plan: plan).map { "\($0) / seat" })
        case .devices:
            valueText(billing.devices(plan: plan).map { PaywallView.hoursText($0) })
        case .integrations:
            HStack(spacing: 3) {
                ForEach(PlanComparison.integrations(for: plan)) { provider in
                    ProviderMark(provider: provider, size: 13)
                }
                if PlanComparison.offersCustomIntegrations(plan) {
                    Image("nc-plus")
                        .icon(9)
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 13, height: 13)
                        .help("Ask for a tool Nod doesn't support yet — we build them")
                        .accessibilityLabel("Custom integrations on request")
                }
            }
        }
    }

    private func hoursText(plan: String) -> String? {
        if billing.hoursAreUnlimited(plan: plan) { return "Unlimited" }
        return billing.hoursPerMonth(plan: plan).map(PaywallView.hoursText)
    }

    /// A dash rather than a guess: the catalog hasn't loaded yet, and inventing
    /// the number here is exactly what these two rows exist to avoid.
    private func valueText(_ text: String?) -> some View {
        Text(text ?? "—")
            .textStyle(Theme.Typography.secondary)
            .foregroundStyle(Theme.Palette.graphite)
    }
}

/// The promotional badge ("Most popular") sells; the status badge ("Your plan")
/// informs. Same shape, different weight, and the status one wins the slot —
/// what someone already pays for matters more than what we'd like them to buy.
struct PlanChip: View {
    let text: String
    let promotional: Bool

    var body: some View {
        let label = Text(text.uppercased())
            .textStyle(Theme.Typography.micro)
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

        if promotional {
            label
                .foregroundStyle(Theme.GlassButton.text)
                .background(Capsule(style: .continuous).fill(Theme.GlassButton.fill))
        } else {
            label
                .foregroundStyle(Theme.Palette.graphite)
                .background(Capsule(style: .continuous).fill(Theme.Palette.surface))
                .overlay(Capsule(style: .continuous).stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
        }
    }
}
