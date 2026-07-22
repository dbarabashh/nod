import XCTest
@testable import Nod

@MainActor
final class ScreenExclusionsTests: XCTestCase {
    private func makeExclusions() -> ScreenExclusions {
        let suite = "screen.exclusions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return ScreenExclusions(defaults: defaults)
    }

    func testNormalizesWebsiteEntries() {
        XCTAssertEqual(ScreenExclusions.normalizeWebsite("https://www.Bank.com/login"), "bank.com")
        XCTAssertEqual(ScreenExclusions.normalizeWebsite("  HTTP://example.org  "), "example.org")
        XCTAssertEqual(ScreenExclusions.normalizeWebsite("bank.com"), "bank.com")
    }

    func testExcludingTheSameWebsiteTwiceIsRejected() {
        let exclusions = makeExclusions()

        XCTAssertTrue(exclusions.excludeWebsite("bank.com"))
        XCTAssertFalse(exclusions.excludeWebsite("https://www.bank.com/"))
        XCTAssertEqual(exclusions.websites, ["bank.com"])
    }

    func testEmptyWebsiteIsRejected() {
        let exclusions = makeExclusions()

        XCTAssertFalse(exclusions.excludeWebsite("   "))
        XCTAssertTrue(exclusions.websites.isEmpty)
    }

    func testAppExclusionIsCaseInsensitive() {
        let exclusions = makeExclusions()
        exclusions.exclude(ExcludedApp(bundleID: "com.example.Bank", name: "Bank"))

        XCTAssertTrue(exclusions.excludesApp(bundleID: "com.example.bank"))
        XCTAssertFalse(exclusions.excludesApp(bundleID: "us.zoom.xos"))
    }

    func testExcludedAppIsNotAddedTwice() {
        let exclusions = makeExclusions()
        let app = ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom")

        exclusions.exclude(app)
        exclusions.exclude(app)

        XCTAssertEqual(exclusions.apps.count, 1)
    }

    func testRemovingRestoresReadability() {
        let exclusions = makeExclusions()
        exclusions.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        exclusions.removeApp("us.zoom.xos")

        XCTAssertFalse(exclusions.excludesApp(bundleID: "us.zoom.xos"))
    }

    func testWindowTitlesMatchExcludedSites() {
        let rules = ScreenExclusionRules(appBundleIDs: [], websites: ["bank.com", "notion.so"])

        XCTAssertTrue(rules.excludesWindow(title: "Statements — bank.com"))
        XCTAssertTrue(rules.excludesWindow(title: "Roadmap | Notion.so"))
        XCTAssertFalse(rules.excludesWindow(title: "Standup - Google Meet"))
    }

    func testRulesSnapshotCarriesBothLists() {
        let exclusions = makeExclusions()
        exclusions.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        exclusions.excludeWebsite("bank.com")

        let rules = exclusions.rules

        XCTAssertEqual(rules.appBundleIDs, ["us.zoom.xos"])
        XCTAssertEqual(rules.websites, ["bank.com"])
    }

    func testExclusionsSurviveAReload() {
        let suite = "screen.exclusions.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no test suite") }
        let first = ScreenExclusions(defaults: defaults)
        first.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        first.excludeWebsite("bank.com")

        let reloaded = ScreenExclusions(defaults: defaults)

        XCTAssertEqual(reloaded.apps.map(\.bundleID), ["us.zoom.xos"])
        XCTAssertEqual(reloaded.websites, ["bank.com"])
    }
}

@MainActor
final class WebsiteCategoryTests: XCTestCase {
    private func makeExclusions() -> ScreenExclusions {
        let suite = "screen.categories.tests.\(UUID().uuidString)"
        return ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    func testEveryCategoryCarriesKeywords() {
        for category in WebsiteCategory.allCases {
            XCTAssertFalse(category.keywords.isEmpty, "\(category.title) has no keywords")
            XCTAssertFalse(category.summary.isEmpty)
        }
    }

    func testCategoryKeywordsAreLowercased() {
        for keyword in WebsiteCategory.keywords(for: Set(WebsiteCategory.allCases)) {
            XCTAssertEqual(keyword, keyword.lowercased())
        }
    }

    func testEnablingACategoryExcludesMatchingWindows() {
        let exclusions = makeExclusions()
        XCTAssertFalse(exclusions.excludesWindow(title: "Revolut — Accounts"))

        exclusions.setExcluded(true, for: .banking)

        XCTAssertTrue(exclusions.excludesWindow(title: "Revolut — Accounts"))
        XCTAssertFalse(exclusions.excludesWindow(title: "Standup - Google Meet"))
    }

    func testDisablingACategoryRestoresReadability() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .social)
        exclusions.setExcluded(false, for: .social)

        XCTAssertFalse(exclusions.excludesWindow(title: "Instagram"))
    }

    func testCategoriesSurviveAReload() {
        let suite = "screen.categories.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no test suite") }
        let first = ScreenExclusions(defaults: defaults)
        first.setExcluded(true, for: .banking)

        XCTAssertEqual(ScreenExclusions(defaults: defaults).categories, [.banking])
    }

    func testWebsiteRuleCountIncludesCategoryKeywords() {
        let exclusions = makeExclusions()
        exclusions.excludeWebsite("bank.com")
        exclusions.setExcluded(true, for: .adult)

        XCTAssertEqual(exclusions.websiteRuleCount, 1 + WebsiteCategory.adult.keywords.count)
    }

    func testRulesSnapshotCarriesCategoryKeywords() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .banking)

        XCTAssertTrue(exclusions.rules.excludesWindow(title: "Monobank"))
    }

    func testSearchMatchesCaseAndDiacriticInsensitively() {
        let app = InstalledApp(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")

        XCTAssertTrue(InstalledApps.matches(app, query: "saf"))
        XCTAssertTrue(InstalledApps.matches(app, query: "SAFARI"))
        XCTAssertTrue(InstalledApps.matches(app, query: "   "))
        XCTAssertFalse(InstalledApps.matches(app, query: "zoom"))
    }
}

@MainActor
final class ExclusionMatchingTests: XCTestCase {
    private func makeExclusions() -> ScreenExclusions {
        let suite = "screen.matching.tests.\(UUID().uuidString)"
        return ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// A category must never swallow a legitimate meeting whose title merely
    /// contains a keyword as a fragment.
    func testCategoryKeywordsDoNotMatchInsideLongerWords() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .shopping)
        exclusions.setExcluded(true, for: .banking)
        exclusions.setExcluded(true, for: .health)

        XCTAssertFalse(exclusions.excludesWindow(title: "Workshop — Google Meet"))
        XCTAssertFalse(exclusions.excludesWindow(title: "Rebranding kickoff — Google Meet"))
        XCTAssertFalse(exclusions.excludesWindow(title: "Healthcheck review — Google Meet"))
    }

    func testCategoryKeywordsStillMatchWholeWords() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .banking)

        XCTAssertTrue(exclusions.excludesWindow(title: "Revolut — Accounts"))
        XCTAssertTrue(exclusions.excludesWindow(title: "My bank — statements"))
    }

    func testDomainPatternsStillMatchAsSubstrings() {
        let rules = ScreenExclusionRules(appBundleIDs: [], websites: ["bank.com"])

        XCTAssertTrue(rules.excludesWindow(title: "Transfers | secure.bank.com/app"))
    }

    func testPunctuationSeparatesWords() {
        let rules = ScreenExclusionRules(appBundleIDs: [], websites: ["revolut"])

        XCTAssertTrue(rules.excludesWindow(title: "Revolut/Business — Dashboard"))
    }
}

@MainActor
final class ScreenContextTests: XCTestCase {
    func testAmbientContextIsOffUntilTurnedOn() {
        // The legal basis for ambient capture is consent (privacy.md § 3.10(b)),
        // which only holds while the feature is opt-in.
        UserDefaults.standard.removeObject(forKey: ScreenContextDefaults.enabledKey)

        XCTAssertFalse(ScreenContextDefaults.isEnabled)
    }

    func testRetentionFallsBackToTheDocumentedDefault() {
        UserDefaults.standard.removeObject(forKey: ScreenContextDefaults.retentionDaysKey)

        XCTAssertEqual(ScreenContextDefaults.retentionDays, 14)
        XCTAssertEqual(ScreenContextDefaults.retention, 14 * 24 * 60 * 60)
    }

    func testSearchDropsShortAndCommonWords() {
        let terms = ScreenContextService.searchTerms(in: "what was that ticket about the export formatting")

        XCTAssertFalse(terms.contains("was"))
        XCTAssertFalse(terms.contains("what"))
        XCTAssertFalse(terms.contains("about"))
        XCTAssertTrue(terms.contains("ticket"))
        XCTAssertTrue(terms.contains("formatting"))
    }

    func testSearchIsBoundedSoAQueryCannotFanOut() {
        let terms = ScreenContextService.searchTerms(in: "alpha bravo charlie delta echo foxtrot golf hotel india")

        XCTAssertLessThanOrEqual(terms.count, 6)
    }

    func testUnchangedScreensHashIdentically() {
        let first = ScreenObservation.hash("Ready for Live\n  AP-2: Sign up journey")
        let second = ScreenObservation.hash("ready for live\nAP-2:   Sign up journey  ")

        XCTAssertEqual(first, second)
    }

    func testDifferentScreensHashDifferently() {
        XCTAssertNotEqual(ScreenObservation.hash("AP-2 moved"), ScreenObservation.hash("AP-4 moved"))
    }

    func testThinWindowsAreNotWorthStoring() {
        XCTAssertNil(ScreenObservationBuilder.text(from: ["Mute", "Chat", "Leave"]))
        XCTAssertNil(ScreenObservationBuilder.text(from: []))
    }

    func testLongWindowsAreTruncatedNotDropped() {
        // Distinct lines on purpose: identical ones are deduplicated first, and
        // this is asserting the length cap, not the dedup.
        let long = (0 ..< 40).map { "line \($0) " + String(repeating: "context ", count: 40) }

        let text = ScreenObservationBuilder.text(from: long)

        XCTAssertEqual(text?.count, ScreenObservationBuilder.maximumCharacters)
    }

    func testRepeatedLinesCollapseBeforeTheLengthCap() {
        let repeated = Array(repeating: String(repeating: "context ", count: 40), count: 40)

        let text = ScreenObservationBuilder.text(from: repeated)

        let expected = repeated[0].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, expected, "a window repeating one line is one line of content")
    }

    func testObservationCarriesAnExpiry() {
        let observation = ScreenObservation(
            userID: UUID(),
            sourceApp: "com.tinyspeck.slackmacgap",
            sourceTitle: "Slack",
            content: String(repeating: "a", count: 200),
            retention: 3600
        )

        XCTAssertEqual(observation.expiresAt.timeIntervalSince(observation.observedAt), 3600, accuracy: 1)
    }
}
