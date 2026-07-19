import SwiftUI

/// The app's own hover explainer, replacing `.help(_:)` where the tooltip is
/// part of the reading experience rather than an accessibility afterthought.
/// AppKit's tooltip is a system-yellow box with system timing and no way to
/// style it — next to a dark glass panel it reads as a foreign element.
///
/// Same glass as the undo toast, plus a tail pointing back at what it explains:
/// a card floating free next to a dense list leaves the user guessing which row
/// it belongs to. It sits above the anchor on purpose — SwiftUI draws later
/// siblings on top, so a card growing upward passes over rows that are already
/// painted, while one dropping downward slides under the next row's text.
private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let detail: String?
    let systemImage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    /// Identifies the in-flight dwell timer: every hover-exit rotates it, so a
    /// timer from a pointer that has already left can never pop the card open.
    @State private var dwellToken = UUID()

    /// Long enough that sweeping the pointer across a list stays quiet, short
    /// enough that a deliberate hover doesn't feel unresponsive.
    private static let dwell: Duration = .milliseconds(320)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if isVisible {
                    TooltipCard(text: text, detail: detail, systemImage: systemImage)
                        .fixedSize(horizontal: false, vertical: true)
                        // A zero-height slot pinned to the anchor's top edge,
                        // with the card hanging out of its bottom — the bubble
                        // lands fully above the anchor with no measuring and no
                        // state. (`alignmentGuide` is the textbook way to do
                        // this and simply doesn't lift the card here; measuring
                        // it into an offset renders nothing at all.)
                        .frame(height: 0, alignment: .bottom)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.94, anchor: .bottomLeading).combined(with: .opacity)
                        )
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                guard hovering else {
                    dwellToken = UUID()
                    withAnimation(.standard(reduceMotion: reduceMotion)) { isVisible = false }
                    return
                }
                let token = UUID()
                dwellToken = token
                Task {
                    try? await Task.sleep(for: Self.dwell)
                    guard dwellToken == token else { return }
                    withAnimation(.hoverReveal(reduceMotion: reduceMotion)) { isVisible = true }
                }
            }
    }
}

/// The bubble itself, split out from the hover plumbing so it can be rendered
/// (and eyeballed) on its own.
struct TooltipCard: View {
    let text: String
    var detail: String?
    var systemImage: String?

    static let tailHeight: CGFloat = 7
    private static let tailWidth: CGFloat = 14
    /// Puts the tail over the left end of the anchor, which is where every pill
    /// this attaches to starts.
    private static let tailInset: CGFloat = 20
    /// Wrapping width for a long hint; a short one stays as narrow as its text.
    private static let maxTextWidth: CGFloat = 230
    private static let fontSize: CGFloat = 11.5
    private static let detailFontSize: CGFloat = 10.5
    private static let fonts: [CGFloat: NSFont] = [
        fontSize: .systemFont(ofSize: fontSize, weight: .medium),
        detailFontSize: .systemFont(ofSize: detailFontSize, weight: .medium)
    ]

    /// Measured on one line and clamped, so the card hugs a short hint and wraps
    /// a long one at a readable measure. The extra point absorbs the rounding
    /// difference between this measurement and SwiftUI's own.
    private var textWidth: CGFloat {
        let widest = max(width(of: text, size: Self.fontSize), detail.map { width(of: $0, size: Self.detailFontSize) } ?? 0)
        return min(widest.rounded(.up) + 1, Self.maxTextWidth)
    }

    private func width(of string: String, size: CGFloat) -> CGFloat {
        guard let font = Self.fonts[size] else { return 0 }
        return (string as NSString).size(withAttributes: [.font: font]).width
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: Self.fontSize, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.95))
                if let detail {
                    Text(detail)
                        // Vibrancy rule: over a translucent surface a flat grey
                        // dissolves — keep the tint bright and the weight up.
                        .font(.system(size: Self.detailFontSize, weight: .medium))
                        .lineSpacing(1.5)
                        .foregroundStyle(Theme.Palette.ink.opacity(0.62))
                }
            }
            // A definite width, because the alternatives both break: an overlay
            // is proposed the anchor's size (a pill a few characters wide), and
            // `fixedSize` reports the text's *unwrapped* ideal — leaving the
            // bubble a line short of the text it wraps.
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 7 + Self.tailHeight)
        .background(bubble)
    }

    /// Takes the window's own material rather than a near-black plate: this
    /// floats a few points above the panel, and a surface that dark reads as a
    /// different app. Depth comes from the shadow and border, not from contrast.
    private var bubble: some View {
        let shape = TooltipBubble(
            cornerRadius: 9,
            tailWidth: Self.tailWidth,
            tailHeight: Self.tailHeight,
            tailInset: Self.tailInset
        )
        return shape
            .fill(.regularMaterial)
            .overlay(shape.fill(Theme.Palette.bg.opacity(0.55)))
            .overlay(shape.stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
    }
}

/// Rounded card plus a downward tail, drawn as one path so the fill, border,
/// and shadow wrap the whole bubble instead of seaming where the tail joins.
struct TooltipBubble: Shape {
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    let tailInset: CGFloat

    /// Traced as one outline rather than a rounded rect unioned with a triangle
    /// — `Path.union` is macOS 14, and the app ships to 13.
    func path(in rect: CGRect) -> Path {
        let bottom = max(rect.maxY - tailHeight, rect.minY)
        let radius = min(cornerRadius, min(rect.width, bottom - rect.minY) / 2)
        let half = tailWidth / 2
        let center = min(
            max(tailInset, rect.minX + radius + half),
            max(rect.maxX - radius - half, rect.minX + radius + half)
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: bottom),
            control: CGPoint(x: rect.maxX, y: bottom)
        )
        path.addLine(to: CGPoint(x: center + half, y: bottom))
        path.addLine(to: CGPoint(x: center + 1.5, y: rect.maxY - 1))
        path.addQuadCurve(
            to: CGPoint(x: center - 1.5, y: rect.maxY - 1),
            control: CGPoint(x: center, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: center - half, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bottom - radius),
            control: CGPoint(x: rect.minX, y: bottom)
        )
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Styled hover explainer in place of `.help(_:)` — same information, drawn
    /// in the app's material. The text is mirrored to an accessibility hint so
    /// dropping AppKit's tooltip doesn't drop it for VoiceOver.
    func hoverTooltip(_ text: String, detail: String? = nil, systemImage: String? = nil) -> some View {
        modifier(HoverTooltipModifier(text: text, detail: detail, systemImage: systemImage))
            .accessibilityHint([text, detail].compactMap { $0 }.joined(separator: ". "))
    }
}
