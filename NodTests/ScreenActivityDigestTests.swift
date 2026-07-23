import XCTest
@testable import Nod

final class ScreenActivityDigestTests: XCTestCase {
    private let user = UUID()

    private func observation(
        app: String,
        title: String,
        content: String,
        minutesAgo: Int
    ) -> ScreenObservation {
        ScreenObservation(
            userID: user,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60),
            sourceApp: app,
            sourceTitle: title,
            content: content,
            retention: 3600
        )
    }

    func testFoldsRepeatedCapturesOfOneWindowIntoOne() {
        let digest = ScreenActivityDigest.build(from: [
            observation(app: "com.jira", title: "AP-8 icon colours", content: "short", minutesAgo: 5),
            observation(app: "com.jira", title: "AP-8 icon colours", content: "the fuller body", minutesAgo: 9),
            observation(app: "com.jira", title: "AP-8 icon colours", content: "mid", minutesAgo: 7)
        ])

        XCTAssertEqual(digest.apps.count, 1)
        XCTAssertEqual(digest.apps[0].windows.count, 1)
        XCTAssertEqual(digest.apps[0].captures, 3)
        // The fullest read wins — the same window differs only by how much loaded.
        XCTAssertEqual(digest.apps[0].windows[0].content, "the fuller body")
        XCTAssertEqual(digest.apps[0].windows[0].captures, 3)
    }

    func testKeepsWindowSpan() {
        let digest = ScreenActivityDigest.build(from: [
            observation(app: "com.slack", title: "#eng", content: "a", minutesAgo: 30),
            observation(app: "com.slack", title: "#eng", content: "b", minutesAgo: 2)
        ])

        let window = digest.apps[0].windows[0]
        XCTAssertEqual(window.lastSeen.timeIntervalSince(window.firstSeen), 28 * 60, accuracy: 1)
    }

    func testTitleGroupsAreCaseInsensitiveButDistinctWindowsStaySeparate() {
        let digest = ScreenActivityDigest.build(from: [
            observation(app: "com.slack", title: "#eng", content: "a", minutesAgo: 4),
            observation(app: "com.slack", title: "#ENG", content: "b", minutesAgo: 3),
            observation(app: "com.slack", title: "#design", content: "c", minutesAgo: 2)
        ])

        XCTAssertEqual(digest.apps[0].windows.count, 2)
    }

    func testUntitledWindowsDoNotCollapseIntoEachOther() {
        let digest = ScreenActivityDigest.build(from: [
            observation(app: "com.editor", title: "", content: "one thing", minutesAgo: 4),
            observation(app: "com.editor", title: "", content: "another thing entirely", minutesAgo: 3)
        ])

        XCTAssertEqual(digest.apps[0].windows.count, 2)
    }

    func testAppsAreRankedByHowLongTheyWereOnScreen() {
        var rows = [observation(app: "com.rare", title: "glance", content: "x", minutesAgo: 1)]
        for minute in 2 ... 6 {
            rows.append(observation(app: "com.main", title: "work \(minute)", content: "x", minutesAgo: minute))
        }

        let digest = ScreenActivityDigest.build(from: rows)

        XCTAssertEqual(digest.apps.first?.bundleID, "com.main")
    }

    func testCapsAppsAndWindowsPerApp() {
        var rows: [ScreenObservation] = []
        for app in 1 ... (ScreenActivityDigest.maximumApps + 3) {
            for window in 1 ... (ScreenActivityDigest.maximumWindowsPerApp + 2) {
                rows.append(observation(app: "com.app\(app)", title: "w\(window)", content: "x", minutesAgo: window))
            }
        }

        let digest = ScreenActivityDigest.build(from: rows)

        XCTAssertEqual(digest.apps.count, ScreenActivityDigest.maximumApps)
        XCTAssertTrue(digest.apps.allSatisfy { $0.windows.count == ScreenActivityDigest.maximumWindowsPerApp })
    }

    func testTruncatesAWindowToTheCharacterCap() {
        let long = String(repeating: "a", count: ScreenActivityDigest.maximumWindowCharacters + 500)
        let digest = ScreenActivityDigest.build(from: [
            observation(app: "com.doc", title: "spec", content: long, minutesAgo: 1)
        ])

        XCTAssertEqual(digest.apps[0].windows[0].content.count, ScreenActivityDigest.maximumWindowCharacters)
    }

    func testEmptyInputIsEmptyDigest() {
        XCTAssertTrue(ScreenActivityDigest.build(from: []).isEmpty)
    }

    func testPromptBlockNamesTheAppAndItsWindows() {
        let digest = ScreenActivityDigest.build(from: [
            observation(app: "com.jira", title: "AP-8 icon colours", content: "grey icons", minutesAgo: 5)
        ])
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let block = digest.apps[0].promptBlock(appName: "Jira", formatter: formatter)

        XCTAssertTrue(block.hasPrefix("[On your screen — Jira, "))
        XCTAssertTrue(block.contains("AP-8 icon colours"))
        XCTAssertTrue(block.contains("grey icons"))
    }
}

@MainActor
final class ScreenContextTitleWeightTests: XCTestCase {
    private func observation(title: String, content: String) -> ScreenObservation {
        ScreenObservation(
            userID: UUID(),
            sourceApp: "com.tinyspeck.slackmacgap",
            sourceTitle: title,
            content: content,
            retention: 3600
        )
    }

    func testATitleMatchAloneIsEnough() {
        let terms = ScreenContextService.searchTerms(in: "Any recent updates or mentions of Jira in my meetings?")
        let window = observation(title: "Jira (DM) - CourtCorrect Ltd - Slack", content: "a thread about nothing else")

        XCTAssertEqual(ScreenContextService.relevant([window], for: terms).count, 1)
    }

    func testOneCommonBodyWordIsStillNotEnough() {
        let terms = ScreenContextService.searchTerms(in: "Any recent updates or mentions of Jira in my meetings?")
        let window = observation(title: "Figma", content: "these are the recent frames we drew")

        XCTAssertTrue(ScreenContextService.relevant([window], for: terms).isEmpty)
    }

    func testTwoBodyMatchesStillQualify() {
        let terms = ScreenContextService.searchTerms(in: "what did we decide about pricing tiers")
        let window = observation(title: "Notes", content: "the pricing page needs new tiers before launch")

        XCTAssertEqual(ScreenContextService.relevant([window], for: terms).count, 1)
    }
}

final class ScreenRecallTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecognisesRecapQuestions() {
        for question in [
            "What have I been working on?",
            "what was I doing this morning",
            "catch me up on my day",
            "що я робив сьогодні",
            "над чим я працював вчора"
        ] {
            XCTAssertNotNil(ScreenRecall.window(for: question, now: now), question)
        }
    }

    func testRecognisesCatchingUpQuestions() {
        for question in [
            "any recent updates?",
            "any updates?",
            "what's new",
            "what did I miss",
            "where did I leave off",
            "що нового",
            "що я пропустив"
        ] {
            XCTAssertNotNil(ScreenRecall.window(for: question, now: now), question)
        }
    }

    /// Substring matching missed every one of these — a word slipped in
    /// between the two the phrase names.
    func testMatchesPhraseWordsInAnyOrderOrDistance() {
        for question in [
            "які останні новини",
            "які у нас новини",
            "what have I actually been working on",
            "what did I end up doing yesterday"
        ] {
            XCTAssertNotNil(ScreenRecall.window(for: question, now: now), question)
        }
    }

    func testIgnoresOrdinaryQuestions() {
        for question in [
            "what did Leo say about pricing",
            "summarize the standup",
            "які дедлайни по проєкту"
        ] {
            XCTAssertNil(ScreenRecall.window(for: question, now: now), question)
        }
    }

    func testFallsBackToADayWhenNoPeriodIsNamed() {
        let window = ScreenRecall.window(for: "what have I been up to", now: now)

        XCTAssertEqual(window?.end, now)
        XCTAssertEqual(window?.duration ?? 0, ScreenRecall.defaultLookback, accuracy: 1)
    }

    func testANamedPeriodNeverReachesIntoTheFuture() {
        let window = ScreenRecall.window(for: "what was I doing today", now: now)

        XCTAssertNotNil(window)
        XCTAssertEqual(window?.end, now)
    }
}
