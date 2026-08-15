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
        guard let data = function.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.compactMapValues { value in
            switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            default: nil
            }
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
        }
    }

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
            description: "Read the user's calendar over a date range. Use it for any question about what they have scheduled beyond the coming week; nearer days are already in the prompt.",
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
