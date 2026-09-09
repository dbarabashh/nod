import Foundation

/// One action the meeting is offering to take, before any of it has been
/// written down anywhere.
///
/// Pure input to `ActionProposalStore`, which is what makes it testable: what a
/// meeting proposes is the part worth being sure about, and it is decided
/// entirely by values — the items, the roster, and who the user confirmed.
struct ProposalDraft: Equatable {
    let type: String
    var parameters: [String: String]
    let confidence: ProposalConfidence
    let actionItemID: UUID?
    let evidenceIdx: Int?

    var status: ActionProposal.Status {
        confidence.status
    }
}

/// Turning a finished meeting's to-dos into prepared work.
///
/// Deliberately conservative about what becomes a proposal at all. Every row
/// here costs the user a decision, and a review queue that is mostly noise is
/// one people stop reading — at which point approving becomes a reflex and the
/// confirmation step protects nobody.
enum ProposalDrafting {
    /// Trackers show titles in one line. Same limit `TaskDraftComposer` uses, so
    /// a task filed either way is cut the same.
    static let titleLimit = 120

    /// How far the pass that produced an item may be trusted on its own.
    ///
    /// The recap read the whole transcript with the stronger model; the live
    /// pass read a few minutes through a window and is allowed to be wrong,
    /// which is the entire reason its findings land as `proposed` rather than
    /// as tasks (`20260806164035`).
    static func semanticConfidence(for source: ActionItem.Source) -> Double {
        switch source {
        case .recap: 0.95
        case .user: 1.0
        case .live: 0.7
        }
    }

    /// - Parameters:
    ///   - owners: the name the recap attached to an item, keyed by the item's
    ///     `position`. Passed in rather than read off the item because
    ///     `action_items` deliberately has no owner column — the name lives in
    ///     the recap, and this is the one place it is used to address anybody.
    /// Where a filed task says it came from — `nil` only in tests that are
    /// about something else.
    struct Source {
        let meetingTitle: String
        let meetingDate: String
        let link: URL
    }

    static func drafts(
        for items: [ActionItem],
        owners: [Int: String],
        provider: IntegrationProvider,
        verb: ActionVerb = .task,
        directory: [Person],
        confirmedSpeakers: [MeetingSpeaker] = [],
        source: Source? = nil
    ) -> [ProposalDraft] {
        guard let action = verb.action(in: provider) else { return [] }
        let type = "\(provider.rawValue).\(action)"
        return items
            .filter(isWorthProposing)
            .sorted { $0.order < $1.order }
            .map { item in
                switch verb {
                case .task:
                    draft(
                        for: item,
                        owner: item.position.flatMap { owners[$0] },
                        type: type,
                        directory: directory,
                        confirmedSpeakers: confirmedSpeakers,
                        source: source
                    )
                case .message, .event, .note:
                    // Carries the words and who the room named, nothing more.
                    // Who it goes to, when, or which record — the person
                    // supplies on the card, which is why it lands as
                    // `needs_review` and never as ready: a message with no
                    // recipient is not a task waiting for a yes.
                    ProposalDraft(
                        type: type,
                        parameters: manualParameters(for: item, owner: item.position.flatMap { owners[$0] }),
                        confidence: ProposalConfidence(semantic: 0),
                        actionItemID: item.id,
                        evidenceIdx: item.evidenceIdx
                    )
                }
            }
    }

    static func manualParameters(for item: ActionItem, owner: String?) -> [String: String] {
        var parameters = ["title": String(item.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleLimit))]
        if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            parameters["assignee_hint"] = owner
        }
        return parameters
    }

    /// One draft for a verb the person picked by hand on the card, replacing
    /// the one the meeting offered.
    static func redraft(
        _ item: ActionItem,
        verb: ActionVerb,
        provider: IntegrationProvider,
        owner: String?,
        directory: [Person],
        source: Source?
    ) -> ProposalDraft? {
        let owners = owner.flatMap { name in item.position.map { [$0: name] } } ?? [:]
        return drafts(for: [item], owners: owners, provider: provider, verb: verb, directory: directory, source: source).first
    }

    /// A real, outstanding task that is not already somewhere else.
    ///
    /// `theirs` is included and is most of the point: a commitment somebody else
    /// made in a meeting the user ran is exactly the thing that gets lost, and
    /// it is the only kind that can carry an owner.
    private static func isWorthProposing(_ item: ActionItem) -> Bool {
        (item.kind == .action || item.kind == .theirs)
            && item.status == .confirmed
            && !item.done
            && item.deletedAt == nil
            && !item.isFiled
            && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func draft(
        for item: ActionItem,
        owner: String?,
        type: String,
        directory: [Person],
        confirmedSpeakers: [MeetingSpeaker],
        source: Source?
    ) -> ProposalDraft {
        var parameters = [
            "title": String(item.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleLimit))
        ]
        var description = ""
        if let deadline = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines), !deadline.isEmpty {
            // Verbatim, in the words it was said in. Turning "by Friday" into a
            // date needs a week-start and a timezone this has neither of, and a
            // wrong due date is worse than a quoted one.
            description = "Due: \(deadline)"
        }
        if let source {
            let footer = FiledTaskFooter.text(
                meetingTitle: source.meetingTitle,
                meetingDate: source.meetingDate,
                quote: item.evidenceQuote,
                link: source.link
            )
            description = FiledTaskFooter.appended(to: description, footer: footer)
        }
        if !description.isEmpty { parameters["description"] = description }

        var confidence = ProposalConfidence(semantic: semanticConfidence(for: item.source))
        let named = owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Only a task somebody else took on makes a claim about an owner. The
        // user's own to-do names nobody, and scoring it would invent a question.
        if item.kind == .theirs, !named.isEmpty {
            switch PersonResolver.resolve(named, in: directory, confirmedSpeakers: confirmedSpeakers) {
            case let .resolved(personID, name, value):
                parameters["assignee_person_id"] = personID.uuidString
                parameters["assignee_name"] = name
                confidence.record(.owner, value)
            case .ambiguous, .unknown:
                // The name as it was said, and no assignee. Kept because it is
                // what the person answering needs in order to answer — and
                // because inventing an owner from it is the one thing
                // `18.1 Conservative execution` forbids outright.
                parameters["assignee_hint"] = named
                confidence.record(.owner, PersonResolver.ambiguousConfidence)
            }
        }

        return ProposalDraft(
            type: type,
            parameters: parameters,
            confidence: confidence,
            actionItemID: item.id,
            evidenceIdx: item.evidenceIdx
        )
    }
}
