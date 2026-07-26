import XCTest
@testable import Nod

@MainActor
final class ScreenExclusionsTests: XCTestCase {
    /// Seeding off by default here so each test starts from an empty list and
    /// asserts on what it put there; `ScreenExclusionSeedTests` covers the seed.
    private func makeExclusions(seedDefaults: Bool = false) -> ScreenExclusions {
        let suite = "screen.exclusions.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return ScreenExclusions(defaults: defaults, seedDefaults: seedDefaults)
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
        let first = ScreenExclusions(defaults: defaults, seedDefaults: false)
        first.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        first.excludeWebsite("bank.com")

        let reloaded = ScreenExclusions(defaults: defaults, seedDefaults: false)

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
        // which only holds while the feature is opt-in. Asserted against the
        // resolution rule rather than the live setting: reading the real one
        // made this pass or fail depending on whether the person running the
        // tests happened to have ambient on.
        XCTAssertFalse(ScreenContextDefaults.resolveEnabled(fileByte: nil, legacyFlag: false))
    }

    func testAnExplicitOffSurvivesTheLegacyKey() {
        XCTAssertFalse(ScreenContextDefaults.resolveEnabled(fileByte: 0, legacyFlag: true))
        XCTAssertTrue(ScreenContextDefaults.resolveEnabled(fileByte: 1, legacyFlag: false))
    }

    func testAPreFileInstallFallsBackToTheOldKey() {
        XCTAssertTrue(ScreenContextDefaults.resolveEnabled(fileByte: nil, legacyFlag: true))
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

@MainActor
final class ScreenContextRelevanceTests: XCTestCase {
    private func observation(_ content: String) -> ScreenObservation {
        ScreenObservation(
            userID: UUID(),
            sourceApp: "com.example.app",
            sourceTitle: "Window",
            content: content,
            retention: 3600
        )
    }

    /// Postgres matches any term, so one incidental word used to be enough to
    /// drag an unrelated window into the answer's grounding.
    func testASingleIncidentalWordIsNotEnough() {
        let terms = ["jira", "ticket", "updates", "barabash"]
        let sourceCode = observation("private var ambientEnabled = false // updates the toggle")

        XCTAssertTrue(ScreenContextService.relevant([sourceCode], for: terms).isEmpty)
    }

    func testTwoMatchingTermsAreKept() {
        let terms = ["jira", "ticket", "updates", "barabash"]
        let board = observation("Jira board — AP-2 ticket moved to Ready for Live")

        XCTAssertEqual(ScreenContextService.relevant([board], for: terms).count, 1)
    }

    /// A one-word question has nothing to corroborate against, so one hit has
    /// to count or it would never retrieve anything.
    func testASingleTermQuestionStillMatches() {
        let board = observation("Jira board — AP-2 moved")

        XCTAssertEqual(ScreenContextService.relevant([board], for: ["jira"]).count, 1)
    }

    func testMatchingIsCaseInsensitive() {
        let board = observation("JIRA BOARD — TICKET AP-2")

        XCTAssertEqual(ScreenContextService.relevant([board], for: ["jira", "ticket"]).count, 1)
    }
}

final class ScreenObservationMergeTests: XCTestCase {
    /// Search runs over `content`, so a window whose only useful signal is its
    /// title — a Slack DM named "Jira", a ticket, a document — must carry that
    /// title into the searchable text or it can never be found.
    func testTitleLeadsTheStoredText() {
        let merged = ScreenObservationBuilder.merge(title: "Jira (DM) - Slack", text: "Home\nDMs\nActivity")

        XCTAssertTrue(merged.hasPrefix("Jira (DM) - Slack\n"))
        XCTAssertTrue(merged.contains("Activity"))
    }

    func testTitleIsNotRepeatedWhenTheBodyAlreadyStartsWithIt() {
        let merged = ScreenObservationBuilder.merge(title: "Inbox", text: "Inbox\n12 unread")

        XCTAssertEqual(merged, "Inbox\n12 unread")
    }

    func testEmptyTitleChangesNothing() {
        XCTAssertEqual(ScreenObservationBuilder.merge(title: "   ", text: "body"), "body")
    }

    /// Two Slack channels expose near-identical chrome; without the title in the
    /// hash they would collapse into one observation.
    func testDifferentWindowsWithIdenticalChromeStayDistinct() {
        let first = ScreenObservationBuilder.merge(title: "Jira (DM)", text: "Home\nDMs")
        let second = ScreenObservationBuilder.merge(title: "Iqbal (DM)", text: "Home\nDMs")

        XCTAssertNotEqual(ScreenObservation.hash(first), ScreenObservation.hash(second))
    }
}

@MainActor
final class ScreenExclusionSeedTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "screen.exclusions.seed.\(UUID().uuidString)") ?? .standard
    }

    func testMessengersAreExcludedOnAFreshInstall() {
        let exclusions = ScreenExclusions(defaults: freshDefaults())

        XCTAssertTrue(exclusions.excludesApp(bundleID: "net.whatsapp.WhatsApp"))
        XCTAssertTrue(exclusions.excludesApp(bundleID: "ru.keepcoder.Telegram"))
        XCTAssertFalse(exclusions.excludesApp(bundleID: "us.zoom.xos"))
    }

    /// The seed is a default, not a rule — removing one has to stick, or the
    /// user can never opt a messenger back in.
    func testARemovedMessengerIsNotReAddedOnRelaunch() {
        let defaults = freshDefaults()
        let first = ScreenExclusions(defaults: defaults)
        first.removeApp("net.whatsapp.WhatsApp")

        let second = ScreenExclusions(defaults: defaults)

        XCTAssertFalse(second.excludesApp(bundleID: "net.whatsapp.WhatsApp"))
        XCTAssertTrue(second.excludesApp(bundleID: "com.signal.Signal"))
    }

    func testSeedingDoesNotDisturbExclusionsTheUserAlreadyHas() {
        let defaults = freshDefaults()
        let existing = ScreenExclusions(defaults: defaults, seedDefaults: false)
        existing.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))

        let seeded = ScreenExclusions(defaults: defaults)

        XCTAssertTrue(seeded.excludesApp(bundleID: "us.zoom.xos"))
        XCTAssertTrue(seeded.excludesApp(bundleID: "net.whatsapp.WhatsApp"))
    }

    /// Every Telegram build is its own bundle id, and the one most people run
    /// was missing — which meant private chats were readable by default.
    func testEveryTelegramBuildIsExcluded() {
        let exclusions = ScreenExclusions(defaults: freshDefaults())

        XCTAssertTrue(exclusions.excludesApp(bundleID: "com.tdesktop.Telegram"))
        XCTAssertTrue(exclusions.excludesApp(bundleID: "ru.keepcoder.Telegram"))
        XCTAssertTrue(exclusions.excludesApp(bundleID: "org.telegram.desktop"))
    }

    /// An install that had already been seeded under the old boolean flag has
    /// to receive defaults added afterwards — that gap is what left existing
    /// users without the Telegram build they actually have.
    func testADefaultAddedLaterReachesAnAlreadySeededInstall() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "screen.exclusions.seededMessengers")

        let exclusions = ScreenExclusions(defaults: defaults)

        XCTAssertTrue(exclusions.excludesApp(bundleID: "com.tdesktop.Telegram"))
    }

    /// …but only the ones it never saw. A messenger removed before the list
    /// grew must stay removed.
    func testTheMigrationDoesNotResurrectARemovedMessenger() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "screen.exclusions.seededMessengers")

        let exclusions = ScreenExclusions(defaults: defaults)

        XCTAssertFalse(exclusions.excludesApp(bundleID: "net.whatsapp.WhatsApp"))
        XCTAssertFalse(exclusions.excludesApp(bundleID: "com.hnc.Discord"))
    }

    func testANewDefaultIsOnlyOfferedOnce() {
        let defaults = freshDefaults()
        let first = ScreenExclusions(defaults: defaults)
        first.removeApp("com.tdesktop.Telegram")

        let second = ScreenExclusions(defaults: defaults)

        XCTAssertFalse(second.excludesApp(bundleID: "com.tdesktop.Telegram"))
    }
}
