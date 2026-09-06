import XCTest
@testable import Nod

/// The sidebar's "Update Nod" row is only ever as true as this bookkeeping:
/// an offer is kept across launches, dropped the moment it is installed or
/// withdrawn, and never shown for the build already running.
@MainActor
final class UpdateAvailabilityTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "nod.tests.update.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private let offered = FeedBuild(version: "13.2.0", build: 71)

    func testAnOfferSurvivesARelaunch() throws {
        let store = try defaults()
        UpdaterChannelDelegate(defaults: store, runningBuild: 69).noteAvailable(offered)

        XCTAssertEqual(UpdaterChannelDelegate(defaults: store, runningBuild: 69).available, offered)
    }

    func testTheOfferIsGoneOnceItIsTheRunningBuild() throws {
        let store = try defaults()
        UpdaterChannelDelegate(defaults: store, runningBuild: 69).noteAvailable(offered)

        XCTAssertNil(UpdaterChannelDelegate(defaults: store, runningBuild: 71).available)
        XCTAssertNil(
            UpdaterChannelDelegate(defaults: store, runningBuild: 69).available,
            "a stale offer is forgotten, not kept for the next downgrade"
        )
    }

    func testAnOlderOrEqualBuildIsNotAnOffer() throws {
        let feed = try UpdaterChannelDelegate(defaults: defaults(), runningBuild: 71)
        feed.noteAvailable(offered)
        XCTAssertNil(feed.available)
        feed.noteAvailable(FeedBuild(version: "13.1.0", build: 60))
        XCTAssertNil(feed.available)
    }

    func testAWithdrawnOfferClearsTheRow() throws {
        let store = try defaults()
        let feed = UpdaterChannelDelegate(defaults: store, runningBuild: 69)
        feed.noteAvailable(offered)
        feed.noteAvailable(nil)

        XCTAssertNil(feed.available)
        XCTAssertNil(UpdaterChannelDelegate(defaults: store, runningBuild: 69).available)
    }

    func testTheChannelIsReadFromTheSameStore() throws {
        let store = try defaults()
        XCTAssertEqual(ReleaseChannel.allowed(in: store), [])
        store.set("beta", forKey: ReleaseChannel.defaultsKey)
        XCTAssertEqual(ReleaseChannel.allowed(in: store), ["beta"])
        store.set("", forKey: ReleaseChannel.defaultsKey)
        XCTAssertEqual(ReleaseChannel.allowed(in: store), [])
    }

    func testInstallGoesThroughSparklesOwnFlow() throws {
        let fired = expectation(forNotification: .nodCheckForUpdates, object: nil)
        try UpdaterChannelDelegate(defaults: defaults(), runningBuild: 69).install()
        wait(for: [fired], timeout: 1)
    }
}
