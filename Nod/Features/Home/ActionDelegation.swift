import Foundation

/// What the person wants to happen — named by outcome, never by tool. The
/// integrations underneath are picked per intent, so the twelfth connected
/// product changes this list nowhere.
enum ActionIntent: String, CaseIterable, Identifiable {
    case sendMessage
    case createTask
    case scheduleMeeting
    case addReminder

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .sendMessage: "nc-paper-plane-2"
        case .createTask: "nc-tasks-2"
        case .scheduleMeeting: "nc-calendar"
        case .addReminder: "nc-calendar-days"
        }
    }

    /// The products that can carry this intent out. The mapping lives here, in
    /// one table, so adding a provider is a membership edit — not a new button.
    var carriers: [IntegrationProvider] {
        switch self {
        case .sendMessage: [.slack]
        case .createTask: [.linear, .jira, .asana, .googleTasks]
        case .scheduleMeeting, .addReminder: [.googleCalendar]
        }
    }

    /// The intents worth offering to someone with these products connected.
    static func available(usable: (IntegrationProvider) -> Bool) -> [ActionIntent] {
        allCases.filter { $0.carriers.contains(where: usable) }
    }

    /// The suggestion as it reads for THIS action — "Create “Test the proxy”
    /// as a task", not a bare command name. Nod has the context; the menu
    /// should show that it does.
    func contextTitle(for item: ActionItem) -> String {
        let short = item.text.count <= 32 ? item.text : String(item.text.prefix(31)).trimmingCharacters(in: .whitespaces) + "…"
        switch self {
        case .sendMessage: return "Send a message about this"
        case .createTask: return "Create “\(short)” as a task"
        case .scheduleMeeting: return "Schedule a follow-up"
        case .addReminder: return "Remind me tomorrow"
        }
    }
}

/// The pure half of delegating: the drafts, the record line, the directory the
/// picker offers, and where the record lives. Separate from the view so all of
/// it can be tested.
enum ActionDelegation {
    /// Someone the message can go to: a person by name, or a channel by the id
    /// Slack posts need.
    enum Target: Identifiable, Equatable {
        case person(name: String, email: String)
        case channel(id: String, name: String, purpose: String)

        var id: String {
            switch self {
            case let .person(name, email): "person:\(name):\(email)"
            case let .channel(id, _, _): "channel:\(id)"
            }
        }

        var display: String {
            switch self {
            case let .person(name, _): name
            case let .channel(_, name, _): "#\(name)"
            }
        }

        var caption: String {
            switch self {
            case let .person(_, email): email
            case let .channel(_, _, purpose): purpose
            }
        }

        var isChannel: Bool {
            if case .channel = self { return true }
            return false
        }
    }

    struct Directory: Equatable {
        var people: [Target] = []
        var channels: [Target] = []
    }

    /// The handoff message a person reviews before it is sent — the item in
    /// its own words, the source named so the recipient can ask about it.
    static func draft(for item: ActionItem, source: String?) -> String {
        var lines = [item.text.hasSuffix("?") ? item.text : "Can you pick this up: \(item.text)?"]
        if let source, !source.isEmpty {
            lines.append("Context: from \"\(source)\" in Nod.")
        }
        return lines.joined(separator: " ")
    }

    /// A question handed to Ask Nod with the session it is about already
    /// pinned, so the answer is grounded in that session rather than in
    /// whatever a search happens to find.
    struct AskRequest: Equatable {
        let text: String
        let session: KnowledgeChatStore.SessionRef?
    }

    /// What lands in the chat composer when the person asks Nod instead.
    ///
    /// Asks for the ground first. "Help me move this forward" read to the
    /// model as "do something", and the something was a ticket, filed before
    /// anyone had said what the problem was or whether it still existed. The
    /// session is named as an `@` mention, which is what pins it.
    static func askPrompt(for item: ActionItem, source: KnowledgeChatStore.SessionRef?) -> AskRequest {
        let origin = source.map { " from \($0.mentionToken)" } ?? ""
        var commitment = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = commitment.last, ".!?".contains(last) {
            commitment.removeLast()
        }
        let text = "About this commitment\(origin): \(commitment). "
            + "First tell me what the session actually said about it: what the problem is, who raised it and what was decided. "
            + "Then check whether it is already tracked or resolved. "
            + "End with what you would do next, and don't create or change anything unless I say so."
        return AskRequest(text: text, session: source)
    }

    static func record(recipient: String, via provider: IntegrationProvider) -> String {
        "Delegated to \(recipient) via \(provider.displayName)"
    }

    /// One offered sentence about a piece of on-screen work. What crosses into
    /// the message is this string and nothing else from the observation.
    @MainActor static func addition(for hint: ScreenObservation) -> String {
        "Related: I've been working in \(hint.appDisplayName) — \(hint.sourceTitle)."
    }

    /// Adds the sentence to the message, or takes exactly it back out —
    /// idempotent either way, so the checkbox and the editor cannot disagree.
    static func toggling(message: String, addition: String) -> String {
        if message.contains(addition) {
            return message
                .replacingOccurrences(of: "\n" + addition, with: "")
                .replacingOccurrences(of: addition, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.isEmpty ? addition : message + "\n" + addition
    }

    private struct UserRow: Decodable {
        let name: String?
        let email: String?
    }

    private struct ChannelRow: Decodable {
        let id: String
        let name: String
        let purpose: String?
    }

    private struct UsersPayload: Decodable {
        let users: [UserRow]
    }

    private struct ChannelsPayload: Decodable {
        let channels: [ChannelRow]
    }

    private struct UsersEnvelope: Decodable {
        let result: UsersPayload?
    }

    private struct ChannelsEnvelope: Decodable {
        let result: ChannelsPayload?
    }

    /// The picker's contents, out of the raw tool results. Errors decode to an
    /// empty directory: a picker with nothing to offer degrades to the typed
    /// name, which still sends.
    static func directory(people: String, channels: String) -> Directory {
        var built = Directory()
        if let data = people.data(using: .utf8),
           let payload = try? JSONDecoder().decode(UsersEnvelope.self, from: data).result {
            built.people = payload.users.compactMap { row in
                guard let name = row.name, !name.isEmpty else { return nil }
                return .person(name: name, email: row.email ?? "")
            }
        }
        if let data = channels.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ChannelsEnvelope.self, from: data).result {
            built.channels = payload.channels.map {
                .channel(id: $0.id, name: $0.name, purpose: $0.purpose ?? "")
            }
        }
        return built
    }

    /// Who matches what was typed. People lead — "tell Vlad" is the common
    /// case — channels answer a leading `#` or a name match. Empty input
    /// offers nothing rather than the whole workspace.
    static func matches(for typed: String, in directory: Directory, limit: Int = 6) -> [Target] {
        let query = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        if query.hasPrefix("#") {
            let name = String(query.dropFirst())
            return directory.channels
                .filter { name.isEmpty || $0.display.lowercased().contains(name) }
                .prefix(limit)
                .map { $0 }
        }
        let people = directory.people.filter {
            $0.display.lowercased().contains(query) || $0.caption.lowercased().hasPrefix(query)
        }
        let channels = directory.channels.filter { $0.display.lowercased().contains(query) }
        return Array((people + channels).prefix(limit))
    }

    /// What `post_message` needs for whoever was picked: a channel posts by
    /// id, a person by name, and a bare typed name stays a person.
    static func sendArguments(target: Target?, typed: String, message: String) -> [String: String] {
        switch target {
        case let .channel(id, _, _): ["channel_id": id, "text": message]
        // The address, when the picker resolved one: `memberFor` falls back to
        // first-name matching, and two Vlads would otherwise go to whichever
        // Slack listed first — not the one that was clicked.
        case let .person(name, email): ["to": email.isEmpty ? name : email, "text": message]
        case nil: ["to": typed, "text": message]
        }
    }

    /// The same catalogue entry the chat uses when it exists, built inline when
    /// it does not — `list_users` is a read the chat never needed a tool for.
    static func tool(action: String, of provider: IntegrationProvider) -> ChatTool {
        ChatTools.definitions(for: [provider]).first { $0.action == action } ?? ChatTool(
            provider: provider,
            name: "\(provider.rawValue)_\(action)",
            description: "",
            parameters: ChatToolSchema(properties: [:], required: []),
            mutating: false
        )
    }

    static func call(
        action: String,
        of provider: IntegrationProvider,
        arguments: [String: String] = [:]
    ) -> ChatToolCall {
        ChatToolCall(
            id: UUID().uuidString,
            type: "function",
            function: .init(name: "\(provider.rawValue)_\(action)", arguments: encode(arguments))
        )
    }

    /// Per-item, on this Mac. A delegation is a message that already exists in
    /// the messenger; this only reminds the person they sent it, so defaults is
    /// enough and the item deliberately stays open.
    static func remember(_ record: String, for itemID: UUID) {
        UserDefaults.standard.set(record, forKey: key(itemID))
        NotificationCenter.default.post(name: .nodActionDelegated, object: itemID)
    }

    static func recorded(for itemID: UUID) -> String? {
        UserDefaults.standard.string(forKey: key(itemID))
    }

    /// Dropped when the item closes, so a record does not outlive the work.
    static func forget(_ itemID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(itemID))
    }

    private static func key(_ itemID: UUID) -> String {
        "today.delegated.\(itemID.uuidString)"
    }

    /// One assignable person out of a provider's `list_users` answer — the
    /// same `{users:[{id,name,email}]}` shape Linear and Slack both speak.
    struct Person: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private struct PersonRow: Decodable {
        let id: String?
        let name: String?
    }

    private struct PeoplePayload: Decodable {
        let users: [PersonRow]
    }

    private struct PeopleEnvelope: Decodable {
        let result: PeoplePayload?
    }

    static func people(in result: String) -> [Person] {
        guard let data = result.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PeopleEnvelope.self, from: data).result
        else { return [] }
        return payload.users.compactMap { row in
            guard let id = row.id, let name = row.name, !name.isEmpty else { return nil }
            return Person(id: id, name: name)
        }
    }

    /// The `@`-fragment being typed at the end of `text`, if one is open —
    /// "ask @Sl" gives "Sl", "no at-sign here" gives nil. Only a trailing
    /// fragment: mentions mid-sentence are already written.
    static func mentionFragment(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before == " " || before == "\n" else { return nil }
        }
        let fragment = String(text[text.index(after: at)...])
        guard !fragment.contains(" "), !fragment.contains("\n") else { return nil }
        return fragment
    }

    /// Replaces the open fragment with the product's token, the same `@Name`
    /// the chat's composer writes — so the plan lands in the chat already
    /// naming its tools.
    static func inserting(mention provider: IntegrationProvider, into text: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@\(provider.displayName) "
    }

    static func encode(_ arguments: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

extension Notification.Name {
    /// A commitment was handed to somebody — Today repartitions on it, because
    /// a delegated item is no longer waiting on you.
    static let nodActionDelegated = Notification.Name("nod.action.delegated")
}
