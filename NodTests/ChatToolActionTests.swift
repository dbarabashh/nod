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
