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
    let isPending: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            badge
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
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// An initial for somebody who is here, an outline for somebody who has only
    /// been asked — the difference is legible before the words are read.
    private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip)
        return ZStack {
            shape.fill(isPending ? .clear : Theme.Palette.surfaceStrong)
            shape.stroke(Theme.Palette.border, lineWidth: 0.5)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isPending ? Theme.Palette.muted : Theme.Palette.ink)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}
