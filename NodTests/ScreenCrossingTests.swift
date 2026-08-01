import XCTest
@testable import Nod

/// The crossing pass: the screen lookup seeded by what the retrieved sessions
/// are about, rather than by the user's question. It is the only path that can
/// put a commitment and the work on it in front of the model at once, so both
/// halves — which words seed it, and which observations survive — are pinned
/// here.
@MainActor
final class ScreenCrossingTests: XCTestCase {
    private let user = UUID()

    private func observation(
        id: UUID = UUID(),
        title: String,
        content: String,
        minutesAgo: Int
    ) -> ScreenObservation {
        ScreenObservation(
            id: id,
            userID: user,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60),
            sourceApp: "com.example.app",
            sourceTitle: title,
            content: content,
            retention: 3600
        )
    }

    // MARK: - Seeds

    func testAProjectNameBecomesItsSearchableWords() {
        XCTAssertEqual(ScreenContextService.searchTerms(inProjects: [["nod-landing"]]), ["landing"])
    }

    /// Short and very common words match every window, which is the same as
    /// matching none — the crossing drops them by the same rule the question
    /// path does, not by a second copy of it.
    func testShortAndCommonWordsAreDropped() {
        XCTAssertEqual(ScreenContextService.searchTerms(inProjects: [["Nod API v2"]]), [])
        XCTAssertEqual(ScreenContextService.searchTerms(inProjects: [["About the Export"]]), ["export"])
    }

    func testTheSameWordAcrossTwoProjectsIsSeededOnce() {
        XCTAssertEqual(
            ScreenContextService.searchTerms(inProjects: [["billing migration", "Billing dashboard"]]),
            ["billing", "migration", "dashboard"]
        )
    }

    /// One broad session must not spend the whole text search on itself.
    func testTheSeedListIsCapped() {
        let projects = ["alpha beta gamma delta epsilon zeta eta theta"]
        XCTAssertEqual(ScreenContextService.searchTerms(inProjects: [projects], limit: 3).count, 3)
    }

    func testNoProjectsMeansNoCrossing() {
        XCTAssertTrue(ScreenContextService.searchTerms(inProjects: []).isEmpty)
    }

    /// A flat cap in session order let the first grounded session spend every
    /// slot and the rest contribute nothing.
    func testEverySessionGetsASeedBeforeAnyGetsASecond() {
        let seeds = ScreenContextService.searchTerms(
            inProjects: [
                ["customer onboarding revamp phase two"],
                ["billing"],
                ["telemetry"]
            ],
            limit: 4
        )

        XCTAssertEqual(Array(seeds.prefix(3)), ["customer", "billing", "telemetry"])
    }

    // MARK: - Budget

    /// `withinBudget` stops at the first block that doesn't fit rather than
    /// skipping it, so appending the crossed windows behind two fat
    /// question-driven ones dropped every one of them.
    func testCrossedWindowsSurviveAFullQuestionSection() {
        let fat = Array(repeating: String(repeating: "x", count: 4_000), count: 3)

        let kept = KnowledgeChatStore.sharingScreenBudget(question: fat, crossed: ["the linked window"])

        XCTAssertTrue(kept.contains("the linked window"))
    }

    func testNeitherHalfCanExceedTheScreenBudget() {
        let fat = Array(repeating: String(repeating: "x", count: 4_000), count: 6)

        let kept = KnowledgeChatStore.sharingScreenBudget(question: fat, crossed: fat)

        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.count }, KnowledgeChatStore.screenBudget)
    }

    // MARK: - Ranking

    /// The tie to the session is the point, so the strongest match wins even
    /// when a weaker one is newer — the opposite of the question-driven path,
    /// which is ordered by recency.
    func testAStrongerMatchBeatsANewerOne() {
        let strong = observation(title: "migration plan", content: "step one", minutesAgo: 300)
        let weak = observation(title: "inbox", content: "re: migration", minutesAgo: 5)

        let ranked = ScreenContextService.linked([weak, strong], for: ["migration"], limit: 2)

        XCTAssertEqual(ranked.map(\.id), [strong.id, weak.id])
    }

    func testAnObservationTheQuestionAlreadyFoundIsNotRepeated() {
        let seen = observation(title: "migration plan", content: "step one", minutesAgo: 10)
        let fresh = observation(title: "migration notes", content: "step two", minutesAgo: 20)

        let ranked = ScreenContextService.linked(
            [seen, fresh],
            for: ["migration"],
            limit: 3,
            excluding: [seen.id]
        )

        XCTAssertEqual(ranked.map(\.id), [fresh.id])
    }

    func testAWindowThatMatchesNothingIsDropped() {
        let unrelated = observation(title: "Spotify", content: "now playing", minutesAgo: 1)

        XCTAssertTrue(ScreenContextService.linked([unrelated], for: ["migration"], limit: 3).isEmpty)
    }

    /// A single term is enough. Every seed is a name the extraction already
    /// judged central to a session, so requiring two would drop the ordinary
    /// case of one project discussed and one window open on it.
    func testASingleTermMatchIsKept() {
        let hit = observation(title: "Untitled", content: "the paddle webhook fails", minutesAgo: 2)

        XCTAssertEqual(
            ScreenContextService.linked([hit], for: ["paddle", "billing"], limit: 3).map(\.id),
            [hit.id]
        )
    }
}
