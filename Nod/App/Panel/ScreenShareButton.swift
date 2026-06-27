import SwiftUI

/// Screen-share visibility as a single icon (no label, to stay compact like the
/// other header buttons): a monitor with an amber eye — open when Nod appears in
/// a screen share, crossed when it's hidden. Tap to flip.
struct ScreenShareButton: View {
    @EnvironmentObject private var pref: PanelSharingPreference

    var body: some View {
        let visible = pref.visibleWhenSharing
        Button(action: { pref.visibleWhenSharing.toggle() }) {
            ZStack {
                ScreenFrameShape()
                    .stroke(
                        Color.white.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                    )
                // The eye almond is drawn at a fixed centre; toggling only adds
                // the slash, so the icon never shifts between states.
                EyeShape(crossed: !visible)
                    .stroke(
                        Theme.Palette.shareEye,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
            }
            .frame(width: 16.5, height: 16.5)
            .headerGlyphCircle()
        }
        .buttonStyle(.plain)
        .panelTooltip(visible ? "Visible when sharing" : "Hidden when sharing")
    }
}

/// Maps a point in the icons' shared 24×24 artwork space into `rect`.
private func pt24(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
}

/// The monitor outline (screen + stand) behind the eye, traced from the supplied
/// 24×24 artwork so it scales crisply and tints with the other header icons.
private struct ScreenFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                origin: pt24(4, 5, in: rect),
                size: CGSize(width: 16 / 24 * rect.width, height: 12 / 24 * rect.height)
            ),
            cornerSize: CGSize(width: 2.5 / 24 * rect.width, height: 2.5 / 24 * rect.height)
        )
        path.move(to: pt24(12, 17, in: rect)); path.addLine(to: pt24(12, 20, in: rect))
        path.move(to: pt24(10, 20, in: rect)); path.addLine(to: pt24(14, 20, in: rect))
        return path
    }
}

/// The amber eye inside the monitor — an almond traced in the same 24×24 space,
/// plus a diagonal slash when `crossed` (Nod hidden from shares).
private struct EyeShape: Shape {
    var crossed: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = pt24(7, 11, in: rect)
        let right = pt24(17, 11, in: rect)
        path.move(to: left)
        path.addQuadCurve(to: right, control: pt24(12, 4.8, in: rect))
        path.addQuadCurve(to: left, control: pt24(12, 17.2, in: rect))
        if crossed {
            path.move(to: pt24(7.5, 6.5, in: rect))
            path.addLine(to: pt24(16.5, 15.5, in: rect))
        }
        return path
    }
}
