import XCTest
@testable import Nod

/// The support email is the one place a person's build and machine reach us,
/// so its facts must survive the trip through a `mailto:` unchanged.
final class SupportReportTests: XCTestCase {
    private let environment = SupportReport.Environment(
        appVersion: "13.1.4",
        build: 1048,
        channel: "SANDBOX",
        osVersion: "26.6.0",
        model: "Mac17,9",
        chip: "Apple M5 Pro",
        architecture: "arm64",
        screens: 2,
        appearance: "dark"
    )

    func testTheBodyCarriesEveryFactAReportNeeds() {
        let report = SupportReport(kind: .bug, environment: environment, triggeredFrom: "Settings", reportID: "nod-1")
        let body = report.body
        for line in [
            "App: Nod 13.1.4 (1048)",
            "Build: sandbox arm64",
            "macOS: 26.6.0",
            "Mac: Mac17,9, Apple M5 Pro",
            "Screens: 2",
            "Appearance: dark",
            "Triggered from: Settings",
            "Report ID: nod-1"
        ] {
            XCTAssertTrue(body.contains(line), line)
        }
        XCTAssertTrue(body.contains(SupportReport.Kind.bug.prompt))
    }

    func testAReleaseBuildSaysSo() {
        var release = environment
        release.channel = nil
        let report = SupportReport(kind: .feature, environment: release, triggeredFrom: "Settings")
        XCTAssertTrue(report.body.contains("Build: release arm64"))
    }

    func testTheLinkIsAMailtoWithSubjectAndBodyEscaped() throws {
        let report = SupportReport(kind: .feature, environment: environment, triggeredFrom: "Settings", reportID: "nod-2")
        let url = try XCTUnwrap(report.url)
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, SupportReport.address)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["subject"], "Nod feature request")
        XCTAssertEqual(items["body"], report.body)
        XCTAssertFalse(url.absoluteString.contains("\n"))
        XCTAssertFalse(url.absoluteString.contains("<"))
    }

    func testEveryReportGetsItsOwnID() {
        let first = SupportReport(kind: .bug, environment: environment, triggeredFrom: "Settings")
        let second = SupportReport(kind: .bug, environment: environment, triggeredFrom: "Settings")
        XCTAssertNotEqual(first.reportID, second.reportID)
        XCTAssertTrue(first.reportID.hasPrefix("nod-"))
    }
}
