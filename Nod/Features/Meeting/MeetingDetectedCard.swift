import AppKit
import SwiftUI

/// "Zoom meeting detected — record it?", in the top-right corner.
///
/// It offers exactly one action and two ways to say no. A detector that reads
/// the room wrong is only tolerable if declining is as cheap as accepting, and
/// if the second decline is permanent.
struct MeetingDetectedCard: View {
    let app: ConferencingApp
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onMute: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringClose = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text("\(app.displayName) call detected")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Record it and Nod will transcribe and summarise it.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .padding(.top, 9)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: MeetingDetectedCard.width, alignment: .topLeading)
        // `PanelMaterial.card`, not the pill form the capture panel uses:
        // `clipShape` does not clip the AppKit effect view underneath, so a pill
        // material in a window with padding around it leaves square blurred
        // corners spilling into the shadow margin.
        .background(PanelMaterial.card(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.Palette.border, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 5)
        // Room for the shadow to fall inside the window on every side. The
        // panel draws no window shadow of its own (the capture panel is a set
        // of separate pills, where one would halo each), so this one is the
        // card's own and has to be given somewhere to land.
        .padding(Self.shadowInset)
        // Fixed width, free height: the window is hosted with
        // `.preferredContentSize`, so whatever this lays out to is the window.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The app's own icon, so the card is recognisable before it is read. Falls
    /// back to a glyph for an app macOS can't resolve a bundle for.
    @ViewBuilder
    private var icon: some View {
        if let image = AppDirectory.icon(for: AppDirectory.identity(forBundleID: app.rawValue)) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 26, height: 26)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onStart) {
                Text("Start recording")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .linkCursor()

            Button(action: onMute) {
                Text("Never for \(app.displayName)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .buttonStyle(.plain)
            .linkCursor()
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Palette.muted.opacity(isHoveringClose ? 1 : 0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Not now")
        .onHover { isHoveringClose = $0 }
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: isHoveringClose)
    }

    /// Matches the panel's compact width so the two read as one product when
    /// the card hands off to it.
    static let width: CGFloat = PanelWidth.compact
    static let shadowInset: CGFloat = 18
    static let windowWidth = width + shadowInset * 2
    /// Placeholder height only: the hosting controller replaces it with what the
    /// content lays out to, which depends on how the subtitle wraps at the
    /// user's text size.
    static let initialWindowSize = NSSize(width: windowWidth, height: 150)
}

#Preview {
    MeetingDetectedCard(app: .zoom, onStart: {}, onDismiss: {}, onMute: {})
        .frame(width: MeetingDetectedCard.windowWidth)
        .background(Color.black)
}
