import SwiftUI

/// The one wide button each window step ends on.
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.GlassButton.text)
                .frame(width: 220)
                .padding(.vertical, 12)
                .glassButtonSurface(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// A wash with a hairline edge, the surface everything on the welcome sky
    /// sits on. On that ground a fill takes the overlay tint, not a material.
    func skySurface(_ shape: some InsettableShape, fill: Double = 0.14) -> some View {
        background(shape.fill(Theme.Palette.overlay.opacity(fill)))
            .overlay(shape.strokeBorder(Theme.Palette.overlay.opacity(0.28), lineWidth: 0.5))
    }
}
