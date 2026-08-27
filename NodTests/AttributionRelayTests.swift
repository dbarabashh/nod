import XCTest
@testable import Nod

/// Keeping the relay across a quit is only safe because it expires. These pin
/// the expiry, because without it a relay left over from an abandoned sign-in
/// would attribute the next person who signs in on this Mac to the first one's
/// campaign — a wrong answer, which is worse than the missing one it replaced.
final class AttributionRelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_773_380)

    private func store() throws -> (AttributionRelayStore, UserDefaults) {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "relay-tests-\(UUID().uuidString)"))
        return (AttributionRelayStore(defaults: suite), suite)
    }

    func testARelayIsLiveForAsLongAsTheRowBehindIt() {
        let relay = AttributionRelay(id: UUID(), startedAt: now)

        XCTAssertTrue(relay.isLive(at: now.addingTimeInterval(AttributionRelay.lifetime - 1)))
        XCTAssertFalse(relay.isLive(at: now.addingTimeInterval(AttributionRelay.lifetime)))
    }

    /// Matches `acquisition_auth_flows.expires_at`. Offering an older one only
    /// spends a round trip to be refused.
    func testTheLifetimeMatchesTheServersDay() {
        XCTAssertEqual(AttributionRelay.lifetime, 24 * 60 * 60)
    }

    /// A clock that moved backwards is not a relay from the future, and
    /// dropping a good one over it would lose exactly what this exists to keep.
    func testAClockThatWentBackwardsDoesNotKillAGoodRelay() {
        let relay = AttributionRelay(id: UUID(), startedAt: now)

        XCTAssertTrue(relay.isLive(at: now.addingTimeInterval(-600)))
    }

    /// The case this whole change is for: the browser took minutes, the app was
    /// quit, and the campaign has to still be there on the next launch.
    func testARelaySurvivesTheProcessThatMintedIt() throws {
        let (relays, defaults) = try store()
        let relay = AttributionRelay(id: UUID(), startedAt: now)
        relays.store(relay)

        let reread = AttributionRelayStore(defaults: defaults).pending(now: now.addingTimeInterval(600))

        XCTAssertEqual(reread?.id, relay.id)
    }

    func testAnExpiredRelayIsNeitherReturnedNorKept() throws {
        let (relays, defaults) = try store()
        relays.store(AttributionRelay(id: UUID(), startedAt: now))

        let stale = now.addingTimeInterval(AttributionRelay.lifetime + 1)
        XCTAssertNil(relays.pending(now: stale))
        // Read once, gone: a Mac that abandoned a sign-in last week does not
        // keep a dead key for the rest of the install's life.
        XCTAssertNil(defaults.string(forKey: "auth.attributionRelay.id"))
    }

    func testNothingPendingWhenNoSignInIsInFlight() throws {
        let (relays, _) = try store()

        XCTAssertNil(relays.pending(now: now))
    }

    /// Cleared only on a claim the server took. A failed claim keeps the relay
    /// so the next session retries it.
    func testClearingRemovesBothHalves() throws {
        let (relays, defaults) = try store()
        relays.store(AttributionRelay(id: UUID(), startedAt: now))
        relays.clear()

        XCTAssertNil(relays.pending(now: now))
        XCTAssertEqual(defaults.double(forKey: "auth.attributionRelay.startedAt"), 0)
    }

    /// A second sign-in started before the first was claimed replaces it: the
    /// browser is now carrying the newer relay, and the older one names a flow
    /// nobody will complete.
    func testStartingAgainReplacesTheRelayInFlight() throws {
        let (relays, _) = try store()
        let first = AttributionRelay(id: UUID(), startedAt: now)
        let second = AttributionRelay(id: UUID(), startedAt: now.addingTimeInterval(60))
        relays.store(first)
        relays.store(second)

        XCTAssertEqual(relays.pending(now: now.addingTimeInterval(120))?.id, second.id)
    }
}
