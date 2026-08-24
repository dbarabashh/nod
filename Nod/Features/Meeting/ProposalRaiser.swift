import Foundation

/// Offers a finished meeting's to-dos as work, once there is somewhere to put
/// them.
///
/// Its own type rather than more of `MeetingEnrichment`, because the two answer
/// different questions and fail differently. Enrichment makes a meeting findable
/// — entities, embeddings — and is about the meeting. This is about the tools
/// the user connected, and produces nothing at all when they have connected
/// none.
@MainActor
final class ProposalRaiser {
    private let proposals: ActionProposalStore
    private let integrations: IntegrationService
    private let organizations: OrganizationService
    private let meetings: MeetingStore

    init(
        proposals: ActionProposalStore,
        integrations: IntegrationService,
        organizations: OrganizationService,
        meetings: MeetingStore
    ) {
        self.proposals = proposals
        self.integrations = integrations
        self.organizations = organizations
        self.meetings = meetings
    }

    /// - Parameters:
    ///   - items: what `ActionItemStore.saveExtracted` just wrote, so the drafts
    ///     can point at real rows.
    ///   - recap: read only for the names it attached to actions. `action_items`
    ///     has no owner column on purpose, and this is the one place a name is
    ///     used to address somebody.
    func raise(from items: [ActionItem], recap: MeetingRecap, for meeting: Meeting) async {
        // Asked as a capability, not as a product: whether work is tracked in
        // Linear or in Jira is the company's business, and a finalize has no
        // reason to know which.
        //
        // The first one, not all of them. Filing one task into two trackers
        // makes two tickets for one piece of work, and choosing between them is
        // a decision for the person rather than for a finalize running after
        // they closed the laptop.
        guard let provider = integrations.taskTargets.first else { return }
        guard meeting.kind.extractsActionItems else { return }

        let drafts = await ProposalDrafting.drafts(
            for: items,
            owners: Self.owners(in: recap),
            provider: provider,
            directory: organizations.people,
            confirmedSpeakers: meetings.speakers(forMeeting: meeting.id)
        )
        guard !drafts.isEmpty else { return }
        Log.ui.info(
            "proposals drafted count=\(drafts.count) ready=\(drafts.filter { $0.status == .ready }.count) provider=\(provider.rawValue)"
        )
        await proposals.raise(drafts, meetingID: meeting.id, userID: meeting.userID)
    }

    /// The name the recap attached to each action, by the action's position —
    /// which is the `position` `saveExtracted` writes onto the row it creates
    /// from it, and therefore how the two are matched up again here.
    private static func owners(in recap: MeetingRecap) -> [Int: String] {
        recap.actionItems.enumerated().reduce(into: [Int: String]()) { table, pair in
            guard pair.element.isSomeoneElses, let owner = pair.element.owner else { return }
            table[pair.offset] = owner
        }
    }
}
