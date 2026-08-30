import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        WelcomeBackdrop {
            VStack(spacing: 24) {
                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    Image("NodGlyphInk")
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(width: 76, height: 76)
                        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 6)

                    Text("Welcome to Nod")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.Palette.ink)
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
                            // Google's own mark, untinted — the one documented
                            // exception to the Nucleo-only rule, and the reason
                            // `ProviderMark` refuses to tint a colour asset.
                            //
                            // The G, not Gmail's M: this signs in with a Google
                            // account, which is not the same thing as an inbox
                            // and need not be a Gmail address at all.
                            //
                            // Hand-drawn into the catalogue rather than fetched:
                            // `scripts/fetch-integration-logos.sh` pulls marks
                            // for products in `IntegrationProvider`, and signing
                            // in is not an integration. The capitalised name
                            // says so — every fetched one is lowercased from a
                            // provider's raw value.
                            Image("BrandGoogle")
                                .icon(18)
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
