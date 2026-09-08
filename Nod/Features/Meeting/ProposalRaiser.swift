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
    private let memory: VerbMemory

    init(
        proposals: ActionProposalStore,
        integrations: IntegrationService,
        organizations: OrganizationService,
        meetings: MeetingStore,
        memory: VerbMemory = VerbMemory()
    ) {
        self.proposals = proposals
        self.integrations = integrations
        self.organizations = organizations
        self.meetings = meetings
        self.memory = memory
    }

    /// - Parameters:
    ///   - items: what `ActionItemStore.saveExtracted` just wrote, so the drafts
    ///     can point at real rows.
    ///   - recap: read only for the names it attached to actions. `action_items`
    ///     has no owner column on purpose, and this is the one place a name is
    ///     used to address somebody.
    func raise(from items: [ActionItem], recap: MeetingRecap, for meeting: Meeting) async {
        guard meeting.kind.extractsActionItems else { return }
        // Asked as a verb, not as a product: whether work is tracked in
        // Linear or in Jira is the company's business, and a finalize has no
        // reason to know which. One product per verb, and only the one the
        // person chose or the only one there is — filing one task into two
        // trackers makes two tickets, and picking between them is a decision
        // for the person rather than for a finalize running after they closed
        // the laptop.
        let owners = Self.owners(in: recap)
        let source = Self.source(for: meeting)
        let speakers = await meetings.speakers(forMeeting: meeting.id)
        var drafts: [ProposalDraft] = []
        for (verb, group) in Self.grouped(items, memory: memory, integrations: integrations) {
            guard let provider = integrations.preferred(for: verb) else { continue }
            drafts += ProposalDrafting.drafts(
                for: group,
                owners: owners,
                provider: provider,
                verb: verb,
                directory: organizations.people,
                confirmedSpeakers: speakers,
                source: source
            )
        }
        guard !drafts.isEmpty else { return }
        Log.ui.info(
            "proposals drafted count=\(drafts.count) ready=\(drafts.filter { $0.status == .ready }.count)"
        )
        await proposals.raise(drafts, meetingID: meeting.id, userID: meeting.userID)
    }

    /// Each item under the verb the rules pick for it; items no rule claims
    /// are left alone. Ordered by verb so a run is stable.
    static func grouped(
        _ items: [ActionItem],
        memory: VerbMemory,
        integrations: IntegrationService
    ) -> [(ActionVerb, [ActionItem])] {
        var table: [ActionVerb: [ActionItem]] = [:]
        for item in items {
            let context = integrations.verbContext(
                isTheirs: item.kind == .theirs,
                remembered: memory.remembered(for: item.kind)
            )
            guard let verb = ActionVerb.suggested(for: context) else { continue }
            table[verb, default: []].append(item)
        }
        return ActionVerb.allCases.compactMap { verb in table[verb].map { (verb, $0) } }
    }

    static func source(for meeting: Meeting) -> ProposalDrafting.Source {
        ProposalDrafting.Source(
            meetingTitle: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
            meetingDate: FiledTaskFooter.dateFormatter.string(from: meeting.startedAt),
            link: FiledTaskFooter.deepLink(meetingID: meeting.id, scheme: AuthService.callbackURL.scheme ?? "nod")
        )
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
