import XCTest
@testable import Nod

/// Adoption of connected products is a number decisions get made on, so it has
/// to move in both directions. Diffed against the previous in-memory value it
/// could only ever rise: a grant revoked at Slack or Google rather than in Nod
/// simply stopped appearing, and one that landed while the app was closed was
/// absorbed into the next launch's baseline and never counted at all.
final class IntegrationLinkChangeTests: XCTestCase {
    func testANewProductIsReportedConnected() {
        let change = IntegrationService.linkChanges(known: ["slack"], current: ["slack", "linear"])

        XCTAssertEqual(change.connected, ["linear"])
        XCTAssertTrue(change.revoked.isEmpty)
    }

    /// The half that used to be invisible: nothing in Nod was clicked, the grant
    /// just stopped existing.
    func testAGrantRevokedElsewhereIsStillReported() {
        let change = IntegrationService.linkChanges(known: ["slack", "linear"], current: ["linear"])

        XCTAssertEqual(change.revoked, ["slack"])
        XCTAssertTrue(change.connected.isEmpty)
    }

    func testBothDirectionsInOneReconcile() {
        let change = IntegrationService.linkChanges(known: ["slack"], current: ["linear", "jira"])

        XCTAssertEqual(change.connected, ["jira", "linear"])
        XCTAssertEqual(change.revoked, ["slack"])
    }

    /// A reconcile that changed nothing must say nothing — this runs on a timer
    /// beside every refresh.
    func testAnUnchangedSetIsSilent() {
        let change = IntegrationService.linkChanges(known: ["slack", "linear"], current: ["linear", "slack"])

        XCTAssertTrue(change.connected.isEmpty)
        XCTAssertTrue(change.revoked.isEmpty)
    }
}
