import Foundation

/// What can happen to an action item, said as a verb rather than a product.
///
/// The list is closed and small on purpose. Two hundred connected products
/// are still four or five things a person can do with a commitment, and the
/// product each verb lands in is chosen once, in Settings, not per row. A new
/// integration adds a carrier to a verb; it never adds a verb.
enum ActionVerb: String, CaseIterable, Codable, Identifiable {
    case task
    case message
    case event
    case note

    var id: String {
        rawValue
    }

    var capability: IntegrationCapability {
        switch self {
        case .task: .tasks
        case .message: .conversations
        case .event: .calendar
        case .note: .customers
        }
    }

    var title: String {
        switch self {
        case .task: "Task"
        case .message: "Message"
        case .event: "Event"
        case .note: "Note"
        }
    }

    var icon: String {
        switch self {
        case .task: "nc-tasks-2"
        case .message: "nc-paper-plane-2"
        case .event: "nc-calendar"
        case .note: "nc-pen-writing"
        }
    }

    /// The provider action that carries this verb, or nil where the product
    /// serves the capability without a write for it.
    func action(in provider: IntegrationProvider) -> String? {
        switch self {
        case .task: provider.taskActions?.create
        case .message: provider == .slack ? "post_message" : nil
        case .event: provider == .googleCalendar ? "create_event" : nil
        case .note: provider == .hubspot ? "create_note" : nil
        }
    }

    /// Products that can carry this verb, in declaration order.
    func carriers(among providers: [IntegrationProvider]) -> [IntegrationProvider] {
        providers.filter { action(in: $0) != nil }
    }

    /// The verb a proposal's `type` (`provider.action`) stands for.
    static func of(type: String) -> ActionVerb? {
        let parts = type.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = IntegrationProvider(rawValue: parts[0]) else { return nil }
        return allCases.first { $0.action(in: provider) == parts[1] }
    }

    /// What this Mac can do right now, per verb — the input the rules read.
    struct Context: Equatable {
        var hasTracker = false
        var hasMessenger = false
        var hasCalendar = false
        var hasCRM = false
        /// The item names somebody else as its owner.
        var isTheirs = false
        /// What the person kept choosing for items like this one, if anything.
        var remembered: ActionVerb?

        func carries(_ verb: ActionVerb) -> Bool {
            switch verb {
            case .task: hasTracker
            case .message: hasMessenger
            case .event: hasCalendar
            case .note: hasCRM
            }
        }
    }

    /// The default verb for an item, from what is connected and what the
    /// person has done before — never from the words of the item. Rules a
    /// person can predict beat a model guessing "this sounds like a ticket".
    static func suggested(for context: Context) -> ActionVerb? {
        if let remembered = context.remembered, context.carries(remembered) { return remembered }
        if context.hasTracker { return .task }
        if context.isTheirs, context.hasMessenger { return .message }
        return nil
    }
}

/// Remembers the verb a person keeps picking by hand for a kind of item, so
/// the third time becomes the default. Per Mac, like the product defaults.
struct VerbMemory {
    static let threshold = 3
    private static let key = "actions.verbMemory"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var table: [String: [String: Int]] {
        get { defaults.dictionary(forKey: Self.key) as? [String: [String: Int]] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// Counts one more hand-picked `verb` for items of `kind`, and returns
    /// whether that verb has now become the remembered default.
    @discardableResult
    func note(_ verb: ActionVerb, for kind: ActionItem.Kind) -> Bool {
        var counts = table[kind.rawValue] ?? [:]
        counts[verb.rawValue, default: 0] += 1
        var all = table
        all[kind.rawValue] = counts
        table = all
        return remembered(for: kind) == verb
    }

    func remembered(for kind: ActionItem.Kind) -> ActionVerb? {
        guard let counts = table[kind.rawValue],
              let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              top.value >= Self.threshold else { return nil }
        return ActionVerb(rawValue: top.key)
    }

    func forget() {
        defaults.removeObject(forKey: Self.key)
    }
}
