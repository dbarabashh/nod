import Foundation

/// The rules the "Share with" list follows as an organization grows.
///
/// A value type rather than three computed properties inside `ProjectSheet`,
/// because the whole point of these rules is what they do at a scale nobody
/// developing has: an organization with two teams exercises none of them, so
/// "it will be fine at a hundred" is a claim no screenshot can check.
/// `NodTests/ProjectAudiencesTests` runs them against a hundred.
enum ProjectAudiences {
    /// Below this a search field is chrome over nothing — most organizations
    /// have a handful of teams and they all fit without scrolling.
    static let searchThreshold = 6

    /// About six rows. The sheet must not grow with the roster: at a hundred
    /// teams the list scrolls inside this height rather than pushing Create off
    /// the bottom of the screen.
    static let listHeight: CGFloat = 152

    static func isSearchable(teamCount: Int) -> Bool {
        teamCount > searchThreshold
    }

    /// Already-shared teams first, then the rest by name.
    ///
    /// This is the answer to a hundred teams. A flat alphabetical list makes
    /// what a project is already shared with unfindable the moment it scrolls
    /// past, which is why Docusign grows a separate "Selected" tab; putting
    /// them first answers the same question in the list they were chosen from.
    static func ranked(_ teams: [Team], sharedWith shared: Set<UUID>) -> [Team] {
        teams.sorted { left, right in
            let leftShared = shared.contains(left.id)
            let rightShared = shared.contains(right.id)
            if leftShared != rightShared { return leftShared }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    /// What to draw: the teams matching `query`, in `order`.
    ///
    /// `order` is fixed when the sheet opens. Re-ranking live reads well in a
    /// screenshot and badly under a cursor — the row you just ticked jumps to
    /// the top and the one you were aiming at next slides into its place — so
    /// ordering is decided once and selection does not disturb it.
    ///
    /// A team missing from `order` sorts last rather than vanishing: one
    /// created in another window while this sheet is open is still a team you
    /// can share with.
    static func listed(_ teams: [Team], order: [UUID], query: String) -> [Team] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = trimmed.isEmpty
            ? teams
            : teams.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        return matching.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
    }
}
