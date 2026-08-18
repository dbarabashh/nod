import SwiftUI

/// One person in the organization — a member, or an address that has been
/// invited and hasn't answered yet.
///
/// Both states share a row because they are the same question to an
/// administrator: who is in this organization. Keeping invites in a strip of
/// their own made the roster read as complete when it wasn't, which is exactly
/// the moment somebody re-invites a person who already has a live invite.
struct PersonRow<Trailing: View>: View {
    let name: String
    let detail: String?
    /// When they joined, and whether this is the viewer. Two facts rather than
    /// one formatted string, so the row decides how each reads instead of every
    /// caller agreeing on a date format and on the word for "you".
    var joined: Date?
    var isSelf = false
    /// Set by a caller laying rows out as a table, so the dates line up down the
    /// list; `nil` sizes the column to its own content.
    var metaWidth: CGFloat?
    let isPending: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            OrgMonogram(name: name, size: 26, isMuted: isPending)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isPending ? Theme.Palette.muted : Theme.Palette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 8)
            if let meta {
                Text(meta)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
                    .frame(width: metaWidth, alignment: .leading)
            }
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// An em dash rather than nothing for somebody with no join date, but only
    /// inside a table — a ragged column is harder to read than a placeholder,
    /// and outside one there is no column to keep straight.
    private var meta: String? {
        if isSelf { return "You" }
        if let joined { return joinedFormatter.string(from: joined) }
        return metaWidth == nil ? nil : "—"
    }
}

/// Built once. `DateFormatter` construction dwarfs the formatting itself, and
/// this runs per roster row on every pass of the enclosing body. A file-scope
/// constant because `PersonRow` is generic, and a generic type cannot hold one.
private let joinedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    return formatter
}()
