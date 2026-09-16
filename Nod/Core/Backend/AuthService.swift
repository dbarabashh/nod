import AppKit
import AuthenticationServices
import Foundation
import Supabase

@MainActor
final class AuthService: NSObject, ObservableObject {
    // Must match `NOD_URL_SCHEME` for the configuration — the sandbox app
    // registers its own scheme so two installed builds can't both claim the
    // callback. Supabase rejects a redirect that is not on the branch's
    // allowlist, so a mismatch here fails at the provider, not at launch.
    #if NOD_SANDBOX
        static let callbackURL = URL(string: "nod-sandbox://auth-callback")!
    #elseif DEBUG
        static let callbackURL = URL(string: "nod-debug://auth-callback")!
    #else
        static let callbackURL = URL(string: "nod://auth-callback")!
    #endif

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
    private let relays = AttributionRelayStore()

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
                // Here rather than only in the callback, because the callback is
                // not the only way a session arrives. A sign-in begun before a
                // quit lands on the next launch as `.initialSession`, and that
                // is precisely the case the relay is now kept on disk for.
                if change.session?.isExpired == false {
                    await claimPendingAttribution()
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
                redirectTo: Self.callbackURL,
                queryParams: [("prompt", "select_account")]
            )
            #if DEBUG
                startAuthSession(url: url)
            #else
                let relay = AttributionRelay(id: UUID(), startedAt: Date())
                guard let startURL = attributionStartURL(oauthURL: url, relayID: relay.id),
                      NSWorkspace.shared.open(startURL) else {
                    startAuthSession(url: url)
                    return
                }
                // Written before the browser is handed the relay, not after the
                // callback comes back: everything between those two points
                // happens in another application, and this one need not survive
                // it.
                relays.store(relay)
            #endif
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
            // The session is not news, but the relay might be: a sign-in that
            // completed while the token was still good leaves the state stream
            // silent, and the campaign would go unclaimed for want of an event.
            await claimPendingAttribution()
            isSigningIn = false
            return
        }

        do {
            _ = try await client.auth.session(from: url)
            await claimPendingAttribution()
            lastError = nil
        } catch {
            Log.auth.error("session(from:) failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        isSigningIn = false
    }

    private func attributionStartURL(oauthURL: URL, relayID: UUID) -> URL? {
        var components = URLComponents(string: "https://hellonod.app/auth/start")
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "relay", value: relayID.uuidString),
            URLQueryItem(name: "oauth", value: oauthURL.absoluteString)
        ]
        components?.percentEncodedFragment = fragment.percentEncodedQuery
        return components?.url
    }

    /// Redeems the relay against the account that just signed in.
    ///
    /// Cleared only once the server has taken it, so a claim that fails on a
    /// flaky network is retried the next time a session appears rather than
    /// thrown away. Claiming twice is safe by construction: the row records the
    /// first user and refuses a different one.
    private func claimPendingAttribution() async {
        guard let relay = relays.pending() else { return }
        struct Params: Encodable { let p_relay_id: UUID }
        do {
            try await client
                .rpc("claim_acquisition_flow", params: Params(p_relay_id: relay.id))
                .execute()
            relays.clear()
            Log.auth.info("acquisition relay claimed")
        } catch {
            Log.auth.error("acquisition relay claim failed: \(error.localizedDescription)")
        }
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

    /// GDPR Right to Erasure (Art. 17). Permanently deletes the account and all
    /// associated personal data server-side, then tears the local session down.
    /// The `delete-account` Edge Function deletes the `auth.users` row, which
    /// cascades to every personal-data table (the consent audit trail is the one
    /// intentional exception — it's anonymised, not deleted). Throws if the
    /// server call fails so the UI can keep the user signed in and show the
    /// error; only signs out locally once erasure is confirmed.
    func deleteAccount() async throws {
        struct Response: Decodable { let deleted: Bool }
        let response: Response = try await client.functions.invoke("delete-account")
        guard response.deleted else {
            throw NSError(
                domain: "AuthService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Account deletion did not complete."]
            )
        }
        Log.auth.info("account deleted; clearing local session")
        await signOut()
    }
}

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeMainThread {
            NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSWindow()
        }
    }
}
