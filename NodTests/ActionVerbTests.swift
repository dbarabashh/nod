import XCTest
@testable import Nod

final class ActionVerbTests: XCTestCase {
    private let defaults: UserDefaults = {
        let suite = "ActionVerbTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    // MARK: - Verbs and carriers

    func testEveryVerbHasACarrierAndAProviderCarriesOnlyItsVerbs() {
        XCTAssertEqual(ActionVerb.task.carriers(among: IntegrationProvider.allCases), [.linear, .jira, .asana, .googleTasks])
        XCTAssertEqual(ActionVerb.message.carriers(among: IntegrationProvider.allCases), [.slack])
        XCTAssertEqual(ActionVerb.event.carriers(among: IntegrationProvider.allCases), [.googleCalendar])
        XCTAssertEqual(ActionVerb.note.carriers(among: IntegrationProvider.allCases), [.hubspot])
        XCTAssertNil(ActionVerb.task.action(in: .hubspot))
    }

    func testAProposalTypeReadsBackAsItsVerb() {
        XCTAssertEqual(ActionVerb.of(type: "linear.create_issue"), .task)
        XCTAssertEqual(ActionVerb.of(type: "google-tasks.create_task"), .task)
        XCTAssertEqual(ActionVerb.of(type: "slack.post_message"), .message)
        XCTAssertEqual(ActionVerb.of(type: "google-calendar.create_event"), .event)
        XCTAssertEqual(ActionVerb.of(type: "hubspot.create_note"), .note)
        XCTAssertNil(ActionVerb.of(type: "linear.update_issue"))
        XCTAssertNil(ActionVerb.of(type: "nonsense"))
    }

    // MARK: - Rules

    func testATrackerMakesEverythingATask() {
        XCTAssertEqual(ActionVerb.suggested(for: .init(hasTracker: true, hasMessenger: true, isTheirs: true)), .task)
        XCTAssertEqual(ActionVerb.suggested(for: .init(hasTracker: true)), .task)
    }

    func testSomebodyElsesCommitmentBecomesAMessageWhenThereIsNoTracker() {
        XCTAssertEqual(ActionVerb.suggested(for: .init(hasMessenger: true, isTheirs: true)), .message)
        XCTAssertNil(ActionVerb.suggested(for: .init(hasMessenger: true, isTheirs: false)))
    }

    func testNothingConnectedProposesNothing() {
        XCTAssertNil(ActionVerb.suggested(for: .init()))
        XCTAssertNil(ActionVerb.suggested(for: .init(hasCalendar: true, hasCRM: true, isTheirs: true)))
    }

    func testARememberedVerbWinsOnlyWhileItCanBeCarried() {
        XCTAssertEqual(ActionVerb.suggested(for: .init(hasTracker: true, hasMessenger: true, remembered: .message)), .message)
        XCTAssertEqual(ActionVerb.suggested(for: .init(hasTracker: true, remembered: .message)), .task)
    }

    // MARK: - Memory

    func testTheThirdHandPickBecomesTheDefault() {
        let memory = VerbMemory(defaults: defaults)
        XCTAssertFalse(memory.note(.message, for: .theirs))
        XCTAssertFalse(memory.note(.message, for: .theirs))
        XCTAssertNil(memory.remembered(for: .theirs))
        XCTAssertTrue(memory.note(.message, for: .theirs))
        XCTAssertEqual(memory.remembered(for: .theirs), .message)
        XCTAssertNil(memory.remembered(for: .action))
    }

    func testMemoryFollowsTheMostPickedVerb() {
        let memory = VerbMemory(defaults: defaults)
        for _ in 0 ..< 3 {
            memory.note(.message, for: .action)
        }
        for _ in 0 ..< 4 {
            memory.note(.note, for: .action)
        }
        XCTAssertEqual(memory.remembered(for: .action), .note)
        memory.forget()
        XCTAssertNil(memory.remembered(for: .action))
    }

    // MARK: - Defaults per capability

    @MainActor func testADefaultProductIsRememberedPerCapability() {
        let service = IntegrationService(supabase: nil, defaults: defaults)
        service.setDefault(.jira, for: .tasks)
        XCTAssertEqual(IntegrationService(supabase: nil, defaults: defaults).defaultProducts[.tasks], .jira)
        service.setDefault(nil, for: .tasks)
        XCTAssertNil(IntegrationService(supabase: nil, defaults: defaults).defaultProducts[.tasks])
    }

    // MARK: - Drafting by verb

    func testANonTaskVerbDraftsAReviewRowWithTheWordsOnly() {
        let item = ActionItem.new(
            meetingID: UUID(),
            userID: UUID(),
            text: "Ping Sofia about the copy",
            deadline: "Friday",
            position: 0,
            kind: .theirs
        )
        let drafts = ProposalDrafting.drafts(for: [item], owners: [0: "Sofia"], provider: .slack, verb: .message, directory: [])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].type, "slack.post_message")
        XCTAssertEqual(drafts[0].status, .needsReview)
        XCTAssertEqual(drafts[0].parameters, ["title": "Ping Sofia about the copy", "assignee_hint": "Sofia"])
    }

    func testAVerbTheProductCannotCarryDraftsNothing() {
        let item = ActionItem.new(meetingID: UUID(), userID: UUID(), text: "x", deadline: nil, position: 0)
        XCTAssertTrue(ProposalDrafting.drafts(for: [item], owners: [:], provider: .hubspot, verb: .task, directory: []).isEmpty)
    }
}
