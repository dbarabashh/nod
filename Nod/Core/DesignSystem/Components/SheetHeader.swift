import SwiftUI

/// The top band of an app-styled sheet: what this is, one line on why, and —
/// for a sheet wide enough that Escape is not the obvious way out — a close
/// glyph. The project and beat sheets each drew it, and disagreed about the
/// subtitle's colour.
struct SheetHeader: View {
    let title: String
    let subtitle: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: onClose == nil ? 0 : 12)
            if let onClose {
                Button(action: onClose) {
                    Image("nc-xmark")
                        .icon(11)
                        .foregroundStyle(Theme.Palette.muted)
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

#Preview {
    VStack(spacing: 0) {
        SheetHeader(title: "New project", subtitle: "A project groups sessions, and scopes what Ask Nod reads.")
        Divider().overlay(Theme.Palette.border)
        SheetHeader(title: "Edit beat", subtitle: "Asked on a schedule, answered where you'll see it.", onClose: {})
    }
    .frame(width: 380)
    .background(WindowBackdrop())
}
