import SwiftUI

/// The small caps label that heads a group of rows. Every surface that needed
/// one re-typed the same three modifiers and picked its own tracking by eye —
/// 0.4, 0.6, 0.7 and 0.8 all shipped at the same 10pt bold.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.muted)
    }
}
