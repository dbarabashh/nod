import XCTest
@testable import Nod

/// Pins the one property the logo fix rests on: replacing the picture has to
/// change the path.
///
/// The old name was a fixed `logo.png`, so a replacement kept its URL and every
/// viewer's `URLSession` cache — and the CDN in front of it — went on serving
/// the picture that had just been replaced. No amount of re-reading the row
/// could fix that, because the row still said the same thing.
final class OrganizationLogoPathTests: XCTestCase {
    private let org = UUID(uuidString: "7942993c-93a4-435c-9d2b-f66288fc6ac7") ?? UUID()

    func testDifferentPicturesGetDifferentPaths() {
        let first = OrganizationService.logoPath(for: org, content: Data([0x01, 0x02, 0x03]))
        let second = OrganizationService.logoPath(for: org, content: Data([0x01, 0x02, 0x04]))
        XCTAssertNotEqual(first, second)
    }

    func testTheSamePictureGetsTheSamePath() {
        let content = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(
            OrganizationService.logoPath(for: org, content: content),
            OrganizationService.logoPath(for: org, content: content)
        )
    }

    /// The bucket's policies authorize on the first path segment alone
    /// (`20260818223500`), so an upload lands nowhere it is allowed if the id
    /// stops being the folder.
    func testTheOrganizationIDIsTheFolder() {
        let path = OrganizationService.logoPath(for: org, content: Data([0x00]))
        XCTAssertTrue(path.hasPrefix("\(org.uuidString.lowercased())/"))
        XCTAssertTrue(path.hasSuffix(".png"))
    }

    func testTwoOrganizationsNeverShareAPath() {
        let content = Data([0x00, 0x01])
        XCTAssertNotEqual(
            OrganizationService.logoPath(for: org, content: content),
            OrganizationService.logoPath(for: UUID(), content: content)
        )
    }
}
