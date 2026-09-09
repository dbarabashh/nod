import AppKit
import SwiftUI

/// The type scale: a role per size, and the leading that goes with it.
///
/// A role carries its leading, because a `Text` with no `lineSpacing` sets at
/// whatever the face happens to carry — which is how two paragraphs at the same
/// size end up at different depths.
///
/// The face is the system one and stays that way: `display` is the slot to
/// change if Nod ever takes a brand face. See `docs/design-scale.md`.
extension Theme {
    /// A size and the leading it sets at, together — the pair is the style, and
    /// splitting them is how leading gets forgotten.
    struct TextStyle {
        let size: CGFloat
        let weight: Font.Weight
        /// The line box the design asks for. Nil where the face's own leading
        /// is what the role wants.
        let lineHeight: CGFloat?
        let font: Font
        /// What `.lineSpacing` has to add to reach `lineHeight`. SwiftUI can
        /// only add — there is no way to tighten below the face's own leading
        /// on this deployment target — so a role that asks for less than the
        /// face gives sets at the face's leading and this is zero.
        let lineSpacing: CGFloat

        /// Both derived values are resolved here, once per role, rather than on
        /// every read. `.textStyle(_:)` is applied inside `body`, so a computed
        /// `lineSpacing` measured an `NSFont` on every render of every `Text` —
        /// four hundred times the cost of reading a field, to re-derive ten
        /// constants. `Font.system` is boxed, so storing it also spares an
        /// allocation and gives SwiftUI a pointer-equal font to diff against.
        init(size: CGFloat, weight: Font.Weight, lineHeight: CGFloat? = nil) {
            self.size = size
            self.weight = weight
            self.lineHeight = lineHeight
            font = .system(size: size, weight: weight)
            lineSpacing = lineHeight.map { max(0, $0 - Self.naturalLineHeight(size: size)) } ?? 0
        }

        /// The face's own line box at this size, which is what SwiftUI lays out
        /// with before any `lineSpacing` is added.
        static func naturalLineHeight(size: CGFloat) -> CGFloat {
            let font = NSFont.systemFont(ofSize: size)
            return (font.ascender - font.descender + font.leading).rounded(.up)
        }

        /// The same role at another weight — an emphasis that keeps the size
        /// and the leading. Without it a call site that needs one word bolder
        /// reaches for `.size` and rebuilds the font by hand, which is how the
        /// leading gets dropped at the very sites the scale exists to hold.
        func weight(_ weight: Font.Weight) -> TextStyle {
            TextStyle(size: size, weight: weight, lineHeight: lineHeight)
        }

        /// How wide `text` sets in this role. The one place the app measures a
        /// string, so a layout that has to fit its own labels can ask rather
        /// than a person eyeballing it — see `SidebarFitTests`.
        func width(of text: String) -> CGFloat {
            let font = NSFont.systemFont(ofSize: size, weight: weight.appKit)
            return (text as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// The roles. Anything in the app is one of these.
    enum Typography {
        /// Onboarding and the largest modal headings. No line box declared: the
        /// source asks for 32/36 and the face's own is 38, which SwiftUI cannot
        /// tighten to on this target — declaring 36 would state an intent the
        /// code does not deliver.
        static let display = TextStyle(size: 32, weight: .semibold)
        /// The title of a page or a note.
        static let pageTitle = TextStyle(size: 24, weight: .semibold, lineHeight: 30)
        /// The heading inside a card.
        static let cardTitle = TextStyle(size: 17, weight: .semibold, lineHeight: 22)
        /// A label over a group of rows.
        static let sectionTitle = TextStyle(size: 13, weight: .semibold, lineHeight: 18)
        /// Prose: a summary, a note, a paragraph somebody reads rather than
        /// scans. The one role that is set wider than the UI it sits in.
        static let editor = TextStyle(size: 15, weight: .regular, lineHeight: 22)
        /// The default. Rows, fields, buttons, everything a person operates.
        static let ui = TextStyle(size: 13, weight: .regular, lineHeight: 18)
        /// The same size, carrying emphasis — a selected row, a button label.
        static let uiEmphasis = TextStyle(size: 13, weight: .medium, lineHeight: 18)
        /// Under a primary line: a timestamp, an address, a description.
        static let secondary = TextStyle(size: 12, weight: .regular, lineHeight: 16)
        /// Status and helper copy.
        static let meta = TextStyle(size: 11, weight: .regular, lineHeight: 14)
        /// Badges, small-caps section labels and the smallest chips. Set heavy
        /// because at this size a regular weight stops holding its own against
        /// a tinted fill.
        static let micro = TextStyle(size: 10, weight: .semibold, lineHeight: 12)
    }
}

extension View {
    /// Applies a role's size and its leading in one go, so a call site cannot
    /// take the font and forget the line height.
    func textStyle(_ style: Theme.TextStyle) -> some View {
        font(style.font).lineSpacing(style.lineSpacing)
    }
}

private extension Font.Weight {
    /// `Font.Weight` carries no numeric value AppKit accepts, and a glyph's
    /// advance does vary by weight — which is what `width(of:)` needs. Line
    /// height does not: every size in the scale measures the same box at
    /// regular, medium, semibold and bold.
    var appKit: NSFont.Weight {
        switch self {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}
