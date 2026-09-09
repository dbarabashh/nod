import XCTest
@testable import Nod

final class AppDeepLinkTests: XCTestCase {
    func testParsesActivationTargets() throws {
        XCTAssertEqual(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://record")), callbackHost: "auth-callback"), .record)
        XCTAssertEqual(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://history")), callbackHost: "auth-callback"), .history)
        XCTAssertEqual(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://ask")), callbackHost: "auth-callback"), .ask)
        XCTAssertEqual(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://action-items")), callbackHost: "auth-callback"), .actionItems)
        XCTAssertEqual(
            try AppDeepLink(url: XCTUnwrap(URL(string: "nod://subscription?offer=winback")), callbackHost: "auth-callback"),
            .subscription(offer: "winback")
        )
    }

    func testParsesOrganizationInvite() throws {
        let token = UUID()
        XCTAssertEqual(
            try AppDeepLink(url: XCTUnwrap(URL(string: "nod://invite?token=\(token.uuidString)")), callbackHost: "auth-callback"),
            .invite(token: token)
        )
    }

    /// A token that isn't a UUID has nothing to redeem, so the link must not be
    /// claimed — parsing it would open the organization pane on a dead invite.
    func testRejectsInviteWithoutAUsableToken() throws {
        XCTAssertNil(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://invite?token=not-a-uuid")), callbackHost: "auth-callback"))
        XCTAssertNil(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://invite")), callbackHost: "auth-callback"))
    }

    func testRejectsUnknownTarget() throws {
        XCTAssertNil(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://unknown")), callbackHost: "auth-callback"))
    }
}
