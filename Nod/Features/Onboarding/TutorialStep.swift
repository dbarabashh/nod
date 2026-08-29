import SwiftUI

struct TutorialStep: View {
    let strings: OnboardingStrings
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(strings.tutorialTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(strings.tutorialBullets.enumerated()), id: \.offset) { _, bullet in
                    BulletRow(bullet: bullet)
                }
            }

            Text(strings.tutorialPrivacy)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)

            HStack {
                Spacer()
                Button(action: onFinish) {
                    Text(strings.tutorialGotIt)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .frame(width: 180)
                        .padding(.vertical, 12)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BulletRow: View {
    let bullet: OnboardingStrings.TutorialBullet

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(bullet.icon)
                .icon(15)
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Theme.Palette.overlay.opacity(0.12))
                        .overlay(Circle().stroke(Theme.Palette.overlay.opacity(0.28), lineWidth: 0.5))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(bullet.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(bullet.body)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }
}
