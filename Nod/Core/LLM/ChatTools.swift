import Foundation

/// One tool the chat model may ask for.
struct ChatTool: Equatable {
    let provider: IntegrationProvider
    /// The name the model uses. Prefixed with the provider so two integrations
    /// can both expose `search` without colliding.
    let name: String
    let description: String
    let parameters: ChatToolSchema
    /// Whether running this changes something in the user's account. Every call
    /// is confirmed regardless — this only decides how the confirmation reads.
    let mutating: Bool

    /// The action name `integration-action` dispatches on, i.e. the tool name
    /// without its provider prefix.
    var action: String {
        String(name.dropFirst(provider.rawValue.count + 1))
    }

    /// The parameter that identifies a call to a person: a tool's first required
    /// argument is the one it is named for. Taken from the schema rather than a
    /// list of known parameter names, so a provider whose primary argument is
    /// `page_title` reads correctly without anyone editing a call site.
    var primaryParameter: String? {
        parameters.required.first
    }

    /// "Searched", "Created in" — derived from the action so the approval card
    /// and the trace can't develop two vocabularies for the same call.
    var verb: String {
        ChatTool.verb(for: action)
    }

    static func verb(for action: String) -> String {
        switch action.split(separator: "_").first.map(String.init) {
        case "search": "Searched"
        case "create": "Created in"
        case "list": "Listed from"
        case "update": "Updated in"
        case "read": "Read from"
        default: "Used"
        }
    }
}

/// A deliberately small JSON Schema: object, string properties, required list.
/// Anything richer would cost tokens in the prefix without buying accuracy —
/// providers validate the real shape server-side anyway.
struct ChatToolSchema: Equatable, Encodable {
    struct Property: Equatable, Encodable {
        let type = "string"
        let description: String
    }

    let type = "object"
    let properties: [String: Property]
    let required: [String]
    let additionalProperties = false
}

/// One tool call the model asked for. Decoded from the provider's response and
/// re-encoded verbatim into the follow-up request.
struct ChatToolCall: Equatable, Identifiable, Codable {
    struct Function: Equatable, Codable {
        let name: String
        /// A JSON object, as a string — that is the wire format, not a choice.
        let arguments: String
    }

    let id: String
    let type: String
    let function: Function

    var name: String {
        function.name
    }

    /// What this call was, in the user's words — the value of the tool's primary
    /// parameter. Empty when the call carried nothing recognisable.
    func recognisableArgument(for tool: ChatTool) -> String {
        tool.primaryParameter.flatMap { arguments[$0] } ?? ""
    }

    /// The arguments as a dictionary of strings. A model that emits a number or
    /// a bool still yields a usable value; anything nested is dropped, which is
    /// why the schema only advertises strings.
    var arguments: [String: String] {
        ToolArguments.decode(function.arguments)
    }
}

/// What a model may put in a tool argument, flattened to what the wire carries.
///
/// One definition rather than one per caller. The chat and the meeting lookup
/// both decode a model's argument object, and while they each had their own the
/// two disagreed: bridging a JSON `true` through `NSNumber` yields `"1"`, which
/// every adapter's `requireBoolean` rejects, so asking the chat for a private
/// Slack channel quietly made a public one.
enum ToolArguments {
    /// A JSON object as a string — the wire format — read into strings.
    static func decode(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.compactMapValues(scalar)
    }

    /// One value, or nil for anything a tool argument cannot carry.
    ///
    /// `nil` for null as well as for objects and arrays: an argument the model
    /// chose to leave out must not reach a provider as the four-letter string,
    /// and a nested value's description is worse than its absence.
    static func scalar(_ value: Any) -> String? {
        switch value {
        case let string as String: string
        // Asked by exact type rather than with `as? Bool`, which is true for
        // any NSNumber representable as one — `"limit": 1` would arrive as
        // "true". JSONSerialization gives booleans a CFBoolean and nothing
        // else, so this is the only reading that separates the two.
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): String(number.boolValue)
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

/// Wire shape for a tool definition (OpenAI-compatible, which is what
/// OpenRouter speaks).
struct ChatToolPayload: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: ChatToolSchema
    }

    let type = "function"
    let function: Function

    init(_ tool: ChatTool) {
        function = Function(name: tool.name, description: tool.description, parameters: tool.parameters)
    }
}

/// Which tools the model is offered, and in what order.
///
/// Both matter for cost. Tool definitions sit in the cached prompt prefix, so
/// they are billed once per cache window — but any change to the array rewrites
/// the cache. Hence: only providers the user actually connected contribute, and
/// the result is sorted, so the same set of connections always produces the same
/// bytes. A user with Linear alone never pays for Notion's vocabulary.
enum ChatTools {
    static func definitions(for connected: Set<IntegrationProvider>) -> [ChatTool] {
        connected
            .sorted { $0.rawValue < $1.rawValue }
            .flatMap(tools(for:))
    }

    private static func tools(for provider: IntegrationProvider) -> [ChatTool] {
        switch provider {
        case .linear: linearTools
        case .googleCalendar: calendarTools
        case .slack: slackTools
        case .github: githubTools
        case .jira: jiraTools
        case .notion: notionTools
        case .asana: asanaTools
        case .hubspot: hubspotTools
        case .gmail: gmailTools
        case .googleDrive: driveTools
        case .googleAds: adsTools
        }
    }

    private static let asanaTools: [ChatTool] = [
        ChatTool(
            provider: .asana,
            name: "asana_search_tasks",
            description: "Search the user's Asana tasks. On a free workspace Asana forbids searching, and this falls back to their own open tasks — the reply says which it did.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Keywords to search for.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .asana,
            name: "asana_create_task",
            description: "File a new Asana task, assigned to the user. Only after searching, and only when they asked for it.",
            parameters: ChatToolSchema(
                properties: [
                    "title": .init(description: "One line, in the meeting's own wording."),
                    "notes": .init(description: "Optional detail.")
                ],
                required: ["title"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .asana,
            name: "asana_update_task",
            description: "Complete or reopen an Asana task.",
            parameters: ChatToolSchema(
                properties: [
                    "id": .init(description: "Task id from a search result."),
                    "completed": .init(description: "`true` to complete, `false` to reopen.")
                ],
                required: ["id", "completed"]
            ),
            mutating: true
        )
    ]

    private static let hubspotTools: [ChatTool] = [
        ChatTool(
            provider: .hubspot,
            name: "hubspot_find_company",
            description: "Look up a company in the CRM. Use before saying whether the team has dealt with them.",
            parameters: ChatToolSchema(
                properties: ["name": .init(description: "Company name or domain.")],
                required: ["name"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .hubspot,
            name: "hubspot_find_contact",
            description: "Look up a person in the CRM by name or email.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Name or email address.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .hubspot,
            name: "hubspot_find_deals",
            description: "Find deals by name. `stage` comes back as the pipeline's own id, not a label.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Deal or company name.")],
                required: ["query"]
            ),
            mutating: false
        )
    ]

    private static let gmailTools: [ChatTool] = [
        ChatTool(
            provider: .gmail,
            name: "gmail_search_messages",
            description: "Search the user's mail. Accepts Gmail syntax (from:, subject:, newer_than:7d). Returns subjects and previews, not full text.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Gmail search query.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .gmail,
            name: "gmail_read_message",
            description: "Read one message in full. Use after a search, when the preview does not answer the question.",
            parameters: ChatToolSchema(
                properties: ["message_id": .init(description: "Message id from a search result.")],
                required: ["message_id"]
            ),
            mutating: false
        )
    ]

    private static let driveTools: [ChatTool] = [
        ChatTool(
            provider: .googleDrive,
            name: "google-drive_search_files",
            description: "Find a document in Drive by name or contents, including shared drives. Returns links, not the documents' text.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Words in the file's name or body.")],
                required: ["query"]
            ),
            mutating: false
        )
    ]

    /// Reading spend, and only that.
    ///
    /// Nothing here writes, and nothing here should: a bid, a budget and a
    /// campaign's status are money moving per hour, and an approval card is a
    /// thin thing to put between a model and somebody's ad account.
    private static let adsTools: [ChatTool] = [
        ChatTool(
            provider: .googleAds,
            name: "google-ads_list_accounts",
            description: "List the ad accounts this login can see. Call first — the other ads tools need the `account` value this returns, and it is not something the user says out loud.",
            parameters: ChatToolSchema(properties: [:], required: []),
            mutating: false
        ),
        ChatTool(
            provider: .googleAds,
            name: "google-ads_campaign_performance",
            description: "What an ad account spent over a window and what it got back, with the biggest-spending campaigns. Use for any question about ad results or budget.",
            parameters: ChatToolSchema(
                properties: [
                    "account": .init(description: "The `account` value from google-ads_list_accounts."),
                    "range": .init(
                        description: "TODAY, YESTERDAY, LAST_7_DAYS, LAST_14_DAYS, LAST_30_DAYS, THIS_MONTH or LAST_MONTH. Defaults to LAST_30_DAYS."
                    )
                ],
                required: ["account"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .googleAds,
            name: "google-ads_keyword_performance",
            description: "The keywords that spent the most over a window. Use when the question is which words the money went to, not how the account did overall.",
            parameters: ChatToolSchema(
                properties: [
                    "account": .init(description: "The `account` value from google-ads_list_accounts."),
                    "range": .init(
                        description: "TODAY, YESTERDAY, LAST_7_DAYS, LAST_14_DAYS, LAST_30_DAYS, THIS_MONTH or LAST_MONTH. Defaults to LAST_30_DAYS."
                    )
                ],
                required: ["account"]
            ),
            mutating: false
        )
    ]

    private static let jiraTools: [ChatTool] = [
        ChatTool(
            provider: .jira,
            name: "jira_search_issues",
            description: "Search the user's Jira issues by keyword. Use before claiming a task does or doesn't exist.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Keywords to search for.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .jira,
            name: "jira_create_issue",
            description: "File a new Jira issue. Only after searching, and only when the user asked for it.",
            parameters: ChatToolSchema(
                properties: [
                    "project": .init(description: "Project key, e.g. `NOD`."),
                    "title": .init(description: "One line, in the meeting's own wording."),
                    "description": .init(description: "Optional detail.")
                ],
                required: ["project", "title"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .jira,
            name: "jira_update_issue",
            description: "Close or reopen a Jira issue. Reopening lands it in the workflow's first open state, not the one it left.",
            parameters: ChatToolSchema(
                properties: [
                    "key": .init(description: "Issue key, e.g. `NOD-31`."),
                    "closed": .init(description: "`true` to close, `false` to reopen.")
                ],
                required: ["key", "closed"]
            ),
            mutating: true
        )
    ]

    private static let notionTools: [ChatTool] = [
        ChatTool(
            provider: .notion,
            name: "notion_search_pages",
            description: "Search the user's Notion pages. Matches page titles, not their contents — search for what a page is called.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Words likely to be in the page's title.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .notion,
            name: "notion_read_page",
            description: "Read one Notion page's text. Use after a search, to quote what was written rather than guess.",
            parameters: ChatToolSchema(
                properties: ["page_id": .init(description: "The page id from a search result.")],
                required: ["page_id"]
            ),
            mutating: false
        )
    ]

    private static let githubTools: [ChatTool] = [
        ChatTool(
            provider: .github,
            name: "github_search_issues",
            description: """
            Search GitHub issues and pull requests, in GitHub's own search syntax. Use before claiming \
            something is or isn't tracked. A question about the user's own work — "my open PRs", "what am \
            I reviewing" — must be scoped with author:@me, assignee:@me or review-requested:@me, and a \
            question about one project with repo:owner/name. An unscoped query searches all of GitHub and \
            comes back with strangers' work.
            """,
            parameters: ChatToolSchema(
                properties: [
                    "query": .init(description: "GitHub search query, e.g. `is:pr is:open author:@me` or `repo:acme/api is:open auth`.")
                ],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .github,
            name: "github_read_issue",
            description: "Read one issue or pull request in full, with its last comments. Use when a specific one is named and its state or discussion matters.",
            parameters: ChatToolSchema(
                properties: ["reference": .init(description: "owner/repo#123")],
                required: ["reference"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .github,
            name: "github_list_repositories",
            description: "List the repositories this account works in. Use to turn a spoken name like \"the api repo\" into one a search can filter on.",
            parameters: ChatToolSchema(properties: [:], required: []),
            mutating: false
        )
    ]

    // Descriptions are terse on purpose: they live in the prefix of every chat
    // this user ever has. One sentence of intent plus when NOT to use it beats a
    // paragraph of politeness.
    private static let linearTools: [ChatTool] = [
        ChatTool(
            provider: .linear,
            name: "linear_search_issues",
            description: "Search the user's Linear issues by keyword. Use before claiming a task does or doesn't exist.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Keywords to search for.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .linear,
            name: "linear_create_issue",
            description: "Create a Linear issue. Search first so you don't file a duplicate.",
            parameters: ChatToolSchema(
                properties: [
                    "title": .init(description: "Short imperative title."),
                    "description": .init(description: "Optional detail, markdown."),
                    "teamId": .init(description: "Only when the workspace has several teams.")
                ],
                required: ["title"]
            ),
            mutating: true
        )
    ]

    /// Opening a channel, and nothing else.
    ///
    /// No posting. A message sent under somebody's own account is indelible and
    /// reads as them saying it, which is a different kind of act from creating a
    /// place for a conversation — and it is not one a meeting needs.
    ///
    /// Guests are named by address rather than by Slack id, exactly as the
    /// calendar's invitations are: the model has the organization's directory in
    /// its prompt and no way to learn a Slack id, and the server turns one into
    /// the other where it can be checked.
    private static let slackTools: [ChatTool] = [
        ChatTool(
            provider: .slack,
            name: "slack_list_channels",
            description: """
            List the Slack channels Nod can reach — every public one, plus private ones it was invited to. \
            Use to find a channel's id before reading it; the user names channels by topic, not by id. \
            This matches channel names and topics only, never message text or people — searching for what \
            somebody said is slack_search_messages.
            """,
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Optional words to narrow the list, e.g. pricing.")],
                required: []
            ),
            mutating: false
        ),
        ChatTool(
            provider: .slack,
            name: "slack_search_messages",
            description: """
            Search Slack for what somebody said, across every conversation at once. Use this first for any \
            question naming a person, a day or a phrase rather than a channel — "what did Vlad send today", \
            "did anyone mention the invoice". Covers every channel the user is in, private ones included, \
            without needing the channel named first. Direct messages are never searched. Give whichever \
            filters the question supports; at least one is required.
            """,
            parameters: ChatToolSchema(
                properties: [
                    "text": .init(description: "Words to look for in the message. Omit when the question is only about who or when."),
                    "from": .init(description: "Who sent it — a first name, full name, @handle or email. Resolved against the workspace."),
                    "in": .init(description: "Restrict to one channel by name, e.g. pricing."),
                    "on": .init(description: "A single day, as 2026-08-26."),
                    "after": .init(description: "Only messages after this day, as 2026-08-26."),
                    "before": .init(description: "Only messages before this day, as 2026-08-26.")
                ],
                required: []
            ),
            mutating: false
        ),
        ChatTool(
            provider: .slack,
            name: "slack_read_channel",
            description: """
            Read recent messages in one Slack channel, newest first. Needs a channel id from \
            slack_list_channels. Replies to the most recently discussed messages come back with them, \
            under `thread_messages`, so a question whose answer is inside a thread is answered from this \
            one call. Nod joins a public channel it isn't in yet, which the channel sees — so read the one \
            that was asked about, not every one that might mention it.
            """,
            parameters: ChatToolSchema(
                properties: [
                    "channel": .init(description: "Channel id from slack_list_channels."),
                    "limit": .init(description: "How many recent messages, 1-200. Default 50.")
                ],
                required: ["channel"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .slack,
            name: "slack_read_thread",
            description: """
            Read one thread's replies in full. slack_read_channel already returns the replies to the \
            messages discussed most recently, so use this only for an older thread it did not carry, or \
            when more replies are needed than it returned.
            """,
            parameters: ChatToolSchema(
                properties: [
                    "channel": .init(description: "Channel id the thread is in."),
                    "thread": .init(description: "The thread id reported by slack_read_channel.")
                ],
                required: ["channel", "thread"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .slack,
            name: "slack_invite_users",
            description: """
            Add people to a Slack channel that already exists. Needs the channel id from \
            slack_list_channels; name the people however the request did, by first name or address, and \
            they are matched against the workspace. A name that matches nobody fails rather than being \
            quietly dropped.
            """,
            parameters: ChatToolSchema(
                properties: [
                    "channel_id": .init(description: "Channel id from slack_list_channels."),
                    "invite_people": .init(
                        description: "Comma-separated people, by first name, full name, @handle or email — whichever the request gave."
                    )
                ],
                required: ["channel_id", "invite_people"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .slack,
            name: "slack_create_channel",
            description: "Create a Slack channel and optionally invite people by email. Use when the user asks for a place to discuss something.",
            parameters: ChatToolSchema(
                properties: [
                    "channel_name": .init(description: "Short kebab-case name, e.g. auth-migration."),
                    "invite_people": .init(
                        description: "Comma-separated people to add, by first name, full name, @handle or email. Omit to create it empty."
                    ),
                    "is_private": .init(description: "\"true\" for a private channel. Defaults to public.")
                ],
                required: ["channel_name"]
            ),
            mutating: true
        )
    ]

    /// Read and write. The read exists alongside the scheduled sync rather than
    /// instead of it: the sync keeps a rolling week on the device, which is what
    /// answers "anything today" with no round trip, and this reaches past that
    /// window for a date the device has never held.
    ///
    /// `mutating` marks the write so its confirmation reads as one — the person
    /// sees the date and the guest list before an invitation reaches anyone's
    /// inbox. Both still stop at `ToolApprovalCard`; nothing leaves Nod
    /// unapproved, and the flag only decides how the card is worded.
    private static let calendarTools: [ChatTool] = [
        ChatTool(
            provider: .googleCalendar,
            name: "google-calendar_list_events",
            description: [
                "Read the user's calendar over a date range.",
                "Use it for any question about what they have scheduled beyond the coming week;",
                "nearer days are already in the prompt.",
                "Results cover the whole window asked for, so a window that opens before the current time",
                "comes back holding events that already finished —",
                "check each one's end time against the clock before calling it upcoming."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "starts_at": .init(description: "RFC3339 start of the window, e.g. 2026-09-01T00:00:00+01:00."),
                    "ends_at": .init(description: "RFC3339 end of the window.")
                ],
                required: ["starts_at", "ends_at"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .googleCalendar,
            // Hyphen, not underscore: `action` is this string minus
            // `provider.rawValue`, and the raw value is `google-calendar`.
            name: "google-calendar_create_event",
            description: "Create a calendar event and invite people. Times must be absolute, in the user's timezone. Ask for a missing date or guest rather than guessing one.",
            parameters: ChatToolSchema(
                properties: [
                    "title": .init(description: "What the meeting is called."),
                    "starts_at": .init(description: "RFC3339 start, e.g. 2026-08-18T15:00:00+01:00."),
                    "ends_at": .init(description: "RFC3339 end. Default to one hour after the start."),
                    "attendees": .init(description: "Comma-separated email addresses to invite. Omit for a private hold."),
                    "description": .init(description: "Optional agenda or context.")
                ],
                required: ["title", "starts_at", "ends_at"]
            ),
            mutating: true
        )
    ]
}
