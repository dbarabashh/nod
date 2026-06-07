import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 24) {
                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    Image("NodLogo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .shadow(color: Theme.Palette.violet.opacity(0.45), radius: 22, x: 0, y: 10)

                    Text("Welcome to Nod")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.Gradients.textBrand)
                }

                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        if auth.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.Palette.ink)
                        } else {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                        }
                        Text(auth.isSigningIn ? "Opening browser…" : "Continue with Google")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                    }
                    .frame(maxWidth: 260)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Gradients.buttonBrand)
                    )
                    .shadow(color: Theme.Palette.pink.opacity(0.35), radius: 16, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(auth.isSigningIn)

                if auth.isSigningIn {
                    Button("Cancel and retry") {
                        auth.cancelPendingSignIn()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                }

                if let error = auth.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.pink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                }

                Spacer(minLength: 0)
            }
            .padding(32)
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}
