import XCTest
@testable import Nod

@MainActor
final class FeedLatestBuildTests: XCTestCase {
    private func item(_ version: String, _ build: Int, channel: String? = nil) -> FeedBuild {
        FeedBuild(version: version, build: build, channel: channel)
    }

    /// `SUAppcast.items` is documented as feed order, not version order.
    func testTheNewestBuildWinsRegardlessOfFeedOrder() {
        let newest = UpdaterChannelDelegate.newest(
            of: [item("13.1.4", 69), item("13.2.0", 71), item("13.1.5", 70)],
            allowing: []
        )

        XCTAssertEqual(newest?.build, 71)
        XCTAssertEqual(newest?.label, "13.2.0 (71)")
    }

    /// An untagged item is on the default channel and everyone sees it; a
    /// tagged one must not be reported to an account not enrolled in it.
    func testAChannelTheAccountIsNotInIsNotItsLatest() {
        let items = [item("13.1.4", 69), item("14.0.0", 90, channel: "beta")]

        XCTAssertEqual(UpdaterChannelDelegate.newest(of: items, allowing: [])?.build, 69)
        XCTAssertEqual(UpdaterChannelDelegate.newest(of: items, allowing: ["beta"])?.build, 90)
    }

    func testAnEmptyFeedHasNoLatest() {
        XCTAssertNil(UpdaterChannelDelegate.newest(of: [], allowing: []))
    }
}
