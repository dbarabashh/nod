import AppKit
import Foundation

/// What a product must do to be somewhere an action item can live: take a task,
/// say whether it is finished, and be searchable for one that is already there.
/// All three or none — a product that accepts a task and can never tell us it
/// closed turns Nod's checkbox into a guess, and one that cannot be searched
/// turns every second meeting about the same thing into a second ticket.
///
/// Named actions rather than a `canFileTasks` flag because the callers need the
/// names anyway, and a bool would leave them to be guessed from a prefix —
/// which is how `create_page` in a notes app would have become a filing target.
struct TaskActions {
    let create: String
    let readStatus: String
    let search: String
    let update: String
}

/// A task already in the product that looks like the one about to be filed.
///
/// Carries both names because they answer different questions: `reference.title`
/// is the key the row will show once linked, `summary` is what the task actually
/// says, which is the only thing that lets a person tell a real duplicate from a
/// coincidence of wording.
struct TaskMatch: Equatable {
    let reference: ProviderLinkItem
    let summary: String
    let closed: Bool
}

/// What a connected product is *for*, as opposed to which product it is.
///
/// Nod does not have a Slack feature or a Linear feature. It has "file this
/// work somewhere" and "start a conversation about this somewhere", and the
/// product that ends up serving either is whatever the organization uses —
/// Linear or Jira, Slack or Teams or Telegram. Naming the capability is what
/// keeps the rest of the app from hard-coding one company's stack as the
/// meaning of the verb.
enum IntegrationCapability: String, CaseIterable, Identifiable {
    /// Somewhere work is tracked: an issue, a ticket, a card.
    case tasks
    /// Somewhere people talk: a channel, a group, a space.
    case conversations
    /// A calendar.
    case calendar

    var id: String {
        rawValue
    }

    /// How the capability is described where a person picks between products.
    var displayName: String {
        switch self {
        case .tasks: "Task tracker"
        case .conversations: "Team chat"
        case .calendar: "Calendar"
        }
    }
}

/// The two calls a conversation product has to answer for Nod to act in it.
///
/// Named actions rather than a bool, for the same reason `TaskActions` is: the
/// caller needs the names, and guessing them from a prefix is how
/// `create_channel` in a wiki would have become a place to put a meeting.
struct ConversationActions {
    /// A channel in Slack, a group in Telegram, a team channel in Teams.
    let createSpace: String
    let invite: String
    /// The workspace's members, for matching a person to their account there.
    let listUsers: String
}

/// Which way the arrow points once a product is connected.
///
/// Kept apart because the two are not the same request to the person granting
/// them, however similar the plumbing is underneath. "File my action items as
/// Linear issues" is a thing Nod does when asked, item by item; "read my
/// calendar" is standing access to where someone is all day. Listing them
/// together under one heading would describe the second in the language of the
/// first.
enum IntegrationRole {
    case actsIn
    case readsFrom
}

/// A third-party product Nod connects to through Nango — creating a Linear issue
/// from an action item, or reading the calendar that says which meeting is
/// starting.
///
/// The opposite arrow to `Connection`, which is a token letting the user's own
/// AI client *read* Nod. Two directions, two tables, deliberately two names.
enum IntegrationProvider: String, CaseIterable, Identifiable, Hashable {
    case linear
    case googleCalendar = "google-calendar"
    case slack

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .linear: "Linear"
        case .googleCalendar: "Google Calendar"
        case .slack: "Slack"
        }
    }

    /// What this product is one of. A provider serves exactly one capability
    /// today; the type is a set so that the first product serving two — a
    /// tracker that is also where the team talks — does not need this rewritten.
    var capabilities: Set<IntegrationCapability> {
        switch self {
        case .linear: [.tasks]
        case .googleCalendar: [.calendar]
        case .slack: [.conversations]
        }
    }

    /// Every product that could serve a capability, whether or not anyone has
    /// connected one. What is actually reachable is `IntegrationService`'s
    /// question — it depends on the connection and on the organization's policy.
    static func all(serving capability: IntegrationCapability) -> [IntegrationProvider] {
        allCases.filter { $0.capabilities.contains(capability) }.sorted { $0.rawValue < $1.rawValue }
    }

    var role: IntegrationRole {
        switch self {
        case .linear, .slack: .actsIn
        case .googleCalendar: .readsFrom
        }
    }

    static func all(_ role: IntegrationRole) -> [IntegrationProvider] {
        allCases.filter { $0.role == role }
    }

    var taskActions: TaskActions? {
        switch self {
        case .linear: TaskActions(
                create: "create_issue",
                readStatus: "read_issues",
                search: "search_issues",
                update: "update_issue"
            )
        case .googleCalendar, .slack: nil
        }
    }

    var conversationActions: ConversationActions? {
        switch self {
        case .slack: ConversationActions(
                createSpace: "create_channel",
                invite: "invite_users",
                listUsers: "list_users"
            )
        case .linear, .googleCalendar: nil
        }
    }

    /// Whether this product can say who is in its workspace, so a company's
    /// roster can be picked up from it. What makes the answer yes is the
    /// adapter having a `list_users` handler, which every product serving
    /// `tasks` or `conversations` needs anyway to resolve an assignee.
    var isDirectorySource: Bool {
        taskActions != nil || conversationActions != nil
    }

    /// What connecting actually grants, in the user's terms. Kept concrete —
    /// "issues" rather than "productivity" — because this is the only place the
    /// scope is explained before the browser opens.
    var summary: String {
        switch self {
        case .linear: "Turn action items into Linear issues."
        case .googleCalendar: "Know which meeting is starting, so notes land on the right one."
        case .slack: "Read what a channel decided, and open one for what a meeting did."
        }
    }

    /// What connecting this actually gets you, and — where it matters — what it
    /// does not. One line each: a person deciding whether to hand over access to
    /// their company's tracker is answering "what will this do", and a single
    /// summary sentence has never been enough to answer it.
    var whatNodDoes: [String] {
        switch self {
        case .linear:
            [
                "File an action item as an issue, with the meeting's own wording.",
                "Check whether something is already tracked before filing it again.",
                "Close an issue when you tick the action item off.",
                "Every call is shown to you first; nothing is filed without your say-so."
            ]
        case .googleCalendar:
            [
                "Know which meeting is starting, so a recording lands on the right one.",
                "Name the people who were invited, so notes can say who said what.",
                "Read-only — Nod never writes to your calendar."
            ]
        case .slack:
            [
                "Read any public channel, so a question can be answered from what the team actually said.",
                "Open a channel for what a meeting decided, and add the people in it.",
                "Bring your workspace's members into the organization directory.",
                "It joins a public channel to read it, which that channel sees. Private channels need an invite, and direct messages are never read."
            ]
        }
    }

    /// Derived from the id rather than listed, so adding a product is adding a
    /// case and dropping an SVG in — not remembering a third place to edit.
    ///
    /// Three hand-written names had already drifted into two conventions, and
    /// Slack's pointed at an imageset nobody ever added: it drew the Nucleo
    /// stand-in, silently, which is how it survived to ship.
    var brandAssetName: String {
        "Brand" + rawValue.replacingOccurrences(of: "-", with: "")
    }

    /// The same mark, from the place the connection itself comes from.
    ///
    /// Nango's integration id *is* our `rawValue` — `integration-connect` sends
    /// it as `allowed_integrations` — so the catalogue we already authenticate
    /// against also has the logo. A product added tomorrow draws its own mark
    /// before anybody exports an asset for it.
    var remoteLogoURL: URL? {
        URL(string: "https://app.nango.dev/images/template-logos/\(rawValue).svg")
    }

    var fallbackIconName: String {
        switch self {
        case .linear: "nc-tasks-2"
        case .googleCalendar: "nc-calendar"
        case .slack: "nc-msgs"
        }
    }

    var iconName: String {
        Self.resolvedIcons[self] ?? fallbackIconName
    }

    /// Resolved once. Whether a brand asset shipped can't change at runtime, and
    /// this is read from view bodies that re-run per stream flush.
    private static let resolvedIcons: [IntegrationProvider: String] = allCases.reduce(into: [:]) { table, provider in
        table[provider] = NSImage(named: provider.brandAssetName) != nil
            ? provider.brandAssetName
            : provider.fallbackIconName
    }

    /// The host whose links belong to this product, so an answer that cites one
    /// can carry its mark instead of an anonymous blue phrase.
    var linkHost: String {
        switch self {
        case .linear: "linear.app"
        case .googleCalendar: "calendar.google.com"
        case .slack: "slack.com"
        }
    }

    init?(linkHost host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        guard let match = Self.allCases.first(where: {
            host == $0.linkHost || host.hasSuffix("." + $0.linkHost)
        }) else { return nil }
        self = match
    }
}

/// A row of `integration_connections`. Which provider is linked is the whole
/// question — the revoked ones are filtered server-side, and no credential is
/// ever stored here to begin with.
struct IntegrationConnection: Decodable {
    let provider: String
    /// Which team's work this connection is for. Never a sharing mechanism —
    /// the credential stays Nango's and stays the connecting person's; this only
    /// tells the chat which workspace to reach for when they are working in that
    /// team's context.
    let teamID: UUID?

    enum CodingKeys: String, CodingKey {
        case provider
        case teamID = "team_id"
    }
}
