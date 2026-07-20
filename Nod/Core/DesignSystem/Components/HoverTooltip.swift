import SwiftUI

/// The app's own hover explainer, replacing `.help(_:)` where the tooltip is
/// part of the reading experience rather than an accessibility afterthought.
/// AppKit's tooltip is a system-yellow box with system timing and no way to
/// style it — next to a dark glass panel it reads as a foreign element.
///
/// The card is NOT drawn where it's attached. A tooltip inside a row is stuck
/// with that row's fate: a scroll view slices whatever hangs above it, and a
/// card dropping below slides under the rows painted after it. So the anchor
/// only publishes *where* it is, and the enclosing `tooltipContainer()` draws
/// the card in one overlay above all of its content — one layer, no clipping,
/// no z-order fights.
private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let detail: String?
    let systemImage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var anchor: CGRect = .zero
    /// Cancelled on hover-exit, so a timer from a pointer that has already left
    /// can't pop the card open behind it.
    @State private var dwellTask: Task<Void, Never>?
    /// Stable across redraws so the container can tell "same tooltip, moved"
    /// from "a different one".
    @State private var identity = UUID()

    /// Long enough that sweeping the pointer across a list stays quiet, short
    /// enough that a deliberate hover doesn't feel unresponsive.
    private static let dwell: Duration = .milliseconds(320)

    func body(content: Content) -> some View {
        content
            // Installed only while the card is up: every anchor in a list
            // carries this, and an always-on reader means a layout-reading
            // subtree plus a preference walk per row, forever, for a card that
            // is visible on one row at a time.
            .background {
                if isVisible {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TooltipAnchorKey.self,
                            value: TooltipRequest(
                                id: identity,
                                text: text,
                                detail: detail,
                                systemImage: systemImage,
                                anchor: geo.frame(in: .named(TooltipSpace.name))
                            )
                        )
                    }
                }
            }
            .onHover { hovering in
                dwellTask?.cancel()
                guard hovering else {
                    withAnimation(.standard(reduceMotion: reduceMotion)) { isVisible = false }
                    return
                }
                dwellTask = Task {
                    try? await Task.sleep(for: Self.dwell)
                    guard !Task.isCancelled else { return }
                    withAnimation(.hoverReveal(reduceMotion: reduceMotion)) { isVisible = true }
                }
            }
    }
}

/// What an anchor publishes: its content and where it sits in the container.
struct TooltipRequest: Equatable {
    let id: UUID
    let text: String
    let detail: String?
    let systemImage: String?
    let anchor: CGRect
}

private struct TooltipAnchorKey: PreferenceKey {
    static var defaultValue: TooltipRequest?

    /// Last one wins — only one tooltip is ever open, since a pointer is only
    /// over one thing at a time.
    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        value = nextValue() ?? value
    }
}

/// Marks the view whose bounds clip tooltips — normally the scroll view a list
/// lives in — and hosts the layer they're drawn on.
enum TooltipSpace {
    static let name = "nod.tooltip.container"
    /// Space a card needs above the anchor before it has to flip below: two
    /// lines of detail plus its chrome.
    static let neededAbove: CGFloat = 88
    /// Gap between the anchor and the card, on whichever side it lands.
    static let gap: CGFloat = 2
}

extension View {
    /// Declares this view as the boundary tooltips inside it must stay within,
    /// and draws them on top of it.
    func tooltipContainer() -> some View {
        coordinateSpace(name: TooltipSpace.name)
            .overlayPreferenceValue(TooltipAnchorKey.self) { request in
                if let request {
                    TooltipLayer(request: request)
                }
            }
            // Stops here: preferences otherwise keep travelling up, and an
            // outer container would draw a second copy of the same card at
            // coordinates that mean nothing in its own space.
            .preference(key: TooltipAnchorKey.self, value: nil)
    }

    /// Styled hover explainer in place of `.help(_:)` — same information, drawn
    /// in the app's material. The text is mirrored to an accessibility hint so
    /// dropping AppKit's tooltip doesn't drop it for VoiceOver.
    func hoverTooltip(_ text: String, detail: String? = nil, systemImage: String? = nil) -> some View {
        modifier(HoverTooltipModifier(text: text, detail: detail, systemImage: systemImage))
            .accessibilityHint([text, detail].compactMap { $0 }.joined(separator: ". "))
    }
}

/// Positions the card against its anchor: above by default, below when the top
/// of the container is too close for it to fit.
private struct TooltipLayer: View {
    let request: TooltipRequest

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var placesBelow: Bool {
        request.anchor.minY < TooltipSpace.neededAbove
    }

    var body: some View {
        TooltipCard(
            text: request.text,
            detail: request.detail,
            systemImage: request.systemImage,
            tailEdge: placesBelow ? .top : .bottom
        )
        .fixedSize(horizontal: false, vertical: true)
        // A zero-height slot at the anchor's edge, with the card hanging out of
        // it — lands the bubble fully outside the anchor without measuring it.
        .frame(height: 0, alignment: placesBelow ? .top : .bottom)
        .offset(
            x: request.anchor.minX,
            y: placesBelow ? request.anchor.maxY + TooltipSpace.gap : request.anchor.minY - TooltipSpace.gap
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .transition(
            reduceMotion
                ? .opacity
                : .scale(scale: 0.94, anchor: placesBelow ? .topLeading : .bottomLeading).combined(with: .opacity)
        )
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: request.id)
    }
}

/// The bubble itself, split out from the hover plumbing so it can be rendered
/// (and eyeballed) on its own.
struct TooltipCard: View {
    let text: String
    var detail: String?
    var systemImage: String?
    var tailEdge: VerticalEdge = .bottom

    static let tailHeight: CGFloat = 7
    private static let tailWidth: CGFloat = 14
    /// Puts the tail over the left end of the anchor, which is where every pill
    /// this attaches to starts.
    private static let tailInset: CGFloat = 20
    /// Wrapping width for a long hint; a short one stays as narrow as its text.
    private static let maxTextWidth: CGFloat = 230
    private static let fontSize: CGFloat = 11.5
    private static let detailFontSize: CGFloat = 10.5
    /// Measured on one line and clamped, so the card hugs a short hint and wraps
    /// a long one at a readable measure. The extra point absorbs the rounding
    /// difference between this measurement and SwiftUI's own.
    private var textWidth: CGFloat {
        let widest = max(width(of: text, size: Self.fontSize), detail.map { width(of: $0, size: Self.detailFontSize) } ?? 0)
        return min(widest.rounded(.up) + 1, Self.maxTextWidth)
    }

    private func width(of string: String, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
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
        .padding(.top, 7 + (tailEdge == .top ? Self.tailHeight : 0))
        .padding(.bottom, 7 + (tailEdge == .bottom ? Self.tailHeight : 0))
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
            tailInset: Self.tailInset,
            tailEdge: tailEdge
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
    /// Which side the tail leaves from — `.bottom` for a card above its anchor,
    /// `.top` for one that had to flip below it.
    var tailEdge: VerticalEdge = .bottom

    /// Traced as one outline rather than a rounded rect unioned with a triangle
    /// — `Path.union` is macOS 14, and the app ships to 13.
    func path(in rect: CGRect) -> Path {
        guard tailEdge == .bottom else {
            // Same outline, mirrored: build the downward-tail path in a flipped
            // box and flip it back, rather than tracing a second one by hand.
            let flipped = TooltipBubble(
                cornerRadius: cornerRadius,
                tailWidth: tailWidth,
                tailHeight: tailHeight,
                tailInset: tailInset
            ).path(in: rect)
            return flipped.applying(
                CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: rect.height))
            )
        }
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
