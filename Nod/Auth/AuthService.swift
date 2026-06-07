import AppKit
import AuthenticationServices
import Foundation
import Supabase

@MainActor
final class AuthService: NSObject, ObservableObject {
    static let callbackURL = URL(string: "nod://auth-callback")!

    @Published private(set) var session: Session?
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    /// Runs at the start of every sign-out, while the session token is still
    /// valid — so any sign-out path (menu, forced device-conflict) gets the
    /// hook, not just one call site. Used to release the single-device slot.
    /// Best-effort by contract: it must not throw or block sign-out.
    var onSignOut: (() async -> Void)?

    private let client: SupabaseClient
    private var stateTask: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?

    /// The SDK's most-recent cached session — updated by the SDK
    /// synchronously as soon as a token refreshes or sign-in lands,
    /// **before** the `authStateChanges` stream emits and updates our
    /// @Published `session`. Use this when you need the freshest value
    /// (e.g. attribution for a record about to be persisted) and don't
    /// care about SwiftUI observation.
    var currentSupabaseSession: Session? {
        client.auth.currentSession
    }

    init(client: SupabaseClient) {
        self.client = client
        let cached = client.auth.currentSession
        session = (cached?.isExpired == false) ? cached : nil
        super.init()
        let stream = client.auth.authStateChanges
        stateTask = Task { [weak self] in
            for await change in stream {
                guard let self else { break }
                await MainActor.run {
                    // With `emitLocalSessionAsInitialSession: true` the SDK
                    // can emit an expired session as `.initialSession`; a
                    // `tokenRefreshed` / `signOut` event will follow once
                    // refresh resolves. Treat expired as nil so the UI
                    // doesn't flip to signed-in with an unusable token.
                    let expired = change.session?.isExpired == true
                    self.session = expired ? nil : change.session
                    Log.auth.info("event=\(change.event) hasSession=\(change.session != nil) expired=\(expired)")
                }
            }
        }
    }

    deinit {
        stateTask?.cancel()
    }

    func signInWithGoogle() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        do {
            let url = try client.auth.getOAuthSignInURL(
                provider: .google,
                redirectTo: Self.callbackURL
            )
            startAuthSession(url: url)
        } catch {
            Log.auth.error("getOAuthSignInURL failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            isSigningIn = false
        }
    }

    private func startAuthSession(url: URL) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.callbackURL.scheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                await self?.finishAuthSession(callbackURL: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        authSession = session
        if !session.start() {
            Log.auth.error("ASWebAuthenticationSession.start() returned false")
            lastError = "Couldn't open sign-in window"
            isSigningIn = false
            authSession = nil
        }
    }

    private func finishAuthSession(callbackURL: URL?, error: Error?) async {
        authSession = nil
        if let error {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionErrorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                Log.auth.info("user cancelled sign-in window")
                isSigningIn = false
                return
            }
            Log.auth.error("ASWebAuthenticationSession failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            isSigningIn = false
            return
        }
        guard let callbackURL else {
            isSigningIn = false
            return
        }
        await handleCallback(callbackURL)
    }

    /// Reset the "signing in" state without completing OAuth.
    /// Use when the user closed the browser tab or wants to retry.
    func cancelPendingSignIn() {
        isSigningIn = false
        lastError = nil
    }

    func handleCallback(_ url: URL) async {
        guard url.scheme?.lowercased() == Self.callbackURL.scheme else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        if let errorParam = queryItems.first(where: { $0.name == "error" })?.value {
            let description = queryItems.first(where: { $0.name == "error_description" })?.value?
                .replacingOccurrences(of: "+", with: " ")
            Log.auth.error("OAuth provider error: \(errorParam) - \(description ?? "")")
            lastError = description ?? errorParam
            isSigningIn = false
            return
        }

        if client.auth.currentSession != nil {
            Log.auth.info("callback received but already signed in - ignoring")
            isSigningIn = false
            return
        }

        do {
            _ = try await client.auth.session(from: url)
            lastError = nil
        } catch {
            Log.auth.error("session(from:) failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        isSigningIn = false
    }

    func signOut() async {
        await onSignOut?()
        do {
            try await client.auth.signOut()
        } catch {
            Log.auth.error("signOut failed: \(error.localizedDescription)")
        }
    }

    /// Sign out and surface `reason` on the sign-in screen. Used when the
    /// server ends the session out from under the user — e.g. the account was
    /// claimed by another device (single-device lock).
    func forceSignOut(reason: String) async {
        await signOut()
        lastError = reason
    }
}

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSWindow()
        }
    }
}
