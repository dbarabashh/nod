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
        case "delete": "Cancelled in"
        case "comment": "Commented in"
        case "append": "Added to"
        case "post": "Posted to"
        case "invite": "Invited to"
        case "find": "Searched"
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

    /// Everything this call carries beyond its primary parameter, for the
    /// approval card of a write. A person shown only "Updated in / Standup" is
    /// approving a change they cannot evaluate — the new time, the guest being
    /// removed — so a mutating card lists every argument. Required parameters
    /// come first in the schema's own order, the rest alphabetically, so the
    /// same call always reads the same way.
    func detailArguments(for tool: ChatTool) -> [(name: String, value: String)] {
        let sent = arguments
        let required = tool.parameters.required.filter { $0 != tool.primaryParameter }
        let optional = sent.keys
            .filter { !tool.parameters.required.contains($0) && $0 != tool.primaryParameter }
            .sorted()
        return (required + optional).compactMap { key in
            guard let value = sent[key], !value.isEmpty else { return nil }
            return (name: key.replacingOccurrences(of: "_", with: " "), value: value)
        }
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
        case .googleTasks: googleTasksTools
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

    private static let googleTasksTools: [ChatTool] = [
        ChatTool(
            provider: .googleTasks,
            name: "google-tasks_search_tasks",
            description: "Search the user's Google Tasks, in their default list, by words in the title or notes.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Keywords to search for.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .googleTasks,
            name: "google-tasks_read_tasks",
            description: "Read whether the given Google Tasks are still open.",
            parameters: ChatToolSchema(
                properties: ["keys": .init(description: "Comma-separated task ids from a search result.")],
                required: ["keys"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .googleTasks,
            name: "google-tasks_create_task",
            description: "File a new task in the user's default Google Tasks list. Only after searching, and only when they asked for it. A due date is a day, not a time.",
            parameters: ChatToolSchema(
                properties: [
                    "title": .init(description: "One line, in the meeting's own wording."),
                    "notes": .init(description: "Optional detail."),
                    "due": .init(description: "Optional due date, RFC 3339; only the date part is kept.")
                ],
                required: ["title"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .googleTasks,
            name: "google-tasks_update_task",
            description: "Retitle, annotate, re-date, complete or reopen a Google Task. A due date is a day, not a time.",
            parameters: ChatToolSchema(
                properties: [
                    "key": .init(description: "Task id from a search result."),
                    "title": .init(description: "New title, if it changes."),
                    "notes": .init(description: "New notes, if they change."),
                    "due": .init(description: "New due date, RFC 3339; only the date part is kept."),
                    "status": .init(description: "`completed` to complete, `needsAction` to reopen.")
                ],
                required: ["key"]
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
        ),
        ChatTool(
            provider: .hubspot,
            name: "hubspot_create_note",
            description: [
                "Log a note on a company, contact or deal — a meeting summary, a call outcome.",
                "It only adds context; nothing about the record changes.",
                "Only after a find: the server refuses a record id whose name doesn't match record_name."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "record_name": .init(description: "The record's name, exactly as the find result showed it."),
                    "attach_to": .init(description: "One of contact, company, deal."),
                    "record_id": .init(description: "The record's id from a find result."),
                    "body": .init(description: "The note's text.")
                ],
                required: ["record_name", "attach_to", "record_id", "body"]
            ),
            mutating: true
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
        ),
        ChatTool(
            provider: .gmail,
            name: "gmail_create_draft",
            description: [
                "Save a draft in the user's Gmail. Nothing is sent — the user reviews and sends it themselves,",
                "so tell them the draft is waiting in their Drafts folder.",
                "For a reply, pass the thread_id from search or read results and keep the original subject, prefixed Re:."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "subject": .init(description: "The subject line."),
                    "to": .init(description: "Comma-separated recipient emails."),
                    "body": .init(description: "The message text."),
                    "cc": .init(description: "Optional comma-separated cc emails."),
                    "thread_id": .init(description: "Optional thread to reply in, from search/read results.")
                ],
                required: ["subject", "to", "body"]
            ),
            mutating: true
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
        ),
        ChatTool(
            provider: .googleDrive,
            name: "google-drive_read_file",
            description: "Read a Drive file's text — docs, sheets, slides, and plain text files. Use after a search, to answer from the document rather than its name.",
            parameters: ChatToolSchema(
                properties: ["file_id": .init(description: "The file id from a search result.")],
                required: ["file_id"]
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
            description: "Search the user's Jira issues by keyword. Returns titles and states only — call jira_read_issue for the description and comments of the one that matters. Use before claiming a task does or doesn't exist.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Keywords to search for.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .jira,
            name: "jira_read_issue",
            description: "Read one Jira issue in full: description, status, assignee, priority, labels and its last comments. Use when a specific issue is named or was found by search and the user wants what it says.",
            parameters: ChatToolSchema(
                properties: ["key": .init(description: "The issue key, e.g. NOD-138.")],
                required: ["key"]
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
        ),
        ChatTool(
            provider: .notion,
            name: "notion_create_page",
            description: [
                "Create a Notion page under an existing one. Only when the user asked for it;",
                "find the parent with search_pages first — the server refuses a parent id whose title",
                "doesn't match parent_page_title."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "title": .init(description: "The new page's title."),
                    "parent_page_title": .init(description: "The parent's title, exactly as search_pages returned it."),
                    "parent_page_id": .init(description: "The parent's id from search_pages."),
                    "content": .init(description: "The page's text. Plain paragraphs, one per line.")
                ],
                required: ["title", "parent_page_title", "parent_page_id", "content"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .notion,
            name: "notion_append_page",
            description: [
                "Add paragraphs to the end of an existing Notion page. Nothing already on the page changes.",
                "Only after search_pages: the server refuses a page id whose title doesn't match page_title."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "page_title": .init(description: "The page's title, exactly as search_pages returned it."),
                    "page_id": .init(description: "The page's id from search_pages."),
                    "content": .init(description: "The text to add. Plain paragraphs, one per line.")
                ],
                required: ["page_title", "page_id", "content"]
            ),
            mutating: true
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
        ),
        ChatTool(
            provider: .github,
            name: "github_create_issue",
            description: "File a GitHub issue. Only after searching, and only when the user asked for it.",
            parameters: ChatToolSchema(
                properties: [
                    "title": .init(description: "One line, in the meeting's own wording."),
                    "repository": .init(description: "owner/repo, from list_repositories or a search result."),
                    "body": .init(description: "Optional detail.")
                ],
                required: ["title", "repository"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .github,
            name: "github_comment_issue",
            description: "Comment on an issue or pull request, in the user's words.",
            parameters: ChatToolSchema(
                properties: [
                    "reference": .init(description: "owner/repo#123"),
                    "body": .init(description: "The comment.")
                ],
                required: ["reference", "body"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .github,
            name: "github_update_issue",
            description: "Close or reopen a GitHub issue. Nothing else about it changes.",
            parameters: ChatToolSchema(
                properties: [
                    "reference": .init(description: "owner/repo#123"),
                    "closed": .init(description: "`true` to close, `false` to reopen.")
                ],
                required: ["reference", "closed"]
            ),
            mutating: true
        )
    ]

    // Descriptions are terse on purpose: they live in the prefix of every chat
    // this user ever has. One sentence of intent plus when NOT to use it beats a
    // paragraph of politeness.
    private static let linearTools: [ChatTool] = [
        ChatTool(
            provider: .linear,
            name: "linear_list_issues",
            description: "List Linear issues by who holds them and which column they are in: what is assigned to the user, what a colleague has, what is In Progress. Use for any \u{201C}my tasks\u{201D} or \u{201C}what's in <column>\u{201D} question; keyword search cannot answer those.",
            parameters: ChatToolSchema(
                properties: [
                    "assignee": .init(description: "\u{201C}me\u{201D} for the user, or a colleague's name. Omit for everyone's."),
                    "state": .init(
                        description: "A column name as the workspace spells it, e.g. In Progress, Todo, In Review. Omit for every open column."
                    ),
                    "closed": .init(description: "\"true\" to include completed and cancelled issues. Defaults to open issues only.")
                ],
                required: []
            ),
            mutating: false
        ),
        ChatTool(
            provider: .linear,
            name: "linear_search_issues",
            description: "Search the user's Linear issues by keyword. Returns titles and states only — call linear_read_issue for the description and comments of the one that matters. Use before claiming a task does or doesn't exist. Not for \u{201C}my tasks\u{201D} — that is linear_list_issues.",
            parameters: ChatToolSchema(
                properties: ["query": .init(description: "Keywords to search for.")],
                required: ["query"]
            ),
            mutating: false
        ),
        ChatTool(
            provider: .linear,
            name: "linear_read_issue",
            description: "Read one Linear issue in full: description, state, assignee, priority, labels and its last comments. Use when a specific issue is named or was found by search and the user wants what it says.",
            parameters: ChatToolSchema(
                properties: ["key": .init(description: "The issue identifier, e.g. NOD-138.")],
                required: ["key"]
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
            name: "slack_post_message",
            description: """
            Post a message to Slack — in a channel, or as a direct message to one person. \
            Use when the user asks to tell, ping, message or send something to somebody or somewhere. \
            Give `channel_id` from slack_list_channels for a channel, or `to` for a person; never both. \
            Write the message as the user would send it, in their own language, with no preamble.
            """,
            parameters: ChatToolSchema(
                properties: [
                    "text": .init(description: "The message to send, exactly as it should appear."),
                    "channel_id": .init(description: "Channel id from slack_list_channels. Omit when messaging a person."),
                    "to": .init(description: "Who to message — a first name, full name, @handle or email. Omit when posting to a channel.")
                ],
                required: ["text"]
            ),
            mutating: true
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
    /// `mutating` marks the writes so their confirmations read as ones — the
    /// person sees what is created, moved, or cancelled before guests are
    /// emailed about it. All still stop at `ToolApprovalCard`; nothing leaves
    /// Nod unapproved, and the flag only decides how the card is worded. The
    /// two destructive writes are additionally held to the title and start on
    /// the card: the server refuses an `event_id` whose live title or start
    /// differs from what was approved, so the words the person read are the
    /// event acted on — a title alone couldn't tell Thursday's standup from
    /// Tuesday's.
    private static let calendarTools: [ChatTool] = [
        ChatTool(
            provider: .googleCalendar,
            name: "google-calendar_list_events",
            description: [
                "Read the user's calendar over a date range.",
                "Use it for any question about what they have scheduled beyond the coming week;",
                "nearer days are already in the prompt.",
                "Also the only source of event ids for update_event and delete_event —",
                "call it first even for a day the prompt already shows.",
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
            name: "google-calendar_check_availability",
            description: [
                "Read when people are busy, from their calendars' free/busy — no titles, just blocks.",
                "Use before proposing or scheduling a meeting with anyone, so the slot doesn't overlap.",
                "A person marked unreadable could not be checked — say so rather than assuming they're free."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "attendees": .init(description: "Comma-separated emails to check."),
                    "starts_at": .init(description: "RFC3339 start of the window to check."),
                    "ends_at": .init(description: "RFC3339 end of the window, at most a week later.")
                ],
                required: ["attendees", "starts_at", "ends_at"]
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
        ),
        ChatTool(
            provider: .googleCalendar,
            name: "google-calendar_update_event",
            description: [
                "Change one event on the user's calendar — retitle it, move it, rewrite its description, or add/remove guests.",
                "Only after list_events in this conversation: `event_id`, `event_title` and `event_starts_at` must come",
                "from its results, and the server refuses a title or start that doesn't match the id.",
                "For a recurring meeting this changes only the one occurrence named.",
                "Guests are emailed about the change."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "event_title": .init(description: "The event's current title, exactly as list_events returned it."),
                    "event_id": .init(description: "The event's id from list_events."),
                    "event_starts_at": .init(description: "The event's current start, exactly as list_events returned it."),
                    "new_title": .init(description: "New title. Omit to keep the current one."),
                    "starts_at": .init(description: "New RFC3339 start. Always pass `ends_at` with it."),
                    "ends_at": .init(description: "New RFC3339 end. Always pass `starts_at` with it, even when only the end moves."),
                    "description": .init(description: "Replacement description."),
                    "add_attendees": .init(description: "Comma-separated emails to invite. Everyone already on the event stays."),
                    "remove_attendees": .init(description: "Comma-separated emails to take off the event. Everyone else stays.")
                ],
                required: ["event_title", "event_id", "event_starts_at"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .googleCalendar,
            name: "google-calendar_respond_to_event",
            description: [
                "Answer the user's own invitation to one event: going, not going, or maybe.",
                "Only after list_events in this conversation: `event_id`, `event_title` and `event_starts_at` must come",
                "from its results, and the server refuses a title or start that doesn't match the id.",
                "Refused when the user organizes the event or is not a guest on it. For a recurring meeting this answers only the one occurrence named.",
                "The organizer is emailed the answer."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "event_title": .init(description: "The event's title, exactly as list_events returned it."),
                    "event_id": .init(description: "The event's id from list_events."),
                    "event_starts_at": .init(description: "The event's start, exactly as list_events returned it."),
                    "response": .init(description: "`accepted`, `declined`, or `tentative`.")
                ],
                required: ["event_title", "event_id", "event_starts_at", "response"]
            ),
            mutating: true
        ),
        ChatTool(
            provider: .googleCalendar,
            name: "google-calendar_delete_event",
            description: [
                "Cancel one event on the user's calendar.",
                "Only after list_events in this conversation: `event_id`, `event_title` and `event_starts_at` must come",
                "from its results, and the server refuses a title or start that doesn't match the id.",
                "For a recurring meeting this cancels only the one occurrence named — say so to the user.",
                "Guests are emailed the cancellation, and it cannot be undone."
            ].joined(separator: " "),
            parameters: ChatToolSchema(
                properties: [
                    "event_title": .init(description: "The event's title, exactly as list_events returned it."),
                    "event_id": .init(description: "The event's id from list_events."),
                    "event_starts_at": .init(description: "The event's start, exactly as list_events returned it.")
                ],
                required: ["event_title", "event_id", "event_starts_at"]
            ),
            mutating: true
        )
    ]
}
