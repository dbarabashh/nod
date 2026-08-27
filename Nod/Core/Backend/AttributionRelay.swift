import Foundation

/// The sign-in relay, kept where a quit cannot lose it.
///
/// Signing in leaves the app: the default browser opens `hellonod.app/auth/start`,
/// which ties the browser's visitor to this relay, and only then goes to Google.
/// Between those two moments the person picks an account, types a password and
/// answers a second factor — minutes, in another application, with this one in
/// the background where macOS may well never bring it forward again by itself.
///
/// Held in memory, the relay died with the process, and the campaign that
/// brought somebody here died with it. Four of the fourteen relays ever minted
/// expired unclaimed that way: people who had already agreed to be counted, and
/// were not.
///
/// Pure and value-typed so the one rule that matters — a relay is only good for
/// as long as the row behind it — is stated once and can be tested without a
/// browser, a network or a clock.
struct AttributionRelay: Equatable {
    let id: UUID
    let startedAt: Date

    /// Matches `acquisition_auth_flows.expires_at`, which the server sets to 24
    /// hours. A relay past that is refused there, so offering it again would
    /// only spend a round trip to be told so.
    ///
    /// The expiry is what makes persistence safe. Without it a relay left over
    /// from an abandoned sign-in would attach the next person who signs in on
    /// this Mac to the first one's campaign — a wrong answer, which is worse
    /// than the missing one it replaced.
    static let lifetime: TimeInterval = 24 * 60 * 60

    func isLive(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(startedAt)
        // Negative age is a clock that moved backwards, not a relay from the
        // future: treat it as live rather than silently dropping a good one.
        return age < Self.lifetime
    }
}

/// Where the relay waits for the browser to come back.
///
/// `UserDefaults` rather than the keychain: a relay is a random id with a
/// day to live and no bearing on what anybody can read — the claim it enables
/// is authorised by the session, not by holding this.
struct AttributionRelayStore {
    private let defaults: UserDefaults
    private static let idKey = "auth.attributionRelay.id"
    private static let startedAtKey = "auth.attributionRelay.startedAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The relay a sign-in is still waiting on, or nil.
    ///
    /// Clears an expired one on the way past, so a Mac that abandoned a sign-in
    /// last week does not keep a dead key around forever.
    func pending(now: Date = Date()) -> AttributionRelay? {
        guard let raw = defaults.string(forKey: Self.idKey),
              let id = UUID(uuidString: raw)
        else { return nil }
        let startedAt = Date(timeIntervalSince1970: defaults.double(forKey: Self.startedAtKey))
        let relay = AttributionRelay(id: id, startedAt: startedAt)
        guard relay.isLive(at: now) else {
            clear()
            return nil
        }
        return relay
    }

    func store(_ relay: AttributionRelay) {
        defaults.set(relay.id.uuidString, forKey: Self.idKey)
        defaults.set(relay.startedAt.timeIntervalSince1970, forKey: Self.startedAtKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.startedAtKey)
    }
}
