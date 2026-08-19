import XCTest
@testable import Nod

/// How much of a day actually reaches the model.
///
/// A recap that named two of the day's seven apps read as inattentive, and the
/// cause was arithmetic rather than the model: one fat app block filled the
/// allowance and ended the list, while a third of that allowance was reserved
/// for a half of the section this path cannot produce.
@MainActor
final class ScreenBudgetTests: XCTestCase {
    private func block(_ label: String, size: Int) -> String {
        label + String(repeating: "x", count: max(0, size - label.count))
    }

    /// The bug that cost most of the day. Ordering still decides who gets the
    /// room first; it must not decide who gets considered at all.
    func testAnOversizedBlockIsSkippedRatherThanEndingTheList() {
        let blocks = [block("fits", size: 100), block("huge", size: 5_000), block("also fits", size: 100)]

        let kept = KnowledgeChatStore.withinBudget(blocks, limit: 1_000)

        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.contains { $0.hasPrefix("also fits") }, "the tail of the day was dropped")
    }

    func testBlocksAreKeptInOrderUntilTheRoomRunsOut() {
        let blocks = (0 ..< 10).map { block("app\($0)", size: 300) }

        let kept = KnowledgeChatStore.withinBudget(blocks, limit: 1_000)

        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.first?.hasPrefix("app0"), true)
    }

    /// A single block longer than the whole allowance still has to answer the
    /// question, so it is cut rather than dropped.
    func testASoleOversizedBlockIsCutRatherThanLost() {
        let kept = KnowledgeChatStore.withinBudget([block("only", size: 5_000)], limit: 1_000)

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.count, 1_000)
    }

    // MARK: - The reservation

    /// A recap of a period never crosses — `crossed` short-circuits on
    /// `coversAWindow`, which that path always sets — so holding a third of
    /// the allowance back for it spent the budget on nothing.
    func testWithNoCrossingTheWholeAllowanceGoesToTheDay() {
        // More than the allowance can hold, so the budget is what binds.
        let day = (0 ..< 30).map { block("app\($0)", size: 1_200) }

        let kept = KnowledgeChatStore.sharingScreenBudget(question: day, crossed: [], isRecap: true)

        XCTAssertEqual(kept.count, KnowledgeChatStore.screenBudget / 1_200)
    }

    /// When there is a crossing, its share is still guaranteed: two fat
    /// question-driven blocks must not swallow a pass whose query and latency
    /// have already been paid for.
    func testACrossingKeepsItsShare() {
        // More than the allowance can hold, so the budget is what binds.
        let day = (0 ..< 30).map { block("app\($0)", size: 1_200) }
        let crossed = [block("crossed", size: 900)]

        let kept = KnowledgeChatStore.sharingScreenBudget(question: day, crossed: crossed, isRecap: true)

        XCTAssertTrue(kept.contains { $0.hasPrefix("crossed") })
        XCTAssertEqual(
            kept.filter { $0.hasPrefix("app") }.count,
            (KnowledgeChatStore.screenBudget - KnowledgeChatStore.crossingBudget) / 1_200
        )
    }

    // MARK: - Whose allowance it is

    /// The recap's room is the recap's. `recentContext` returns a handful of
    /// keyword-matched windows on an ordinary question, and giving those a
    /// day's allowance would make "what did Leo say about the ticket?" carry as
    /// much screen text as "what did I do today?".
    func testAnOrdinaryTurnGetsTheSmallerAllowance() {
        let matched = (0 ..< 30).map { block("window\($0)", size: 1_200) }

        let kept = KnowledgeChatStore.sharingScreenBudget(question: matched, crossed: [])

        XCTAssertEqual(kept.count, KnowledgeChatStore.matchedScreenBudget / 1_200)
        XCTAssertLessThan(KnowledgeChatStore.matchedScreenBudget, KnowledgeChatStore.screenBudget)
    }

    /// The two layers have to agree, and nothing but this says so.
    ///
    /// `ScreenActivityDigest` decides how much text one app can produce;
    /// `KnowledgeChatStore` decides how much of it survives into the prompt.
    /// They were tuned together by hand and live in different files — which is
    /// how the section came to hold 9k while a day needed far more, with no
    /// test noticing. A bump to `maximumApps` or `appBudget` re-creates that
    /// starvation silently unless something fails here.
    func testTheSectionCanHoldAFullDayOfApps() {
        let perApp = ScreenActivityDigest.appBudget
            + ScreenActivityDigest.maximumWindowsPerApp * ScreenActivityDigest.glimpseCharacters

        XCTAssertGreaterThanOrEqual(
            KnowledgeChatStore.screenBudget,
            ScreenActivityDigest.maximumApps * perApp,
            "a full day of apps no longer fits the prompt section"
        )
    }

    /// The two fixes are only worth anything together: skipping without room,
    /// or room without skipping, still leaves most of a day behind.
    func testADayOfSevenAppsNowFits() {
        let day = (0 ..< 7).map { block("app\($0)", size: 2_000) }

        let kept = KnowledgeChatStore.sharingScreenBudget(question: day, crossed: [], isRecap: true)

        XCTAssertEqual(kept.count, 7)
    }
}
