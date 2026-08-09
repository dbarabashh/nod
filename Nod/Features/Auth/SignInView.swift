import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        ZStack {
            Image("WelcomeSky")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    Image("NodGlyphInk")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 6)

                    Text("Welcome to Nod")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.GlassButton.text)
                }

                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        if auth.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.GlassButton.text)
                        } else {
                            Image("nc-check")
                                .icon(18)
                                .foregroundStyle(Theme.GlassButton.text)
                        }
                        Text(auth.isSigningIn ? "Opening browser…" : "Continue with Google")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.GlassButton.text)
                    }
                    .frame(maxWidth: 260)
                    .padding(.vertical, 12)
                    .glassButtonSurface(Capsule(style: .continuous))
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
                        .foregroundStyle(Theme.Palette.danger)
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
