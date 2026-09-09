import SwiftUI

/// Where a meeting's to-dos could go, offered once under the checklist of
/// somebody who has connected no tracker.
///
/// The filing button draws nothing for that person on purpose — a mark for a
/// product they have not set up is an advert on every row. This is the one
/// place the offer is made instead: one line, under the list it is about, and
/// gone for good once it is declined or answered. The same shape as
/// `ConnectToolsRow` on the home screen.
struct TrackerConnectRow: View {
    let meetingID: UUID

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var actionItems: ActionItemStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @AppStorage(TrackerConnectRow.dismissedKey) private var isDismissed = false

    static let dismissedKey = "actionItems.trackerOfferDismissed"

    /// Trackers only, in declaration order, and only where a real mark ships —
    /// a chip wearing the stand-in glyph teaches nobody that Jira is reachable.
    static func offered(
        blocked: Set<IntegrationProvider>,
        ships: Set<IntegrationProvider> = ProviderMark.ships
    ) -> [IntegrationProvider] {
        IntegrationProvider.allCases.filter {
            $0.taskActions != nil && ships.contains($0) && !blocked.contains($0)
        }
    }

    /// The two questions this row can ask. Nothing connected is the first;
    /// two trackers and no pick is the second, and it is the one that
    /// otherwise fails silently — `ProposalRaiser` drafts nothing until it
    /// is answered, and nothing else on this screen says so.
    private enum Ask {
        case connect([IntegrationProvider])
        case choose([IntegrationProvider])
    }

    /// All of these at once, or nothing: a session that is not the user's, has
    /// nothing open, or a settled tracker has no use for either question.
    private var ask: Ask? {
        guard integrations.hasLoaded,
              entitlements.mayUse(.actionItems),
              let meeting = meetingStore.byID[meetingID],
              !meetingStore.isSharedWithMe(meeting),
              meeting.kind.extractsActionItems,
              actionItems.items(forMeeting: meetingID).contains(where: \.isOpen)
        else { return nil }
        if integrations.taskTargets.isEmpty {
            let offered = Self.offered(blocked: integrations.blockedByOrganization)
            return isDismissed || offered.isEmpty ? nil : .connect(offered)
        }
        if integrations.taskTargets.count > 1, integrations.preferredTaskTarget == nil {
            return .choose(integrations.taskTargets)
        }
        return nil
    }

    var body: some View {
        switch ask {
        case nil:
            EmptyView()
        case let .connect(offered):
            question(
                "Send these to your tracker",
                detail: "Nod drafts the ticket from what was said. You approve before anything is filed.",
                chips: offered,
                onPick: { _ in settingsFocus.open(.integrations) },
                help: { "Connect \($0.displayName) — Nod can then file this session's tasks there" }
            ) {
                Button("Not now") { isDismissed = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
            }
        case let .choose(targets):
            question(
                "Which tracker should these go to?",
                detail: "Nod will draft tasks there when your next session ends. For this one, use each row's Send to menu. You can change it in Settings.",
                chips: targets,
                onPick: { integrations.setDefaultTaskTarget($0) },
                help: { "File tasks in \($0.displayName) by default" }
            ) {
                EmptyView()
            }
        }
    }

    private func question(
        _ title: String,
        detail: String,
        chips: [IntegrationProvider],
        onPick: @escaping (IntegrationProvider) -> Void,
        help: @escaping (IntegrationProvider) -> String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { provider in
                    ChatSuggestionChip(text: provider.displayName, provider: provider) { onPick(provider) }
                        .help(help(provider))
                }
                trailing()
            }
        }
        .padding(.top, 14)
    }
}
