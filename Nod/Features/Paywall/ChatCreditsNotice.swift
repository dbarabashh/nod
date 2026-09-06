import Supabase
import SwiftUI

/// The row under an answer when a read of a connected tool was refused for
/// want of integration credits.
///
/// Its own row rather than a line in the trace: the trace is a record for
/// checking, and this is a bill. The server's refusal is addressed to the
/// model ("answer with what you already know"), so the person is told in
/// their own terms — what stopped, when it refills, and the one thing they can
/// do about it now. Reads the live entitlement rather than the refusal so a
/// pack bought from this row turns the sentence into "credits added" instead
/// of leaving a stale warning under an answer that is no longer true.
struct ChatCreditsNotice: View {
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var billing: BillingService
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var analytics: ProductAnalytics

    /// The entitlement the row was born with is the one the refusal was made
    /// against, but the app's copy of it can lag the server by a read or two.
    /// "Credits are back" is claimed only once this row has asked the server.
    @State private var hasRefreshed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(replenished ? "nc-check" : "nc-hourglass")
                .icon(11)
                .foregroundStyle(replenished ? Theme.Palette.success : Theme.Palette.warning)
            Text(sentence)
                .textStyle(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .onAppear {
            // Once per app session: the row stays on screen across turns, and
            // every turn it survives is not a new refusal.
            analytics.record(
                .errorShown,
                properties: .init(reasonCode: .creditsExhausted, surface: .ask),
                oncePerSession: "credits"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .stroke(tint.opacity(0.25), lineWidth: 0.5)
                )
        )
        .task {
            guard !hasRefreshed else { return }
            if billing.prices.isEmpty { await billing.loadPrices() }
            await entitlements.refresh()
            hasRefreshed = true
        }
    }

    private var entitlement: Entitlement? {
        entitlements.entitlement
    }

    private var replenished: Bool {
        guard hasRefreshed, !entitlements.loadFailed, let entitlement else { return false }
        return entitlement.integrationCreditsIncluded - entitlement.integrationCreditsUsed > 0
    }

    private var tint: Color {
        replenished ? Theme.Palette.success : Theme.Palette.warning
    }

    private var isShared: Bool {
        entitlement?.payer == .organization
    }

    private var isPaid: Bool {
        entitlement?.status == .active
    }

    private var isTrialing: Bool {
        entitlement?.status == .trialing
    }

    /// The server sends the same refusal for "spent" and "not paying". The
    /// entitlement tells them apart, and only the first one refills.
    private var hasPlan: Bool {
        entitlement == nil || isPaid || isTrialing
    }

    private var administers: Bool {
        organizations.activeMembership?.role.administers ?? false
    }

    private var pack: PlanPrice? {
        guard isPaid, let plan = entitlement?.plan else { return nil }
        return billing.creditPackOffer(plan: plan)
    }

    private var canBuy: Bool {
        pack != nil && (!isShared || administers)
    }

    private var sentence: String {
        if replenished {
            return "Integration credits are back. Ask again and Nod will read your connected tools."
        }
        guard hasPlan else {
            return "Reading connected tools needs an active plan, so Nod answered from what it already knows."
        }
        let pool = isShared ? "Your workspace's integration credits" : "Your integration credits"
        let refill = (isPaid ? entitlement?.renewalDate : nil)
            .map { "refill on \(PaywallFormat.day($0))" } ?? "refill next period"
        let base = "\(pool) for this period are used up, so Nod answered from what it already knows. They \(refill)"
        if canBuy {
            return base + ", or add a pack now."
        }
        if isShared, pack != nil {
            return base + ". An owner or admin can add a pack from Organization → Billing."
        }
        if isTrialing {
            return base + ". Packs are available on a paid plan."
        }
        return base + "."
    }

    @ViewBuilder
    private var action: some View {
        if replenished {
            EmptyView()
        } else if !hasPlan {
            link("See plans", to: .nodOpenSubscription)
        } else if canBuy, let pack, let credits = pack.topUpCredits, let sku = pack.sku,
                  let amount = PaywallFormat.currency(pack) {
            GlassPillButton(
                "Add \(PaywallFormat.count(credits)) · \(amount)",
                size: .compact,
                isLoading: billing.isStartingTopUp,
                tint: .brand
            ) {
                Task { _ = await billing.startTopUp(sku: sku, surface: .chat) }
            }
            .linkCursor()
        } else if isShared, pack != nil {
            link("Open Billing", to: .nodOpenOrganizationBilling)
        } else if isTrialing {
            link("See plans", to: .nodOpenSubscription)
        }
    }

    private func link(_ label: String, to name: Notification.Name) -> some View {
        Button(label) { NotificationCenter.default.post(name: name, object: nil) }
            .buttonStyle(.plain)
            .textStyle(Theme.Typography.meta)
            .foregroundStyle(Theme.Palette.violet)
            .linkCursor()
    }
}

#Preview {
    let supabase = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
    return ChatCreditsNotice()
        .environmentObject(EntitlementService(supabase: supabase))
        .environmentObject(BillingService(supabase: supabase))
        .environmentObject(OrganizationService.preview(memberships: []))
        .environmentObject(ProductAnalytics.preview)
        .padding()
        .frame(width: 520)
        .background(Theme.Palette.bg)
}
