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

    func testRejectsUnknownTarget() throws {
        XCTAssertNil(try AppDeepLink(url: XCTUnwrap(URL(string: "nod://unknown")), callbackHost: "auth-callback"))
    }
}
