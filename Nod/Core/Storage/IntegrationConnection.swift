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

/// A third-party product Nod can *act in* — create a Linear issue from an action
/// item, and later write a Notion page or post to Slack.
///
/// The opposite arrow to `Connection`, which is a token letting the user's own
/// AI client *read* Nod. Two directions, two tables, deliberately two names.
enum IntegrationProvider: String, CaseIterable, Identifiable, Hashable {
    case linear

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .linear: "Linear"
        }
    }

    var taskActions: TaskActions? {
        switch self {
        case .linear: TaskActions(
                create: "create_issue",
                readStatus: "read_issues",
                search: "search_issues",
                update: "update_issue"
            )
        }
    }

    /// What connecting actually grants, in the user's terms. Kept concrete —
    /// "issues" rather than "productivity" — because this is the only place the
    /// scope is explained before the browser opens.
    var summary: String {
        switch self {
        case .linear: "Turn action items into Linear issues."
        }
    }

    /// The brand mark, once someone drops `logo.png` into the matching imageset
    /// — same arrangement as `ConnectionClient.iconAssetName`. Resolved at use
    /// site so a missing asset degrades to the Nucleo stand-in instead of
    /// rendering an empty frame.
    var brandAssetName: String {
        switch self {
        case .linear: "ConnLinear"
        }
    }

    var fallbackIconName: String {
        switch self {
        case .linear: "nc-tasks-2"
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
}
