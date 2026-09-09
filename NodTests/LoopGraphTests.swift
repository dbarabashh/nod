import XCTest
@testable import Nod

/// The retrieval that has to work without knowing who anybody is. Nod has no
/// meeting bot, so identity is the least reliable thing it holds — these pin
/// that the graph is entered through the right door and never a near-miss.
final class LoopGraphTests: XCTestCase {
    private let userID = UUID()
    private let now = Date(timeIntervalSince1970: 1_787_773_380)

    /// The two-step the production path takes, as one call: tokenise what was
    /// said, then ask the index which entities it names.
    private func named(_ said: String, _ entities: Entity...) -> [Entity] {
        LoopGraph.mentioned(
            in: LoopCandidates.words(in: said),
            among: LoopGraph.Index(entities: entities, byMeeting: [:])
        )
    }

    private func entity(_ name: String, kind: EntityKind = .project) -> Entity {
        Entity(id: UUID(), userID: userID, kind: kind, name: name)
    }

    private func loop(_ text: String, meeting: UUID, daysAgo: Int = 0) -> ActionItem {
        var made = ActionItem(
            id: UUID(),
            meetingID: meeting,
            userID: userID,
            text: text,
            deadline: nil,
            position: nil,
            done: false,
            doneAt: nil,
            externalProvider: nil,
            externalKey: nil,
            externalURL: nil,
            externalCreatedAt: nil,
            createdAt: now.addingTimeInterval(-Double(daysAgo) * 86_400),
            updatedAt: nil,
            deletedAt: nil
        )
        made.status = .confirmed
        made.loopState = .open
        return made
    }

    /// The case the word filter cannot reach: the same project, said two
    /// different ways, in two different languages.
    func testALoopIsFoundThroughASharedProjectNotSharedWording() {
        let mobile = entity("Mobile Companion")
        let earlier = UUID()
        let current = UUID()
        let index = LoopGraph.Index(
            entities: [mobile],
            byMeeting: [earlier: [mobile.id], current: [mobile.id]]
        )
        let promise = loop("надіслати макети", meeting: earlier)

        let picked = LoopCandidates.pick(
            from: [promise],
            mentionedIn: "what is the state of the mobile companion right now",
            excluding: current,
            graph: index
        )

        XCTAssertEqual(picked.map(\.id), [promise.id])
    }

    /// Every content word of the name has to be present. "Mobile Companion" and
    /// "mobile carrier billing" share a word and nothing else, and a graph
    /// entered through the wrong door returns confident nonsense.
    func testAPartialNameMatchIsNotAMatch() {
        let mobile = entity("Mobile Companion")

        XCTAssertTrue(named("the mobile carrier billing", mobile).isEmpty)
        XCTAssertEqual(
            named("shipping mobile companion this week", mobile).map(\.id),
            [mobile.id]
        )
    }

    /// A name that survives normalisation as nothing cannot be matched safely,
    /// and matching it loosely would put it in every conversation.
    func testAnEntityWithNoContentWordsIsSkipped() {
        XCTAssertTrue(named("we shipped it", entity("Nod")).isEmpty)
    }

    /// Ordered by how much of the subject the loop's meeting shared, so a
    /// session that was about the same two things outranks one that brushed
    /// against a single topic.
    func testMoreSharedSubjectOutranksLess() {
        let pricing = entity("Pricing Model")
        let billing = entity("Billing Flow")
        let both = UUID()
        let one = UUID()
        let current = UUID()
        let index = LoopGraph.Index(
            entities: [pricing, billing],
            byMeeting: [
                both: [pricing.id, billing.id],
                one: [pricing.id],
                current: [pricing.id]
            ]
        )
        let weaker = loop("weaker", meeting: one)
        let stronger = loop("stronger", meeting: both)

        let picked = LoopGraph.loops(
            touching: LoopGraph.mentioned(
                in: LoopCandidates.words(in: "the pricing model and the billing flow"),
                among: index
            ),
            in: index,
            among: [weaker, stronger],
            excluding: current
        )

        XCTAssertEqual(picked.map(\.text), ["stronger", "weaker"])
    }

    /// The same rule the wording filter sorts by: the point is the promise
    /// nobody has thought about, and a tie broken towards the recent one buries
    /// exactly the loop this feature exists for.
    func testATieGoesToTheOlderLoop() {
        let pricing = entity("Pricing Model")
        let left = UUID()
        let right = UUID()
        let index = LoopGraph.Index(
            entities: [pricing],
            byMeeting: [left: [pricing.id], right: [pricing.id]]
        )
        let fresh = loop("fresh", meeting: left, daysAgo: 2)
        let forgotten = loop("forgotten", meeting: right, daysAgo: 40)

        let picked = LoopGraph.loops(
            touching: [pricing],
            in: index,
            among: [fresh, forgotten],
            excluding: UUID()
        )

        XCTAssertEqual(picked.map(\.text), ["forgotten", "fresh"])
    }

    /// Asking whether this conversation resolved what this conversation just
    /// raised is asking the model to agree with itself.
    func testTheMeetingsOwnLoopsAreNeverCandidates() {
        let pricing = entity("Pricing Model")
        let current = UUID()
        let index = LoopGraph.Index(entities: [pricing], byMeeting: [current: [pricing.id]])

        let picked = LoopGraph.loops(
            touching: [pricing],
            in: index,
            among: [loop("just raised", meeting: current)],
            excluding: current
        )

        XCTAssertTrue(picked.isEmpty)
    }

    func testAClosedOrDeletedLoopIsNeverReached() {
        let pricing = entity("Pricing Model")
        let earlier = UUID()
        let index = LoopGraph.Index(entities: [pricing], byMeeting: [earlier: [pricing.id]])

        var closed = loop("done", meeting: earlier)
        closed.loopState = .confirmed
        var deleted = loop("gone", meeting: earlier)
        deleted = ActionItem(
            id: deleted.id,
            meetingID: earlier,
            userID: userID,
            text: "gone",
            deadline: nil,
            position: nil,
            done: false,
            doneAt: nil,
            externalProvider: nil,
            externalKey: nil,
            externalURL: nil,
            externalCreatedAt: nil,
            createdAt: now,
            updatedAt: nil,
            deletedAt: now
        )

        let picked = LoopGraph.loops(
            touching: [pricing],
            in: index,
            among: [closed, deleted],
            excluding: UUID()
        )

        XCTAssertTrue(picked.isEmpty)
    }

    /// An account whose sessions have not been through extraction is the honest
    /// state of a fresh install, not an error: the wording filter is what this
    /// did before the graph existed, and it still works.
    func testWithoutAGraphTheWordingFilterStillAnswers() {
        let earlier = UUID()
        let promise = loop("send the pricing deck", meeting: earlier)

        let picked = LoopCandidates.pick(
            from: [promise],
            mentionedIn: "did anyone send the pricing deck",
            excluding: UUID(),
            graph: .empty
        )

        XCTAssertEqual(picked.map(\.id), [promise.id])
    }

    /// The graph leads and the wording tops up. Both loops must arrive, the
    /// graph's first, and neither twice.
    func testGraphHitsLeadAndWordingFillsTheRestWithoutDuplicates() {
        let mobile = entity("Mobile Companion")
        let viaGraph = UUID()
        let viaWords = UUID()
        let index = LoopGraph.Index(entities: [mobile], byMeeting: [viaGraph: [mobile.id]])
        let reached = loop("надіслати макети", meeting: viaGraph, daysAgo: 5)
        let worded = loop("write the migration guide", meeting: viaWords, daysAgo: 5)

        let picked = LoopCandidates.pick(
            from: [worded, reached],
            mentionedIn: "mobile companion — and the migration guide too",
            excluding: UUID(),
            graph: index
        )

        XCTAssertEqual(picked.map(\.text), ["надіслати макети", "write the migration guide"])
        XCTAssertEqual(Set(picked.map(\.id)).count, picked.count)
    }

    func testTheLimitIsRespectedAcrossBothSources() {
        let mobile = entity("Mobile Companion")
        let earlier = UUID()
        let index = LoopGraph.Index(entities: [mobile], byMeeting: [earlier: [mobile.id]])
        let many = (0 ..< 6).map { loop("mobile companion task \($0)", meeting: earlier, daysAgo: $0) }

        let picked = LoopCandidates.pick(
            from: many,
            mentionedIn: "mobile companion task",
            excluding: UUID(),
            graph: index,
            limit: 2
        )

        XCTAssertEqual(picked.count, 2)
    }

    /// A name that survives normalisation as nothing would otherwise be present
    /// in every sentence — the same trap the phrase form closes with a length
    /// floor.
    func testAnEmptyNameNeverMatches() {
        XCTAssertFalse(EntityMatcher.names([], spokenIn: ["anything", "at", "all"]))
    }

    func testWordOrderDoesNotMatterForASpokenName() {
        let said = LoopCandidates.words(in: "the companion app we build for mobile")

        XCTAssertTrue(EntityMatcher.names(LoopCandidates.words(in: "Mobile Companion"), spokenIn: said))
    }

    /// The room's own sentence is better retrieval material than the
    /// extractor's summary of it, and often the only one anybody says again.
    func testAStoredQuoteIsMatchedBesideTheExtractorsWording() {
        let earlier = UUID()
        var promise = loop("Send the updated deck", meeting: earlier)
        promise.evidenceQuote = "я скину презентацію після дзвінка"

        let picked = LoopCandidates.pick(
            from: [promise],
            mentionedIn: "ти вже скинув презентацію?",
            excluding: UUID()
        )

        XCTAssertEqual(picked.map(\.id), [promise.id])
    }

    func testALoopWithNoQuoteStillMatchesOnItsOwnWording() {
        let promise = loop("send the pricing deck", meeting: UUID())

        XCTAssertEqual(promise.matchable, "send the pricing deck")
    }
}
