import Foundation

/// A folder handed to an audience.
///
/// The only thing in Nod that makes one person's session readable by another
/// without a link. Deliberately a row of its own rather than a flag on the
/// folder: sharing is an act with a date, an author and an audience, and it has
/// to be revocable as a thing rather than as a setting.
struct FolderShare: Decodable, Identifiable, Equatable {
    let id: UUID
    let labelID: UUID
    /// Exactly one of these is set — the check constraint in
    /// `20260814152612_share_folders_with_teams.sql` refuses a row that names
    /// both, because a share with two audiences silently grants the wider one.
    let teamID: UUID?
    let orgID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case labelID = "label_id"
        case teamID = "team_id"
        case orgID = "org_id"
    }
}
