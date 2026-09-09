import SwiftUI

/// The small caps label that heads a group of rows. Every surface that needed
/// one re-typed the same three modifiers and picked its own tracking by eye —
/// 0.4, 0.6, 0.7 and 0.8 all shipped at the same 10pt bold.
///
/// The notch runs quieter than the window does, which is a real difference and
/// not drift: its cards sit over whatever the user was already looking at. That
/// is the `compact` size, and it is a choice made once here rather than
/// re-typed at each of the six places it appears. It used to run half a point
/// smaller as well; the size is now the scale's `micro` in both, and only the
/// tracking and the tint carry the difference — half-point steps were how the
/// same label came to set six different ways.
struct SectionLabel: View {
    enum Size {
        case standard
        case compact

        var tracking: CGFloat {
            switch self {
            case .standard: 0.8
            case .compact: 0.6
            }
        }

        var tint: Color {
            switch self {
            case .standard: Theme.Palette.muted
            case .compact: Theme.Palette.muted.opacity(0.7)
            }
        }
    }

    let text: String
    var size: Size = .standard
    /// A quieter second phrase on the same line — "3m ago", "17 days open".
    /// Says when or how long, never what: the label is the heading.
    var trailing: String?

    init(_ text: String, size: Size = .standard, trailing: String? = nil) {
        self.text = text
        self.size = size
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.x1) {
            Text(text.uppercased())
                .textStyle(Theme.Typography.micro)
                .tracking(size.tracking)
                .foregroundStyle(size.tint)
            if let trailing {
                Text(trailing)
                    .textStyle(Theme.Typography.micro.weight(.regular))
                    .foregroundStyle(Theme.Palette.muted.opacity(0.65))
            }
        }
    }
}
