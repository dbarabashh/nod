import XCTest
@testable import Nod

/// Nod has no Slack feature and no Linear feature. It has "file this work
/// somewhere" and "talk about this somewhere", and which product serves either
/// is the organization's choice — Linear or Jira, Slack or Teams or Telegram.
///
/// These pin the join between the two halves. The failure they exist to catch is
/// quiet: a provider added with actions but no capability is connectable,
/// appears in Settings, and is never once offered by the thing that would use
/// it — with nothing failing anywhere to say so.
final class IntegrationCapabilityTests: XCTestCase {
    func testEveryProviderServesSomething() {
        for provider in IntegrationProvider.allCases {
            XCTAssertFalse(
                provider.capabilities.isEmpty,
                "\(provider.rawValue) serves no capability, so nothing will ever reach for it"
            )
        }
    }

    func testActionsAndCapabilitiesAgree() {
        for provider in IntegrationProvider.allCases {
            XCTAssertEqual(
                provider.taskActions != nil,
                provider.capabilities.contains(.tasks),
                "\(provider.rawValue) disagrees with itself about being a task tracker"
            )
            XCTAssertEqual(
                provider.conversationActions != nil,
                provider.capabilities.contains(.conversations),
                "\(provider.rawValue) disagrees with itself about being a team chat"
            )
        }
    }

    /// A capability nothing serves is a promise the product cannot keep, so each
    /// one has at least one adapter behind it.
    func testEveryCapabilityHasAProviderBehindIt() {
        for capability in IntegrationCapability.allCases {
            XCTAssertFalse(
                IntegrationProvider.all(serving: capability).isEmpty,
                "nothing serves \(capability.rawValue)"
            )
        }
    }

    /// The order decides which product a finalize files into when somebody has
    /// connected two, so it must not depend on the order a `Set` happened to
    /// iterate in this run.
    func testTheChoiceBetweenTwoProvidersIsStable() {
        let first = IntegrationProvider.all(serving: .tasks)
        for _ in 0 ..< 20 {
            XCTAssertEqual(IntegrationProvider.all(serving: .tasks), first)
        }
    }

    /// A provider Nod only reads from must never be offered as somewhere to put
    /// something — the calendar is not a task tracker, however much a model
    /// might like it to be.
    func testReadOnlyProvidersAreNotSomewhereToActInAsTasks() {
        for provider in IntegrationProvider.all(.readsFrom) {
            XCTAssertNil(provider.taskActions, "\(provider.rawValue) is read-only")
            XCTAssertNil(provider.conversationActions, "\(provider.rawValue) is read-only")
        }
    }

    /// `type` on a proposal is `provider.action`, split on the first dot by both
    /// the executor and the app. A provider whose raw value contained one would
    /// make every proposal for it undispatchable.
    func testProviderNamesCanBeSplitOffAProposalType() {
        for provider in IntegrationProvider.allCases {
            XCTAssertFalse(
                provider.rawValue.contains("."),
                "\(provider.rawValue) cannot be the first half of a proposal type"
            )
            let proposal = ActionProposal(
                id: UUID(),
                userID: UUID(),
                meetingID: nil,
                actionItemID: nil,
                type: "\(provider.rawValue).do_something",
                status: .ready,
                parameters: [:],
                confidence: nil,
                confidenceParts: nil,
                evidenceIdx: nil,
                createdAt: nil
            )
            XCTAssertEqual(proposal.provider, provider)
            XCTAssertEqual(proposal.action, "do_something")
        }
    }
}
