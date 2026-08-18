import XCTest
@testable import Nod

/// `ChatTool.action` is the tool name with `provider.rawValue` cut off the
/// front, so the two have to agree on the separator. They nearly did not: the
/// calendar's raw value is `google-calendar`, and a tool named
/// `google_calendar_create_event` produced the action `reate_event` — a name the
/// server has no handler for, failing at the moment a person pressed the confirm
/// button rather than at build time.
final class ChatToolActionTests: XCTestCase {
    func testEveryAdvertisedToolNamesAnActionTheServerCanDispatch() {
        for provider in IntegrationProvider.allCases {
            for tool in ChatTools.definitions(for: [provider]) {
                XCTAssertTrue(
                    tool.name.hasPrefix(provider.rawValue + "_"),
                    "\(tool.name) must start with \(provider.rawValue)_ or its action is cut wrong"
                )
                XCTAssertFalse(tool.action.isEmpty, "\(tool.name) derived an empty action")
                XCTAssertFalse(
                    tool.action.contains(provider.rawValue),
                    "\(tool.name) kept its prefix in the action \(tool.action)"
                )
            }
        }
    }

    /// Reading a channel is not a write, and the model is told so — but every
    /// call still stops at the approval card, which is what `mutating` does not
    /// decide. What it does decide is how the card reads, and a read presented
    /// as a change is how somebody learns to click through them.
    func testSlackReadsAreNotAdvertisedAsChanges() {
        let tools = ChatTools.definitions(for: [.slack])
        let byAction = Dictionary(uniqueKeysWithValues: tools.map { ($0.action, $0) })

        XCTAssertEqual(byAction["list_channels"]?.mutating, false)
        XCTAssertEqual(byAction["read_channel"]?.mutating, false)
        XCTAssertEqual(byAction["read_thread"]?.mutating, false)
        XCTAssertEqual(byAction["create_channel"]?.mutating, true)
    }

    func testCalendarReadsWithoutApprovalAndWritesWithIt() {
        let tools = ChatTools.definitions(for: [.googleCalendar])
        XCTAssertEqual(Set(tools.map(\.action)), ["list_events", "create_event"])
        // Reading back the user's own calendar needs no confirmation. Creating an
        // event does: `sendUpdates=all` puts mail in other people's inboxes and
        // an entry in their calendars, and neither can be recalled.
        XCTAssertEqual(tools.first { $0.action == "list_events" }?.mutating, false)
        XCTAssertEqual(tools.first { $0.action == "create_event" }?.mutating, true)
    }
}
