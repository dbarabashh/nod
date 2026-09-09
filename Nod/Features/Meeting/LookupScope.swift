import Foundation

/// Which earlier sessions "what did we say about this" should search.
///
/// The obvious answer is the project the meeting is filed under, and it is the
/// right one — when the meeting is filed. Most are not. Filing is something
/// people do afterwards if they do it at all, and a feature that only works for
/// the tidy is a feature that works for nobody on the day they need it.
///
/// So there are three levels, and the point is that the third is not a failure.
/// It is what `LiveMeetingAnalyst+Recall` already does — search everything and
/// let similarity decide — and it works because every answer names the session
/// it came from. A person who reads "from Pricing workshop, June 3" under an
/// answer can discount it themselves; one who reads an unattributed claim
/// cannot. Widening the search is safe precisely because the provenance is not
/// optional.
enum LookupScope: Equatable {
    /// Filed under one or more projects. Searches every session in them.
    case project(name: String, meetingIDs: [UUID])
    /// Not filed, but this is one instance of a repeating calendar entry, so
    /// the earlier instances are the same thread of work under another name.
    /// The project the user did not get round to creating.
    case series(title: String, meetingIDs: [UUID])
    /// Nothing says what this meeting belongs to. Search everything.
    case everything

    /// What to pass to the search. `nil` means unscoped.
    var meetingIDs: [UUID]? {
        switch self {
        case let .project(_, ids), let .series(_, ids): ids.isEmpty ? nil : ids
        case .everything: nil
        }
    }

    /// What the scope is called, for the log and for anything that wants to
    /// tell the user how wide it looked.
    var label: String? {
        switch self {
        case let .project(name, _): name
        case let .series(title, _): title
        case .everything: nil
        }
    }

    /// - Parameters:
    ///   - meetingID: the recording in progress. Always excluded from the
    ///     result — what was said ten minutes ago is this conversation, not an
    ///     earlier one, and the live pass already owns it.
    ///   - icalUID: the calendar entry behind it, when there is one.
    ///   - assignments: `LabelStore.assignments` — meeting to project ids.
    ///   - labelNames: project id to name.
    ///   - meetings: every session the user can see.
    static func of(
        meetingID: UUID?,
        icalUID: String?,
        assignments: [UUID: Set<UUID>],
        labelNames: [UUID: String],
        meetings: [Meeting]
    ) -> LookupScope {
        let live = meetings.live()
        let others = live.filter { $0.id != meetingID }

        if let meetingID, let projects = assignments[meetingID], !projects.isEmpty {
            let ids = others.filter { !(assignments[$0.id] ?? []).isDisjoint(with: projects) }.map(\.id)
            if !ids.isEmpty {
                // Named for the first project that has a name, in id order, so
                // two runs of the same meeting label it the same way.
                let name = projects.compactMap { labelNames[$0] }.min()
                return .project(name: name ?? "this project", meetingIDs: ids)
            }
        }

        // A recurring entry carries one uid across every instance, which is
        // exactly the grouping a project folder would have been.
        if let icalUID, !icalUID.isEmpty {
            let ids = others.filter { $0.icalUID == icalUID }.map(\.id)
            if !ids.isEmpty {
                let title = others.first { $0.icalUID == icalUID }?.title?.nilIfBlank
                return .series(title: title ?? "this meeting", meetingIDs: ids)
            }
        }

        return .everything
    }
}
