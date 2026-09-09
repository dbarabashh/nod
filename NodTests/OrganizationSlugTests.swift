import XCTest
@testable import Nod

/// Pins `Organization.slug(from:)` to the check constraint in
/// `20260814111629_organizations_schema.sql`. The database is the one that
/// rejects a bad slug, and it does so with an error nobody can act on — so the
/// invariant worth testing is not "looks reasonable" but "the constraint would
/// accept it", asserted for every case below.
final class OrganizationSlugTests: XCTestCase {
    private let constraint = try? NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$")

    private func assertAccepted(_ slug: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let constraint else { return XCTFail("regex failed to compile", file: file, line: line) }
        let range = NSRange(slug.startIndex..., in: slug)
        XCTAssertNotNil(
            constraint.firstMatch(in: slug, range: range),
            "\(slug) would be rejected by organizations_slug_check",
            file: file,
            line: line
        )
    }

    func testLowercasesAndHyphenates() {
        XCTAssertEqual(Organization.slug(from: "Acme"), "acme")
        XCTAssertEqual(Organization.slug(from: "Acme Corp"), "acme-corp")
        XCTAssertEqual(Organization.slug(from: "  Acme   Corp  "), "acme-corp")
        XCTAssertEqual(Organization.slug(from: "Acme, Inc."), "acme-inc")
    }

    func testCollapsesRunsAndTrimsEdges() {
        XCTAssertEqual(Organization.slug(from: "--Acme--Corp--"), "acme-corp")
        assertAccepted(Organization.slug(from: "--Acme--Corp--"))
    }

    /// A name that carries no ASCII survives as a usable slug rather than an
    /// empty string — the person named their company in their own alphabet, and
    /// that is not an error to show them.
    func testNonASCIINameFallsBackToAGeneratedSlug() {
        let slug = Organization.slug(from: "Приклад")
        XCTAssertTrue(slug.hasPrefix("org-"))
        assertAccepted(slug)
    }

    func testTooShortFallsBack() {
        for name in ["A", "ab", "-", " "] {
            let slug = Organization.slug(from: name)
            XCTAssertTrue(slug.hasPrefix("org-"), "\(name) produced \(slug)")
            assertAccepted(slug)
        }
    }

    func testLongNameStaysWithinLimitAndNeverEndsOnAHyphen() {
        let slug = Organization.slug(from: String(repeating: "Very Long Company Name ", count: 6))
        XCTAssertLessThanOrEqual(slug.count, 40)
        XCTAssertFalse(slug.hasSuffix("-"))
        assertAccepted(slug)
    }

    func testSuffixIsAppendedForCollisionRetry() {
        XCTAssertEqual(Organization.slug(from: "Acme", suffix: "ab12"), "acme-ab12")
        assertAccepted(Organization.slug(from: "Acme", suffix: "ab12"))
    }

    func testSuffixSurvivesAnUnusableName() {
        let slug = Organization.slug(from: "Приклад", suffix: "ab12")
        XCTAssertEqual(slug, "ab12")
        assertAccepted(slug)
    }
}
