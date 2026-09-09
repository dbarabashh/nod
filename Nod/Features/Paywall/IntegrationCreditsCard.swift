import SwiftUI

/// The integration credit pool, and the one way to add to it.
///
/// Sits on every page where the pool is spent or paid for — Integrations,
/// Subscription, a workspace's Billing — because the thing people need to know
/// is not the number but what happens at zero: reads of connected tools pause
/// until the period refills or a pack is bought. So the card says that in
/// words whenever the pool is low or gone, and carries the pack beside the
/// count when the viewer is the one who can buy it.
struct IntegrationCreditsCard: View {
    let used: Double
    let included: Double
    let plan: String
    /// A workspace's pool rather than one person's.
    let isShared: Bool
    /// Whether the plan is being paid for. A pack is sold only against one,
    /// and a trial's renewal date is the day it ends, not a refill.
    let isActive: Bool
    /// Whether the viewer may spend the workspace's money; ignored for a
    /// personal pool, which its holder may always top up.
    let administers: Bool
    let renewalDate: Date?
    @ObservedObject var billing: BillingService

    private var share: Double {
        included > 0 ? used / included : 0
    }

    private var tint: Color {
        share >= 0.9 ? Theme.Palette.danger : share >= 0.7 ? Theme.Palette.warning : Theme.Palette.ink
    }

    private var canBuy: Bool {
        isActive && (!isShared || administers)
    }

    private var refillsOn: Date? {
        isActive ? renewalDate : nil
    }

    var body: some View {
        let offer = billing.creditPackOffer(plan: plan)
        SettingsCard {
            SettingsRow(
                icon: "nc-hourglass",
                title: isShared ? "Workspace integration credits" : "Integration credits",
                subtitle: subtitle(hasOffer: offer != nil)
            ) {
                HStack(spacing: 12) {
                    Text("\(PaywallFormat.count(used)) of \(PaywallFormat.count(included))")
                        .textStyle(Theme.Typography.uiEmphasis)
                        .foregroundStyle(tint)
                        .monospacedDigit()
                    if canBuy, let pack = offer,
                       let credits = pack.topUpCredits, let sku = pack.sku,
                       let amount = PaywallFormat.currency(pack) {
                        GlassPillButton(
                            "Add \(PaywallFormat.count(credits)) · \(amount)",
                            size: .compact,
                            isLoading: billing.isStartingTopUp,
                            tint: .brand
                        ) {
                            Task { _ = await billing.startTopUp(sku: sku, surface: .settings) }
                        }
                        .linkCursor()
                        .help(isShared
                            ? "One-time pack for this period, added to the workspace's pool"
                            : "One-time pack for this period")
                    }
                }
            }
        }
    }

    /// What the number means, and what to do about it — the second half only
    /// once it matters. A fresh pool needs no warning; a pool at zero needs the
    /// whole sentence, including who can buy more when the reader cannot.
    private func subtitle(hasOffer: Bool) -> String {
        let refill = refillsOn.map { "refills on \(PaywallFormat.day($0))" } ?? "refills next period"
        let buy = buyClause(hasOffer: hasOffer)
        if used >= included {
            return "Used up. Nod stops reading connected tools and answers from what it already knows until the pool \(refill)\(buy)."
        }
        let base = "One credit each time Nod reads a connected tool for you. Filing tickets, sending messages and exporting notes are free."
        let pool = isShared ? " Shared across everyone the workspace covers, \(refill)." : " The pool \(refill)."
        if share >= 0.7 {
            return base + pool + " When it runs out, reads pause until it \(refill)\(buy)."
        }
        return base + pool
    }

    private func buyClause(hasOffer: Bool) -> String {
        guard hasOffer else { return "" }
        if canBuy { return " — or add a pack" }
        if isShared { return " — or an owner or admin adds a pack from Organization → Billing" }
        return ""
    }
}

/// The card read off the live entitlement. Observes both objects itself so it
/// appears when the entitlement resolves and follows a purchase, which a plain
/// `var` handed down through Settings would not.
struct EntitlementCreditsCard: View {
    @ObservedObject var entitlements: EntitlementService
    @ObservedObject var billing: BillingService
    var organizations: OrganizationService?

    var body: some View {
        if let ent = entitlements.entitlement, ent.integrationCreditsIncluded > 0 {
            IntegrationCreditsCard(
                used: ent.integrationCreditsUsed,
                included: ent.integrationCreditsIncluded,
                plan: ent.plan,
                isShared: ent.payer == .organization,
                isActive: ent.status == .active,
                administers: organizations?.activeMembership?.role.administers ?? false,
                renewalDate: ent.renewalDate,
                billing: billing
            )
        }
    }
}
