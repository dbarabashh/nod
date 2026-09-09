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
    /// Seeding off, as in `ScreenExclusionsTests`: these assert on category
    /// behaviour, and the shipped website defaults would otherwise be counted
    /// in every total. `ScreenExclusionSeedTests` covers the seed itself.
    private func makeExclusions() -> ScreenExclusions {
        let suite = "screen.categories.tests.\(UUID().uuidString)"
        return ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard, seedDefaults: false)
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
        let first = ScreenExclusions(defaults: defaults, seedDefaults: false)
        first.setExcluded(true, for: .banking)

        XCTAssertEqual(ScreenExclusions(defaults: defaults, seedDefaults: false).categories, [.banking])
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

    /// The regression, in the shape it arrived in: one person posts twice in a
    /// thread. Dropping the second author line left their last message headed by
    /// the `@mention` inside it, and an answer reported that mentioned person as
    /// having replied.
    func testAnAuthorPostingTwiceKeepsBothBylines() {
        let thread = [
            "Mikhail Koval", "Yesterday at 5:52 PM", "Just called it. It still could not handle the finishing call.",
            "2 replies",
            "Dima", "Yesterday at 6:27 PM", "I redeployed. I need a time to investigate this.",
            "Dima", "25 minutes ago", "@Mikhail Koval Hey, can you try to make a call from the livekit?"
        ]

        let text = ScreenObservationBuilder.text(from: thread)

        XCTAssertEqual(text?.components(separatedBy: "Dima").count, 3, text ?? "nil")
        XCTAssertTrue(text?.contains("Dima\n25 minutes ago") == true, text ?? "nil")
    }

    /// Keeping repeats must not make a repetitive window look substantial: the
    /// store gate and the OCR fallback both measure distinct content, or a
    /// sidebar label forty times over passes for a conversation.
    func testARepetitiveWindowIsStillJudgedOnItsDistinctContent() {
        let sidebar = Array(repeating: ["Threads", "Huddles", "Drafts & sent", "general"], count: 30).flatMap { $0 }

        XCTAssertNil(ScreenObservationBuilder.text(from: sidebar))
        XCTAssertLessThan(
            ScreenObservationBuilder.informativeLength(of: sidebar.joined(separator: "\n")),
            ScreenObservationBuilder.minimumCharacters
        )
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

    /// A vault window lists every account the user owns. Reading one is the
    /// worst single capture ambient context can make, so both halves — the
    /// desktop app and the web vault — are off before anyone configures
    /// anything.
    func testPasswordManagersAreExcludedOnAFreshInstall() {
        let exclusions = ScreenExclusions(defaults: freshDefaults())

        XCTAssertTrue(exclusions.excludesApp(bundleID: "com.1password.1password"))
        XCTAssertTrue(exclusions.excludesApp(bundleID: "com.bitwarden.desktop"))
        XCTAssertTrue(exclusions.excludesApp(bundleID: "com.apple.Passwords"))
        XCTAssertTrue(exclusions.excludesWindow(title: "Vault — 1password.com"))
        XCTAssertTrue(exclusions.excludesWindow(title: "bitwarden.com"))
    }

    /// One-time-secret links exist to be read once and destroyed. Capturing one
    /// into a 14-day index defeats the entire point of the service.
    func testSecretSharingSitesAreExcludedOnAFreshInstall() {
        let exclusions = ScreenExclusions(defaults: freshDefaults())

        XCTAssertTrue(exclusions.excludesWindow(title: "Shared secret · onetimesecret.com"))
        XCTAssertTrue(exclusions.excludesWindow(title: "privnote.com"))
        XCTAssertTrue(exclusions.excludesWindow(title: "pwpush.com/p/abc"))
    }

    /// Same contract as the apps: a shipped default is an ordinary entry, and
    /// removing one has to stick.
    func testARemovedDefaultWebsiteIsNotReAddedOnRelaunch() {
        let defaults = freshDefaults()
        let first = ScreenExclusions(defaults: defaults)
        first.removeWebsite("1password.com")

        let second = ScreenExclusions(defaults: defaults)

        XCTAssertFalse(second.excludesWindow(title: "Vault — 1password.com"))
        XCTAssertTrue(second.excludesWindow(title: "bitwarden.com"))
    }

    func testDefaultWebsitesAreLabelledAsSuch() {
        XCTAssertTrue(ScreenExclusions.isDefaultWebsite("1password.com"))
        XCTAssertFalse(ScreenExclusions.isDefaultWebsite("bank.com"))
    }

    func testSeedingDoesNotDisturbWebsitesTheUserAlreadyHas() {
        let defaults = freshDefaults()
        let existing = ScreenExclusions(defaults: defaults, seedDefaults: false)
        existing.excludeWebsite("bank.com")

        let seeded = ScreenExclusions(defaults: defaults)

        XCTAssertTrue(seeded.websites.contains("bank.com"))
        XCTAssertTrue(seeded.websites.contains("1password.com"))
    }
}

/// The allowlist exists because categories are keyword matches against a window
/// title, so they are broad by construction and will catch a site the user
/// actually wants read.
@MainActor
final class ScreenAlwaysIncludeTests: XCTestCase {
    private func makeExclusions() -> ScreenExclusions {
        let suite = "screen.allowlist.\(UUID().uuidString)"
        return ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard, seedDefaults: false)
    }

    func testAnAllowedSiteSurvivesAnExcludedCategory() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .shopping)
        XCTAssertTrue(exclusions.excludesWindow(title: "Order 12 — amazon"))

        exclusions.alwaysInclude("amazon")

        XCTAssertFalse(exclusions.excludesWindow(title: "Order 12 — amazon"))
    }

    /// The line the allowlist must never cross: an explicitly excluded site is
    /// the user saying "never read this", and no other rule gets to overrule it.
    func testAnAllowedSiteCannotReopenAnExplicitExclusion() {
        let exclusions = makeExclusions()
        exclusions.excludeWebsite("bank.com")

        XCTAssertEqual(exclusions.alwaysInclude("bank.com"), .excluded, "the entry would have had no effect")
        XCTAssertTrue(exclusions.excludesWindow(title: "Statements — bank.com"))
    }

    /// …including when it arrived as a shipped default, which is the case a
    /// user is least likely to remember setting.
    func testTheAllowlistCannotReopenADefaultExclusion() {
        let suite = "screen.allowlist.seeded.\(UUID().uuidString)"
        let exclusions = ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard)

        XCTAssertEqual(exclusions.alwaysInclude("1password.com"), .excluded)
        XCTAssertTrue(exclusions.excludesWindow(title: "Vault — 1password.com"))
    }

    func testAllowingDoesNotCaptureUnrelatedExcludedSites() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .shopping)
        exclusions.alwaysInclude("amazon")

        XCTAssertTrue(exclusions.excludesWindow(title: "Cart — ebay"))
    }

    func testAllowlistEntriesAreNormalizedAndDeduped() {
        let exclusions = makeExclusions()

        XCTAssertNil(exclusions.alwaysInclude("https://www.Portal.com/x"))
        XCTAssertEqual(exclusions.alwaysInclude("portal.com"), .duplicate)
        XCTAssertEqual(exclusions.alwaysIncluded, ["portal.com"])
    }

    func testAllowlistSurvivesAReload() {
        let suite = "screen.allowlist.reload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let first = ScreenExclusions(defaults: defaults, seedDefaults: false)
        first.alwaysInclude("portal.com")

        let second = ScreenExclusions(defaults: defaults, seedDefaults: false)

        XCTAssertEqual(second.alwaysIncluded, ["portal.com"])
    }

    func testRemovingAnAllowlistEntryRestoresTheCategory() {
        let exclusions = makeExclusions()
        exclusions.setExcluded(true, for: .shopping)
        exclusions.alwaysInclude("amazon")
        exclusions.removeAlwaysIncluded("amazon")

        XCTAssertTrue(exclusions.excludesWindow(title: "Order 12 — amazon"))
    }

    /// With no category on, the allowlist has nothing to override and must not
    /// start letting things through on its own.
    func testTheAllowlistDoesNothingWhenNoCategoryIsExcluded() {
        let exclusions = makeExclusions()
        exclusions.alwaysInclude("portal.com")

        XCTAssertFalse(exclusions.excludesWindow(title: "Standup — Google Meet"))
        XCTAssertFalse(exclusions.excludesWindow(title: "portal.com"))
    }

    /// A default shipped in a later version must not quietly overrule a choice
    /// the user already made in the other direction.
    func testSeedingSkipsASiteTheUserAlwaysIncluded() {
        let suite = "screen.allowlist.seed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let first = ScreenExclusions(defaults: defaults, seedDefaults: false)
        first.alwaysInclude("1password.com")

        let seeded = ScreenExclusions(defaults: defaults)

        XCTAssertFalse(seeded.websites.contains("1password.com"))
        XCTAssertTrue(seeded.alwaysIncluded.contains("1password.com"))
        XCTAssertTrue(seeded.websites.contains("bitwarden.com"), "the rest of the list still seeds")
    }

    func testAnExcludedDomainIsCaughtByTheURLWhenTheTitleHidesIt() {
        let rules = ScreenExclusionRules(appBundleIDs: [], websites: ["bank.com"])

        XCTAssertFalse(rules.excludesWindow(title: "Dashboard"), "the title alone names nothing")
        XCTAssertTrue(rules.excludesWindow(title: "Dashboard", url: "https://www.bank.com/accounts"))
    }

    func testTheAllowlistStillOverridesACategoryMatchedOnTheURL() {
        let rules = ScreenExclusionRules(
            appBundleIDs: [],
            websites: [],
            categoryKeywords: ["linkedin"],
            alwaysIncluded: ["linkedin.com"]
        )

        XCTAssertFalse(rules.excludesWindow(title: "Feed", url: "https://linkedin.com/feed"))
    }

    func testANamedExclusionOnTheURLOutranksAnAllowlistedTitle() {
        let rules = ScreenExclusionRules(
            appBundleIDs: [],
            websites: ["bank.com"],
            categoryKeywords: [],
            alwaysIncluded: ["notes"]
        )

        XCTAssertTrue(rules.excludesWindow(title: "notes", url: "https://bank.com/transfer"))
    }

    func testAWindowWithNoURLBehavesAsBefore() {
        let rules = ScreenExclusionRules(appBundleIDs: [], websites: ["bank.com"])

        XCTAssertTrue(rules.excludesWindow(title: "bank.com — Transfers"))
        XCTAssertFalse(rules.excludesWindow(title: "Untitled"))
    }

    func testTheLockScreenAndAuthorizationPromptAreNeverRead() {
        let rules = ScreenExclusionRules(appBundleIDs: [], websites: [])

        XCTAssertTrue(rules.excludesApp(bundleID: "com.apple.loginwindow"))
        XCTAssertTrue(rules.excludesApp(bundleID: "com.apple.SecurityAgent"))
        XCTAssertFalse(rules.excludesApp(bundleID: "com.tinyspeck.slackmacgap"))
    }
}
