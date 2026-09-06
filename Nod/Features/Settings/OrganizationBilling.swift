import SwiftUI

/// What the workspace is paying for, as returned by `org_billing_overview`.
///
/// Carries no Paddle identifiers on purpose: the portal is opened by asking the
/// server for a session, so nothing here needs a customer or subscription id and
/// a member reading this row learns none.
struct OrgBilling: Decodable {
    struct Seat: Decodable, Identifiable {
        let userID: UUID
        let name: String
        let email: String
        let role: String
        let seat: Int
        let holdsSeat: Bool

        var id: UUID {
            userID
        }

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case name, email, role, seat
            case holdsSeat = "holds_seat"
        }
    }

    let hasSubscription: Bool
    let viewerRole: String
    let plan: String?
    let status: String?
    let seats: Int?
    let billingCycle: String?
    let hoursIncluded: Double?
    let hoursUsed: Double?
    let trialEndsAt: Date?
    let renewalDate: Date?
    let members: [Seat]

    /// Only an owner or admin may open the portal — it cancels the plan every
    /// colleague is working on — and the server refuses anybody else regardless.
    var viewerAdministers: Bool {
        viewerRole == "owner" || viewerRole == "admin"
    }

    var seatsTaken: Int {
        members.count
    }

    /// People who are active in the organization but outside its seat count.
    /// They are not cut off — they fall back to whatever they hold themselves —
    /// but nobody has told them, and this is the page that can.
    var uncovered: [Seat] {
        members.filter { !$0.holdsSeat }
    }

    enum CodingKeys: String, CodingKey {
        case hasSubscription = "has_subscription"
        case viewerRole = "viewer_role"
        case plan, status, seats, members
        case billingCycle = "billing_cycle"
        case hoursIncluded = "hours_included"
        case hoursUsed = "hours_used"
        case trialEndsAt = "trial_ends_at"
        case renewalDate = "renewal_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasSubscription = try c.decodeIfPresent(Bool.self, forKey: .hasSubscription) ?? false
        viewerRole = try c.decodeIfPresent(String.self, forKey: .viewerRole) ?? "member"
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        seats = try c.decodeIfPresent(Int.self, forKey: .seats)
        billingCycle = try c.decodeIfPresent(String.self, forKey: .billingCycle)
        hoursIncluded = try c.decodeIfPresent(Double.self, forKey: .hoursIncluded)
        hoursUsed = try c.decodeIfPresent(Double.self, forKey: .hoursUsed)
        trialEndsAt = try c.decodeIfPresent(String.self, forKey: .trialEndsAt).flatMap(ServerTimestamp.date)
        renewalDate = try c.decodeIfPresent(String.self, forKey: .renewalDate).flatMap(ServerTimestamp.date)
        members = try c.decodeIfPresent([Seat].self, forKey: .members) ?? []
    }
}

/// The organization's Billing page: what it bought, how much of it is left, and
/// who it covers.
///
/// The seat table is the point. Coverage is derived from join order rather than
/// assigned, so until this page existed nobody could see who was inside the seat
/// count and who had quietly fallen out of it.
struct OrganizationBilling: View {
    @ObservedObject var service: OrganizationService
    @ObservedObject var billing: BillingService
    let membership: OrgMembership

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let overview = service.billing {
                if overview.hasSubscription {
                    planCard(overview)
                    seatsCard(overview)
                } else {
                    noPlanCard(overview)
                }
            } else {
                SettingsCard {
                    SettingsEmptyRow("Reading what this workspace is on…")
                }
            }
        }
        .task(id: membership.organization.id) {
            await service.loadBilling(in: membership.organization.id)
        }
    }

    // MARK: - The plan

    private func planCard(_ overview: OrgBilling) -> some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-credit-card",
                title: planTitle(overview),
                subtitle: planSubtitle(overview)
            ) {
                if overview.viewerAdministers {
                    Button {
                        Task { await billing.openWorkspacePortal() }
                    } label: {
                        HStack(spacing: 6) {
                            if billing.isOpeningPortal {
                                ProgressView().controlSize(.small).tint(Theme.Palette.muted)
                            }
                            Text("Manage")
                                .textStyle(Theme.Typography.secondary.weight(.semibold))
                                .foregroundStyle(Theme.GlassButton.text)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .glassButtonSurface(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(billing.isOpeningPortal)
                    .help("Invoices, card, seats and cancellation, on Paddle")
                }
            }
            SettingsRowDivider()
            SettingsRow(
                icon: "nc-hourglass",
                title: "Pooled hours",
                subtitle: poolSubtitle(overview)
            ) {
                Text(poolValue(overview))
                    .textStyle(Theme.Typography.uiEmphasis)
                    .foregroundStyle(Theme.Palette.ink)
                    .monospacedDigit()
            }
        }
    }

    private func planTitle(_ overview: OrgBilling) -> String {
        let name = (overview.plan ?? "").capitalized
        guard let seats = overview.seats else { return name }
        return "\(name) · \(seats) seat\(seats == 1 ? "" : "s")"
    }

    private func planSubtitle(_ overview: OrgBilling) -> String {
        var parts: [String] = []
        switch overview.status {
        case "trialing":
            if let ends = overview.trialEndsAt {
                parts.append("On trial until \(Self.dayFormatter.string(from: ends))")
            } else {
                parts.append("On trial")
            }
        case "past_due": parts.append("Payment needs attention")
        case "canceled": parts.append("Canceled")
        case "expired": parts.append("Expired")
        default: break
        }
        if overview.billingCycle == "yearly" { parts.append("billed yearly") }
        if overview.billingCycle == "monthly" { parts.append("billed monthly") }
        if overview.status != "trialing", let renews = overview.renewalDate {
            parts.append("renews \(Self.dayFormatter.string(from: renews))")
        }
        return parts.isEmpty ? "Paid by this workspace." : parts.joined(separator: " · ")
    }

    private func poolSubtitle(_ overview: OrgBilling) -> String {
        guard let seats = overview.seats, let included = overview.hoursIncluded, seats > 0 else {
            return "Shared across everyone this workspace covers."
        }
        let perSeat = included / Double(seats)
        return String(
            format: "%@ per seat, shared across everyone this workspace covers.",
            PaywallView.hoursText(perSeat)
        )
    }

    private func poolValue(_ overview: OrgBilling) -> String {
        guard let used = overview.hoursUsed, let included = overview.hoursIncluded else { return "—" }
        return String(format: "%.1f of %@", used, PaywallView.hoursText(included))
    }

    // MARK: - The seats

    private func seatsCard(_ overview: OrgBilling) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Seats", trailing: "\(overview.seatsTaken) active")
                .padding(.horizontal, 2)

            if !overview.uncovered.isEmpty {
                // The one thing this page exists to say out loud.
                SettingsCard {
                    SettingsRow(
                        icon: "nc-triangle-warning",
                        title: "\(overview.uncovered.count) beyond the seats you bought",
                        subtitle: "They keep working on whatever plan they hold themselves. Add seats to cover them."
                    ) {
                        EmptyView()
                    }
                }
            }

            SettingsCard {
                ForEach(Array(overview.members.enumerated()), id: \.element.id) { index, seat in
                    if index > 0 { SettingsRowDivider() }
                    PersonRow(
                        name: seat.name,
                        detail: seat.name == seat.email ? nil : seat.email,
                        isSelf: seat.userID == service.currentUserID,
                        isPending: false
                    ) {
                        StatusLabel(
                            icon: seat.holdsSeat ? "nc-check" : "nc-minus",
                            title: seat.holdsSeat ? "Covered" : "No seat",
                            tint: seat.holdsSeat ? Theme.Palette.success : Theme.Palette.muted
                        )
                    }
                }
            }
        }
    }

    private func noPlanCard(_ overview: OrgBilling) -> some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-credit-card",
                title: "This workspace has no plan",
                subtitle: overview.viewerAdministers
                    ? "Everybody here pays for themselves. Buy seats from Subscription to put them on one plan with a shared pool."
                    : "Everybody here pays for themselves. An owner or admin can put the workspace on one plan."
            ) {
                if overview.viewerAdministers {
                    Button("Open Subscription") {
                        NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                    }
                    .buttonStyle(.plain)
                    .textStyle(Theme.Typography.secondary.weight(.semibold))
                    .foregroundStyle(Theme.Palette.graphite)
                    .linkCursor()
                }
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}
