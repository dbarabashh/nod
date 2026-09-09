import XCTest
@testable import Nod

final class ReadyToFileTests: XCTestCase {
    private let meetingID = UUID()
    private let userID = UUID()

    private func proposal(
        _ status: ActionProposal.Status,
        item: UUID? = nil,
        key: String? = nil
    ) -> ActionProposal {
        var proposal = ActionProposal(
            id: UUID(),
            userID: userID,
            meetingID: meetingID,
            actionItemID: item,
            type: "linear.create_issue",
            status: status,
            parameters: ["title": "Ship it"],
            confidence: nil,
            confidenceParts: nil,
            evidenceIdx: nil,
            createdAt: nil
        )
        proposal.externalKey = key
        proposal.externalURL = key.map { "https://linear.app/nod/issue/\($0)" }
        return proposal
    }

    private func item(_ id: UUID = UUID(), done: Bool = false, filed: Bool = false) -> ActionItem {
        var item = ActionItem.new(id: id, meetingID: meetingID, userID: userID, text: "Ship it", deadline: nil, position: 0)
        if done { item = item.marked(done: true, at: Date()) }
        if filed {
            item = item.filed(
                in: ProviderLinkItem(provider: .linear, title: "NOD-1", url: URL(string: "https://linear.app/nod/issue/NOD-1")!),
                at: Date()
            )
        }
        return item
    }

    // MARK: - Phase

    func testNothingOutstandingDrawsNothing() {
        XCTAssertEqual(ReadyToFilePhase.of([], items: []), .nothing)
        XCTAssertEqual(ReadyToFilePhase.of([proposal(.rejected)], items: []), .nothing)
    }

    func testOffersWaitOnThePersonWithLastTimesFailures() {
        let offered = proposal(.ready)
        let failed = proposal(.failed)
        XCTAssertEqual(ReadyToFilePhase.of([failed, offered], items: []), .review([failed, offered]))
    }

    func testAnythingMovingMakesTheWholeBatchRunningInTheOrderOffered() {
        let running = proposal(.executing)
        let done = proposal(.completed, key: "NOD-2")
        let failed = proposal(.failed)
        let waiting = proposal(.ready)
        XCTAssertEqual(
            ReadyToFilePhase.of([done, waiting, failed, running], items: []),
            .running([done, failed, running])
        )
    }

    func testAStrandedApprovalIsRunningSoItCanBeRun() {
        let stranded = proposal(.approved)
        XCTAssertEqual(ReadyToFilePhase.of([stranded], items: []), .running([stranded]))
    }

    func testARefreshKeepsWhatThisRunFiledInItsPlace() {
        let done = proposal(.completed, key: "NOD-2")
        let stale = proposal(.completed, key: "NOD-3")
        let waiting = proposal(.ready)
        let newcomer = proposal(.ready)
        let fetched = [newcomer, waiting, stale.with(status: .rejected)]
        let merged = ActionProposalStore.merged(fetched, keeping: [done, stale, waiting])
        XCTAssertEqual(merged.map(\.id), [done.id, stale.id, waiting.id, newcomer.id])
        XCTAssertEqual(merged[1].status, .rejected)
    }

    func testARefreshDoesNotDowngradeARunningRow() {
        let running = proposal(.executing)
        let merged = ActionProposalStore.merged([running.with(status: .approved)], keeping: [running])
        XCTAssertEqual(merged.map(\.status), [.executing])
    }

    func testEverythingFiledIsDone() {
        let done = proposal(.completed, key: "NOD-2")
        XCTAssertEqual(ReadyToFilePhase.of([done], items: []), .done([done]))
    }

    func testAFailureAloneStaysRunningSoItCanBeRetried() {
        let failed = proposal(.failed)
        XCTAssertEqual(ReadyToFilePhase.of([failed], items: []), .running([failed]))
    }

    func testAnOfferForATickedOrHandFiledRowIsDropped() {
        let ticked = item(done: true)
        let filedByHand = item(filed: true)
        let offers = [ticked, filedByHand].map { proposal(.ready, item: $0.id) }
        XCTAssertEqual(ReadyToFilePhase.of(offers, items: [ticked, filedByHand]), .nothing)
    }

    func testAnOfferWhoseRowIsNotLoadedIsKept() {
        let offer = proposal(.ready, item: UUID())
        XCTAssertEqual(ReadyToFilePhase.of([offer], items: []), .review([offer]))
    }

    func testACompletedProposalOutlivesItsRowBeingFiled() {
        let row = item(filed: true)
        let done = proposal(.completed, item: row.id, key: "NOD-1")
        XCTAssertEqual(ReadyToFilePhase.of([done], items: [row]), .done([done]))
    }

    func testTheReferenceOfADoneProposalOpensTheTicket() throws {
        let done = proposal(.completed, key: "NOD-7")
        let reference = try XCTUnwrap(ReadyToFileCard.reference(of: done))
        XCTAssertEqual(reference.provider, .linear)
        XCTAssertEqual(reference.title, "NOD-7")
        XCTAssertEqual(reference.note, "Ship it")
        XCTAssertNil(ReadyToFileCard.reference(of: proposal(.completed)))
    }

    // MARK: - Undo

    func testUnfilingSendsExplicitNullsNotOmittedKeys() throws {
        let data = try JSONEncoder().encode(ActionItemStore.UnfilingBody(updatedAt: Date()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["external_provider", "external_key", "external_url", "external_created_at"] {
            XCTAssertTrue(json.keys.contains(key), "\(key) must be sent")
            XCTAssertTrue(json[key] is NSNull, "\(key) must be null")
        }
        XCTAssertNotNil(json["updated_at"])
    }

    // MARK: - Where the batch goes

    func testTheOnlyTrackerIsThePreferredOne() {
        XCTAssertEqual(IntegrationService.preferred(among: [.jira], chosen: nil), .jira)
    }

    func testTwoTrackersAndNoPickIsNoTracker() {
        XCTAssertNil(IntegrationService.preferred(among: [.jira, .linear], chosen: nil))
    }

    func testThePickWinsWhileItIsStillConnected() {
        XCTAssertEqual(IntegrationService.preferred(among: [.jira, .linear], chosen: .linear), .linear)
        XCTAssertEqual(IntegrationService.preferred(among: [.jira], chosen: .linear), .jira)
        XCTAssertNil(IntegrationService.preferred(among: [.jira, .asana], chosen: .linear))
    }

    // MARK: - The offer to connect

    func testOnlyTrackersWithAMarkAreOffered() {
        let offered = TrackerConnectRow.offered(blocked: [], ships: [.linear, .jira, .slack, .notion])
        XCTAssertEqual(offered, [.linear, .jira])
    }

    func testABlockedTrackerIsNotOffered() {
        let offered = TrackerConnectRow.offered(blocked: [.jira], ships: [.linear, .jira])
        XCTAssertEqual(offered, [.linear])
    }
}

private extension ActionProposal {
    func with(status: Status) -> ActionProposal {
        var copy = self
        copy.status = status
        return copy
    }
}
