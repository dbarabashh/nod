import SwiftUI

/// The idle state's glyph: a collector aperture drawing loose information into a
/// lit core.
///
/// It is doing the positioning's job. A microphone says Nod records; this says
/// Nod *gathers* — the conversation, and everything around it — which is the
/// difference between a note-taker and a companion that comes back with what
/// needs doing. Shown before a capture starts, so it reads as primed rather
/// than working.
///
/// Adapted from the `agent-info-collector` illustration. Rebuilt in SwiftUI
/// rather than shipped as an asset: the artwork's whole point is the motion, and
/// AppKit renders SVG as a still frame. The core is Nod's brand blue rather than
/// the original green, so the surface keeps one accent across the meter, the
/// clock, and this.
struct NotchCollector: View {
    var size: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var breathing = false
    @State private var drawingIn = false

    /// One fragment of context on its way in. `start` is in multiples of the
    /// aperture's radius, so the whole flight scales with `size`.
    private struct Particle {
        let start: CGPoint
        let duration: Double
        let delay: Double
        let isChip: Bool
    }

    /// Staggered so they never arrive in step — four particles landing together
    /// would read as a loading spinner rather than as things being drawn in.
    private static let particles = [
        Particle(start: CGPoint(x: -1.75, y: -0.85), duration: 2.4, delay: 0, isChip: false),
        Particle(start: CGPoint(x: 1.80, y: -0.75), duration: 2.8, delay: 0.45, isChip: true),
        Particle(start: CGPoint(x: -1.55, y: 1.05), duration: 2.2, delay: 1.0, isChip: false),
        Particle(start: CGPoint(x: 1.60, y: 1.00), duration: 2.6, delay: 1.35, isChip: true)
    ]

    var body: some View {
        ZStack {
            shell
            intake
            glow
            core
            if !reduceMotion {
                ForEach(Array(Self.particles.enumerated()), id: \.offset) { _, particle in
                    self.particle(particle)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            spinning = true
            breathing = true
            drawingIn = true
        }
    }

    // MARK: - Aperture

    private var shell: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.16), Color(white: 0.09)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(Circle().stroke(Color.black.opacity(0.9), lineWidth: 1))
            .overlay(
                Circle()
                    .fill(Color(white: 0.07))
                    .frame(width: size * 0.74, height: size * 0.74)
            )
    }

    /// Two dashed rings turning against each other. Counter-rotation is what
    /// makes an aperture read as an intake rather than a progress spinner.
    private var intake: some View {
        ZStack {
            ring(dash: [7, 3.5], width: size * 0.086, opacity: 0.5, clockwise: true, period: 8)
            ring(dash: [2.5, 6.5], width: size * 0.07, opacity: 0.9, clockwise: false, period: 5)
        }
        // Cut the core out from under the rings, so the lit centre is never
        // crossed by a dash sliding over it.
        .mask(
            Circle()
                .fill(Color.white)
                .overlay(
                    Circle()
                        .frame(width: size * 0.5, height: size * 0.5)
                        .blendMode(.destinationOut)
                )
                .compositingGroup()
        )
    }

    private func ring(
        dash: [CGFloat],
        width: CGFloat,
        opacity: Double,
        clockwise: Bool,
        period: Double
    ) -> some View {
        Circle()
            .stroke(
                Color(white: 0.36).opacity(opacity),
                style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash)
            )
            .frame(width: size * 0.62, height: size * 0.62)
            .rotationEffect(.degrees(spinning ? (clockwise ? 360 : -360) : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: period).repeatForever(autoreverses: false),
                value: spinning
            )
    }

    // MARK: - Core

    private var glow: some View {
        Circle()
            .fill(Theme.Palette.brand)
            .frame(width: size * 0.79, height: size * 0.79)
            .blur(radius: size * 0.17)
            .opacity(breathing ? 0.22 : 0.08)
            .scaleEffect(breathing ? 1.0 : 0.72)
            .animation(pulse, value: breathing)
    }

    private var core: some View {
        Circle()
            .fill(coreGradient)
            .frame(width: size * 0.41, height: size * 0.41)
            .overlay(highlight)
            .scaleEffect(breathing ? 1.06 : 0.94)
            .animation(pulse, value: breathing)
    }

    private var coreGradient: RadialGradient {
        RadialGradient(
            colors: [
                Color.white.opacity(0.85),
                Theme.Palette.brand,
                DesignTokens.Palette.electricBlue
            ],
            center: .center,
            startRadius: 0,
            endRadius: size * 0.21
        )
    }

    private var highlight: some View {
        Circle()
            .fill(Color.white.opacity(0.28))
            .frame(width: size * 0.11, height: size * 0.11)
            .offset(x: -size * 0.07, y: -size * 0.07)
    }

    private var pulse: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 1.9).repeatForever(autoreverses: true)
    }

    // MARK: - Incoming information

    /// It shrinks and fades as the core takes it, so nothing ever visibly lands
    /// on top of the aperture.
    private func particle(_ particle: Particle) -> some View {
        let radius = size / 2
        let travel = drawingIn
            ? CGSize(width: 0, height: 0)
            : CGSize(width: particle.start.x * radius, height: particle.start.y * radius)

        return Group {
            if particle.isChip {
                RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                    .frame(width: size * 0.09, height: size * 0.06)
            } else {
                Circle()
                    .frame(width: size * 0.075, height: size * 0.075)
            }
        }
        .foregroundColor(Color(white: 0.48))
        .offset(travel)
        .scaleEffect(drawingIn ? 0.1 : 1)
        .opacity(drawingIn ? 0 : 0.75)
        .animation(
            .easeIn(duration: particle.duration)
                .delay(particle.delay)
                .repeatForever(autoreverses: false),
            value: drawingIn
        )
    }
}
