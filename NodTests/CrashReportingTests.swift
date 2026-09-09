import XCTest
@testable import Nod

/// The SDK starts only for a build that carries a DSN and a person who has
/// not said no. Both halves are pinned, because a Debug build that reported
/// a developer's crashes, or a switched-off preference that was ignored,
/// would each break a sentence in the privacy policy.
final class CrashReportingTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "nod.tests.crash.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testNoDsnMeansNoReporting() {
        XCTAssertNil(CrashReporting.configuration(from: [:], version: "1", build: 1))
        XCTAssertNil(CrashReporting.configuration(from: ["NodSentryDSN": "  "], version: "1", build: 1))
        XCTAssertNil(CrashReporting.configuration(from: nil, version: "1", build: 1))
    }

    func testADsnNamesTheEnvironmentAndRelease() throws {
        let configuration = try XCTUnwrap(CrashReporting.configuration(
            from: ["NodSentryDSN": "https://key@o1.ingest.sentry.io/2", "NodSentryEnvironment": "sandbox"],
            version: "13.1.4",
            build: 69
        ))
        XCTAssertEqual(configuration.environment, "sandbox")
        XCTAssertEqual(configuration.release, "nod@13.1.4+69")
    }

    func testAnEmptyEnvironmentFallsBackToProduction() throws {
        let configuration = try XCTUnwrap(CrashReporting.configuration(
            from: ["NodSentryDSN": "https://key@o1.ingest.sentry.io/2", "NodSentryEnvironment": ""],
            version: "1",
            build: 1
        ))
        XCTAssertEqual(configuration.environment, "production")
    }

    func testNothingIsSentBeforeThePersonIsAsked() throws {
        let store = try defaults()
        XCTAssertFalse(CrashReporting.hasBeenAsked(in: store))
        XCTAssertFalse(CrashReporting.isEnabled(in: store))
    }

    func testAnAnswerIsRemembered() throws {
        let store = try defaults()
        store.set(true, forKey: CrashReporting.askedKey)
        XCTAssertTrue(CrashReporting.isEnabled(in: store), "the default answer is yes once asked")
        store.set(false, forKey: CrashReporting.defaultsKey)
        XCTAssertFalse(CrashReporting.isEnabled(in: store))
    }
}
