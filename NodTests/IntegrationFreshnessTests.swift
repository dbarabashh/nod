import XCTest
@testable import Nod

@MainActor
final class IntegrationFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingLoadedYetIsStale() {
        XCTAssertTrue(IntegrationService.isStale(loadedAt: nil, now: now))
    }

    func testAFreshLoadIsNotReRead() {
        let justNow = now.addingTimeInterval(-1)

        XCTAssertFalse(IntegrationService.isStale(loadedAt: justNow, now: now))
    }

    /// The case this exists for: an authorization that landed after the connect
    /// watch gave up. Once per launch meant it stayed invisible until a quit.
    func testALoadOlderThanTheWindowIsReRead() {
        let stale = now.addingTimeInterval(-IntegrationService.freshness)

        XCTAssertTrue(IntegrationService.isStale(loadedAt: stale, now: now))
        XCTAssertTrue(IntegrationService.isStale(loadedAt: now.addingTimeInterval(-3_600), now: now))
    }
}
