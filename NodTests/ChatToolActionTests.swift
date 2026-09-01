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
        XCTAssertEqual(
            Set(tools.map(\.action)),
            ["list_events", "check_availability", "create_event", "update_event", "delete_event"]
        )
        // Reading back the user's own calendar needs no confirmation. Every
        // write does: `sendUpdates=all` puts mail in other people's inboxes and
        // changes their calendars, and none of it can be recalled. `mutating`
        // is also what keeps these off the unattended chat and outside "always
        // allow", so a write mislabelled here would run without a card.
        XCTAssertEqual(tools.first { $0.action == "list_events" }?.mutating, false)
        XCTAssertEqual(tools.first { $0.action == "check_availability" }?.mutating, false)
        XCTAssertEqual(tools.first { $0.action == "create_event" }?.mutating, true)
        XCTAssertEqual(tools.first { $0.action == "update_event" }?.mutating, true)
        XCTAssertEqual(tools.first { $0.action == "delete_event" }?.mutating, true)
    }

    /// The complete write surface, every provider — `mutating` is what keeps a
    /// tool behind the approval card, off the unattended chat, and outside
    /// "always allow", so a write mislabelled here runs without a card. Google
    /// Ads and Drive are empty on purpose: money moving per hour, and a
    /// document store Nod only ever reads.
    func testEveryWriteIsMarkedMutating() {
        let writes: [IntegrationProvider: Set<String>] = [
            // Linear's chat catalogue stops at filing; closing an issue rides
            // the action-item tick (`taskActions`), not a chat tool.
            .linear: ["create_issue"],
            .jira: ["create_issue", "update_issue"],
            .asana: ["create_task", "update_task"],
            .slack: ["create_channel", "invite_users", "post_message"],
            .googleCalendar: ["create_event", "update_event", "delete_event"],
            .github: ["create_issue", "comment_issue", "update_issue"],
            .notion: ["create_page", "append_page"],
            .hubspot: ["create_note"],
            .gmail: ["create_draft"],
            .googleDrive: [],
            .googleAds: []
        ]
        XCTAssertEqual(Set(writes.keys), Set(IntegrationProvider.allCases), "a provider is missing from the map")
        for (provider, actions) in writes {
            let tools = ChatTools.definitions(for: [provider])
            for tool in tools {
                XCTAssertEqual(
                    tool.mutating, actions.contains(tool.action),
                    "\(tool.name) has the wrong mutating flag"
                )
            }
            XCTAssertEqual(Set(tools.filter(\.mutating).map(\.action)), actions)
        }
    }

    /// The card names the target by the tool's first required parameter, and
    /// the server verifies that same name against the live record. If a raw id
    /// ever became first, the person would be approving a UUID.
    func testDestructiveCalendarCardsLeadWithTheTitle() {
        let tools = ChatTools.definitions(for: [.googleCalendar])
        XCTAssertEqual(tools.first { $0.action == "update_event" }?.primaryParameter, "event_title")
        XCTAssertEqual(tools.first { $0.action == "delete_event" }?.primaryParameter, "event_title")
        let notion = ChatTools.definitions(for: [.notion])
        XCTAssertEqual(notion.first { $0.action == "append_page" }?.primaryParameter, "page_title")
        XCTAssertEqual(notion.first { $0.action == "create_page" }?.parameters.required[1], "parent_page_title")
        let hubspot = ChatTools.definitions(for: [.hubspot])
        XCTAssertEqual(hubspot.first { $0.action == "create_note" }?.primaryParameter, "record_name")
    }

    /// A mutating card lists what the call actually changes, not just which
    /// event it touches: required parameters in schema order, then the rest
    /// alphabetically, the primary and anything unsent left out.
    func testUpdateCardShowsTheChangeBeingApproved() throws {
        let tool = try XCTUnwrap(
            ChatTools.definitions(for: [.googleCalendar]).first { $0.action == "update_event" }
        )
        let call = ChatToolCall(
            id: "1",
            type: "function",
            function: .init(name: tool.name, arguments: [
                "{\"event_title\": \"Standup\", \"event_id\": \"abc\",",
                "\"event_starts_at\": \"2026-09-03T10:00:00Z\",",
                "\"starts_at\": \"2026-09-03T11:00:00Z\", \"ends_at\": \"2026-09-03T11:30:00Z\",",
                "\"remove_attendees\": \"vlad@x.com\"}"
            ].joined(separator: " "))
        )
        XCTAssertEqual(call.recognisableArgument(for: tool), "Standup")
        XCTAssertEqual(call.detailArguments(for: tool).map(\.name), [
            "event id", "event starts at", "ends at", "remove attendees", "starts at"
        ])
        XCTAssertEqual(
            call.detailArguments(for: tool).first { $0.name == "remove attendees" }?.value,
            "vlad@x.com"
        )
    }
}
