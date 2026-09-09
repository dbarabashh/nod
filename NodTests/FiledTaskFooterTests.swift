import XCTest
@testable import Nod

final class FiledTaskFooterTests: XCTestCase {
    private let meetingID = UUID(uuidString: "0B1F2C3D-4E5F-4A6B-8C7D-9E8F7A6B5C4D")!

    func testTheDeepLinkOpensTheMeetingInNod() {
        let url = FiledTaskFooter.deepLink(meetingID: meetingID, scheme: "nod")
        XCTAssertEqual(url.absoluteString, "nod://meeting?id=\(meetingID.uuidString)")
        XCTAssertEqual(AppDeepLink(url: url, callbackHost: "auth-callback"), .meeting(id: meetingID))
    }

    func testAMeetingLinkWithoutAnIDIsNotOurs() throws {
        let url = try XCTUnwrap(URL(string: "nod://meeting?id=not-a-uuid"))
        XCTAssertNil(AppDeepLink(url: url, callbackHost: "auth-callback"))
    }

    func testTheFooterNamesTheSessionQuotesTheWordsAndLinksBack() {
        let link = FiledTaskFooter.deepLink(meetingID: meetingID, scheme: "nod")
        let footer = FiledTaskFooter.text(
            meetingTitle: "Weekly sync",
            meetingDate: "8 Sep 2026",
            quote: "we need the pricing copy before Thursday",
            link: link
        )
        XCTAssertEqual(
            footer,
            """
            —
            From “Weekly sync” (8 Sep 2026), via Nod
            > we need the pricing copy before Thursday
            \(link.absoluteString)
            """
        )
    }

    func testALongQuoteIsCutAndAMissingOneIsSkipped() {
        let link = FiledTaskFooter.deepLink(meetingID: meetingID, scheme: "nod")
        let long = String(repeating: "a", count: FiledTaskFooter.quoteLimit + 40)
        let cut = FiledTaskFooter.text(meetingTitle: "S", meetingDate: "d", quote: long, link: link)
        XCTAssertTrue(cut.contains("> " + String(repeating: "a", count: FiledTaskFooter.quoteLimit) + "…"))
        let none = FiledTaskFooter.text(meetingTitle: "S", meetingDate: "d", quote: "  ", link: link)
        XCTAssertFalse(none.contains(">"))
    }

    func testTheFooterFollowsTheDescriptionOrStandsAlone() {
        XCTAssertEqual(FiledTaskFooter.appended(to: "Due: Friday", footer: "—\nvia Nod"), "Due: Friday\n\n—\nvia Nod")
        XCTAssertEqual(FiledTaskFooter.appended(to: "  ", footer: "—\nvia Nod"), "—\nvia Nod")
    }

    func testADraftedProposalCarriesTheFooter() {
        let item = ActionItem.new(
            meetingID: meetingID,
            userID: UUID(),
            text: "Write the pricing copy",
            deadline: "by Thursday",
            position: 0,
            evidenceQuote: "we need the pricing copy before Thursday"
        )
        let source = ProposalDrafting.Source(
            meetingTitle: "Weekly sync",
            meetingDate: "8 Sep 2026",
            link: FiledTaskFooter.deepLink(meetingID: meetingID, scheme: "nod")
        )
        let drafts = ProposalDrafting.drafts(for: [item], owners: [:], provider: .linear, directory: [], source: source)
        let description = drafts[0].parameters["description"] ?? ""
        XCTAssertTrue(description.hasPrefix("Due: by Thursday\n\n—\nFrom “Weekly sync”"))
        XCTAssertTrue(description.contains("> we need the pricing copy before Thursday"))
        XCTAssertTrue(description.hasSuffix("nod://meeting?id=\(meetingID.uuidString)"))
    }
}
