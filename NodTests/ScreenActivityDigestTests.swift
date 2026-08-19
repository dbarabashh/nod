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

    /// The two-phase read, collapsed: production fetches the index and the
    /// bodies from separate queries, and a test has both in hand already.
    private func digest(from observations: [ScreenObservation]) -> ScreenActivityDigest {
        var bodies: [String: String] = [:]
        for observation in observations
            where (bodies[observation.contentHash]?.count ?? 0) < observation.content.count {
            bodies[observation.contentHash] = observation.content
        }
        return ScreenActivityDigest.build(plan: plan(from: observations), bodies: bodies)
    }

    private func plan(from observations: [ScreenObservation]) -> ScreenActivityPlan {
        ScreenActivityDigest.plan(from: observations.map {
            ScreenObservationIndex(
                observedAt: $0.observedAt,
                sourceApp: $0.sourceApp,
                sourceTitle: $0.sourceTitle,
                contentHash: $0.contentHash
            )
        })
    }

    func testFoldsRepeatedCapturesOfOneWindowIntoOne() {
        let digest = digest(from: [
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
        let digest = digest(from: [
            observation(app: "com.slack", title: "#eng", content: "a", minutesAgo: 30),
            observation(app: "com.slack", title: "#eng", content: "b", minutesAgo: 2)
        ])

        let window = digest.apps[0].windows[0]
        XCTAssertEqual(window.lastSeen.timeIntervalSince(window.firstSeen), 28 * 60, accuracy: 1)
    }

    func testTitleGroupsAreCaseInsensitiveButDistinctWindowsStaySeparate() {
        let digest = digest(from: [
            observation(app: "com.slack", title: "#eng", content: "a", minutesAgo: 4),
            observation(app: "com.slack", title: "#ENG", content: "b", minutesAgo: 3),
            observation(app: "com.slack", title: "#design", content: "c", minutesAgo: 2)
        ])

        XCTAssertEqual(digest.apps[0].windows.count, 2)
    }

    func testUntitledWindowsDoNotCollapseIntoEachOther() {
        let digest = digest(from: [
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

        let digest = digest(from: rows)

        XCTAssertEqual(digest.apps.first?.bundleID, "com.main")
    }

    func testCapsAppsAndWindowsPerApp() {
        var rows: [ScreenObservation] = []
        for app in 1 ... (ScreenActivityDigest.maximumApps + 3) {
            for window in 1 ... (ScreenActivityDigest.maximumWindowsPerApp + 2) {
                rows.append(observation(app: "com.app\(app)", title: "w\(window)", content: "x", minutesAgo: window))
            }
        }

        let digest = digest(from: rows)

        XCTAssertEqual(digest.apps.count, ScreenActivityDigest.maximumApps)
        XCTAssertTrue(digest.apps.allSatisfy { $0.windows.count == ScreenActivityDigest.maximumWindowsPerApp })
    }

    func testTruncatesAWindowToTheCharacterCap() {
        let long = String(repeating: "a", count: ScreenActivityDigest.maximumWindowCharacters + 500)
        let digest = digest(from: [
            observation(app: "com.doc", title: "spec", content: long, minutesAgo: 1)
        ])

        XCTAssertEqual(digest.apps[0].windows[0].content.count, ScreenActivityDigest.maximumWindowCharacters)
    }

    func testEmptyInputIsEmptyDigest() {
        XCTAssertTrue(digest(from: []).isEmpty)
    }

    /// The whole point of planning from an index: a window seen in the morning
    /// has to survive into the plan, whatever happened all afternoon.
    func testMorningWindowsSurviveAnAfternoonOfOtherApps() {
        var rows = [observation(app: "com.figma", title: "Onboarding flow", content: "frames", minutesAgo: 540)]
        for minute in 1 ... 400 {
            rows.append(observation(app: "com.slack", title: "#eng \(minute)", content: "chatter", minutesAgo: minute))
        }

        let plan = plan(from: rows)

        XCTAssertTrue(plan.apps.contains { $0.bundleID == "com.figma" })
    }

    /// The counterpart to `testMorningWindowsSurviveAnAfternoonOfOtherApps`,
    /// one level down: surviving as an app is no use if the window that carried
    /// the work is then evicted from inside it.
    ///
    /// Asked "what was my day" twice, seconds apart, Nod described two
    /// different days — a few idle browser tabs opened in between had newer
    /// `lastSeen` than the pull request that took the evening, and took its
    /// slot. Windows rank by how long they were up, exactly as apps do.
    func testAWindowThatFilledTheDayOutranksRecentGlances() {
        var rows: [ScreenObservation] = []
        for minute in 60 ... 200 {
            rows.append(observation(app: "com.chrome", title: "PR #17", content: "review", minutesAgo: minute))
        }
        for (index, glance) in ["Dimension", "Littlebird", "Pricing", "Fundraising"].enumerated() {
            rows.append(observation(app: "com.chrome", title: glance, content: "tab", minutesAgo: index + 1))
        }

        let digest = digest(from: rows)
        let titles = digest.apps[0].windows.map(\.title)

        XCTAssertEqual(titles.first, "PR #17")
        XCTAssertEqual(digest.apps[0].windows.count, ScreenActivityDigest.maximumWindowsPerApp)
    }

    /// The same day asked about twice, with nothing but a fresh glance in
    /// between, has to come back the same. This is the property the recency
    /// ranking broke.
    func testANewGlanceDoesNotChangeWhatTheDayWasAbout() {
        var day: [ScreenObservation] = []
        for minute in 30 ... 120 {
            day.append(observation(app: "com.chrome", title: "PR #17", content: "review", minutesAgo: minute))
        }
        for minute in 130 ... 200 {
            day.append(observation(app: "com.chrome", title: "Reddit testers", content: "post", minutesAgo: minute))
        }

        let before = digest(from: day).apps[0].windows.map(\.title)
        let after = digest(from: day + [
            observation(app: "com.chrome", title: "Spectre", content: "player", minutesAgo: 1)
        ]).apps[0].windows.map(\.title)

        XCTAssertEqual(before.prefix(2).map { $0 }, ["PR #17", "Reddit testers"])
        XCTAssertEqual(after.prefix(2).map { $0 }, ["PR #17", "Reddit testers"])
    }

    func testPlanNamesEveryScreenStateOfAWindowUpToTheCandidateCap() {
        let rows = (1 ... ScreenActivityDigest.maximumCandidatesPerWindow + 4).map {
            observation(app: "com.editor", title: "main.swift", content: "state \($0)", minutesAgo: $0)
        }

        let plan = plan(from: rows)

        XCTAssertEqual(plan.apps[0].windows[0].candidateHashes.count, ScreenActivityDigest.maximumCandidatesPerWindow)
        XCTAssertEqual(plan.apps[0].windows[0].captures, rows.count)
    }

    func testHashesToReadAreDeduplicated() {
        let rows = [
            observation(app: "com.slack", title: "#eng", content: "identical", minutesAgo: 4),
            observation(app: "com.slack", title: "#design", content: "identical", minutesAgo: 3)
        ]

        let plan = plan(from: rows)

        XCTAssertEqual(plan.apps[0].windows.count, 2)
        XCTAssertEqual(plan.hashesToRead.count, 1)
    }

    /// A body that never arrived is a window we cannot report, not an empty one.
    func testWindowsWithoutABodyAreDropped() {
        let seen = observation(app: "com.jira", title: "AP-8", content: "the ticket body", minutesAgo: 5)
        let missing = observation(app: "com.figma", title: "Onboarding flow", content: "frames", minutesAgo: 6)
        let plan = plan(from: [seen, missing])

        let digest = ScreenActivityDigest.build(plan: plan, bodies: [seen.contentHash: seen.content])

        XCTAssertEqual(digest.apps.count, 1)
        XCTAssertEqual(digest.apps[0].bundleID, "com.jira")
    }

    /// The rules quote the block format literally, to tell the model to hide it.
    /// They live two folders from the code that emits it, so a format change
    /// leaves the prompt describing plumbing that no longer exists — which is
    /// what a one-word edit ("captured") nearly did.
    func testTheScreenRulesQuoteTheFormatWeActuallyEmit() {
        let digest = digest(from: [
            observation(app: "com.whatever", title: "a window", content: "the thread", minutesAgo: 5)
        ])

        let header = String(digest.apps[0].promptBlock(appName: "Whatever").prefix { $0 != "\n" })

        XCTAssertTrue(header.hasPrefix(ScreenPromptBlock.opening), header)
        XCTAssertTrue(header.contains(ScreenPromptBlock.captureMarker), header)
        // Checked against the emitter's own constants, not against a literal:
        // which app the rules pick for their example is theirs to change.
        XCTAssertTrue(
            PromptLibrary.screenRules.contains(ScreenPromptBlock.opening),
            "the rules stopped quoting the header they tell the model to hide"
        )
        XCTAssertTrue(
            PromptLibrary.screenRules.contains(ScreenPromptBlock.captureMarker),
            "the rules no longer say the stamp is a capture time"
        )
    }

    func testPromptBlockNamesTheAppAndItsWindows() {
        let digest = digest(from: [
            observation(app: "com.jira", title: "AP-8 icon colours", content: "grey icons", minutesAgo: 5)
        ])
        let block = digest.apps[0].promptBlock(appName: "Jira")

        XCTAssertTrue(block.hasPrefix("[On your screen — Jira, captured "))
        XCTAssertTrue(block.contains("AP-8 icon colours"))
        XCTAssertTrue(block.contains("grey icons"))
    }
}

/// The day on a screen block is computed here, not left for the model to
/// subtract from `[TODAY]`. It got that subtraction wrong on a real answer —
/// a Slack thread open twenty minutes earlier was reported as yesterday's.
@MainActor
final class ObservationStampTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_610_740)

    private func stamp(hoursAgo: Double) -> String {
        PromptLibrary.observationStamp(now.addingTimeInterval(-hoursAgo * 3600), now: now)
    }

    func testSomethingSeenMinutesAgoIsToday() {
        XCTAssertTrue(stamp(hoursAgo: 0.5).hasPrefix("today at "), stamp(hoursAgo: 0.5))
    }

    /// The regression: same clock time, one day back. A bare calendar date left
    /// both of these looking alike to the model.
    func testTheDayBeforeIsNamedYesterday() {
        XCTAssertTrue(stamp(hoursAgo: 24).hasPrefix("yesterday at "), stamp(hoursAgo: 24))
    }

    func testAnOlderWindowCarriesItsWeekdayAndItsAge() {
        let older = stamp(hoursAgo: 24 * 4)
        XCTAssertTrue(older.contains(" at "), older)
        XCTAssertTrue(older.hasSuffix("(4 days ago)"), older)
    }

    func testARangeInsideOneDayNamesTheDayOnce() {
        let start = now.addingTimeInterval(-3600)

        let span = PromptLibrary.observationSpan(from: start, to: now, now: now)

        XCTAssertTrue(span.hasPrefix("today at "), span)
        XCTAssertEqual(span.components(separatedBy: "today").count - 1, 1, span)
    }

    /// A window open across midnight has to say so on both ends, or the range
    /// reads as an hour when it was thirteen.
    func testARangeAcrossMidnightNamesBothDays() {
        let midnight = Calendar.current.startOfDay(for: now)

        let span = PromptLibrary.observationSpan(
            from: midnight.addingTimeInterval(-600),
            to: midnight.addingTimeInterval(600),
            now: now
        )

        XCTAssertTrue(span.contains("yesterday at "), span)
        XCTAssertTrue(span.contains("today at "), span)
    }

    /// Crossing midnight is a day change even when only minutes have passed —
    /// the comparison is between calendar days, not elapsed hours.
    func testJustAfterMidnightYesterdayIsStillYesterday() {
        let midnight = Calendar.current.startOfDay(for: now)
        let justBefore = midnight.addingTimeInterval(-60)

        XCTAssertTrue(
            PromptLibrary.observationStamp(justBefore, now: midnight.addingTimeInterval(300))
                .hasPrefix("yesterday at "),
            PromptLibrary.observationStamp(justBefore, now: midnight.addingTimeInterval(300))
        )
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
