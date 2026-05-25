import Foundation
import AppKit
import Supabase

@MainActor
final class AuthService: ObservableObject {
    static let callbackURL = URL(string: "nod://auth-callback")!

    @Published private(set) var session: Session?
    @Published private(set) var isSigningIn = false
    @Published var lastError: String?

    private let client: SupabaseClient
    private var stateTask: Task<Void, Never>?

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
        self.session = (cached?.isExpired == false) ? cached : nil
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
            NSWorkspace.shared.open(url)
        } catch {
            Log.auth.error("getOAuthSignInURL failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            isSigningIn = false
        }
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
        do {
            try await client.auth.signOut()
        } catch {
            Log.auth.error("signOut failed: \(error.localizedDescription)")
        }
    }
}
