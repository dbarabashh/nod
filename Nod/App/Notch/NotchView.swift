import SwiftUI

/// The notch surface itself: one silhouette that morphs between states.
///
/// Everything is laid out from the top edge down, because the surface hangs off
/// the menu bar. The window around it never moves or resizes (see `NotchPanel`),
/// so every size change here is a spring on a SwiftUI frame.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The state the surface is animating away from, so the morph can pick a
    /// spring that suits the direction — arriving and leaving are not the same
    /// gesture. Updated after the animation is committed, in the same pass.
    @State private var previous: NotchPresentation = .dormant

    var body: some View {
        VStack(spacing: 0) {
            surface
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            NotchAnimation.morph(from: previous, to: presentation, reduceMotion: reduceMotion),
            value: presentation
        )
        .animation(NotchAnimation.converting, value: geometry)
        .onChange(of: presentation) { previous = $0 }
    }

    private var presentation: NotchPresentation {
        model.presentation
    }

    private var geometry: NotchGeometry {
        model.geometry
    }

    private var surface: some View {
        // Resolved once per body pass. Read straight from the computed property,
        // each of the three modifiers below would box a fresh `AnyShape` and
        // re-run `path(in:)` — three times per frame for the whole of a morph.
        let shape = shape

        return NotchStateContent(model: model)
            // Opened states lock their natural height, so a surface animating
            // shut does not re-lay them out at every intermediate size — that
            // relayout is what makes a closing card look like it is being
            // squashed, text and buttons crushing together on the way down.
            // Fixed, the content holds its shape and the mask closes over it.
            //
            // A resting state must not: its height is the hardware cut-out's,
            // and content pinned to its own ideal height would sit against the
            // top edge of a taller surface instead of centred in it.
            .fixedSize(horizontal: false, vertical: presentation.isOpen)
            .frame(
                width: presentation.surfaceWidth(in: geometry),
                height: presentation.surfaceHeight(in: geometry),
                // Opened: anchored to the edge the surface hangs from, so the
                // mask eats the content from the bottom up rather than closing
                // in from both edges like a shutter. At rest: centred in the
                // cut-out, which is the only thing that looks right there.
                alignment: presentation.isOpen ? .top : .center
            )
            // Black *behind* the content and the whole thing masked by the
            // silhouette, rather than the shape filled behind it: an opening
            // spring overshoots its final size, and a fill sized to the frame
            // leaves a lit sliver at the edge for those frames. The margin has
            // to cover that overshoot and no more — it is composited every frame
            // the content invalidates, so a generous one is paid for continuously.
            .background(Color.black.padding(-40))
            .mask(shape)
            // The shadow goes on the silhouette, behind everything, rather than
            // on the finished surface: applied on top, its source layer is the
            // live content, and a 22pt gaussian would be recomputed every time
            // the level meter moves. Here it rasterizes once per morph.
            .background(shadow(shape))
            .overlay(edge(shape))
            .contentShape(shape)
            .onTapGesture(perform: model.toggleOpen)
            .allowsHitTesting(isInteractive)
    }

    private var shape: AnyShape {
        geometry.surfaceShape(bottomRadius: presentation.bottomRadius(in: geometry))
    }

    /// Whether the surface takes clicks at all — the single rule, rather than
    /// one predicate here and a second guard inside the tap handler.
    ///
    /// Exactly one case is excluded: dormant on a screen with no cut-out, where
    /// the surface is drawing nothing and would be an invisible click target at
    /// the top centre of the screen, swallowing clicks meant for whatever is
    /// behind it. Anywhere else it is either showing something or covering dead
    /// hardware, and a click costs the user nothing.
    private var isInteractive: Bool {
        presentation != .dormant || geometry.hasCutout
    }

    private func shadow(_ shape: AnyShape) -> some View {
        shape
            .fill(Color.black)
            .shadow(color: .black.opacity(presentation.isOpen ? 0.45 : 0), radius: 22, x: 0, y: 10)
    }

    /// A hairline that only exists when the surface is opened — it is what
    /// separates a card from the black bezel above it. At rest there is nothing
    /// to separate, and an outline around the cut-out would give the illusion
    /// away instantly.
    private func edge(_ shape: AnyShape) -> some View {
        shape.stroke(
            Theme.Palette.border.opacity(presentation.isOpen ? 1 : 0),
            lineWidth: 0.5
        )
    }
}
