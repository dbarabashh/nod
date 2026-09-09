import Combine
import Foundation

/// How much a connected product may be reached without asking first.
///
/// Two states, not the three a plugin permissions screen usually offers. The
/// third one — "low-risk actions" — would need a notion of a harmless *write*,
/// and the catalogue has none: `ChatTool.mutating` is the only line this app
/// can actually defend, so it is the only line drawn here. A tier nobody can
/// audit is worse than a coarser one everybody can.
enum ToolApproval: String, CaseIterable, Identifiable {
    /// Every call shows a card, reads included.
    case alwaysAsk
    /// Reads run unasked; every write still shows its card.
    case allowReads

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .alwaysAsk: "Always ask"
        case .allowReads: "Allow read actions"
        }
    }

    var detail: String {
        switch self {
        case .alwaysAsk: "Nod asks before reading from or changing anything in a connected product."
        case .allowReads: "Nod can read without asking. Anything that creates, sends or changes something still asks."
        }
    }
}

@MainActor
final class ToolApprovalPreference: ObservableObject {
    /// Asking every time is the default, and stays the default for everyone who
    /// upgrades into this setting existing. What a person agreed to when they
    /// connected a product is not ours to widen on their behalf — see
    /// `.agents/rules/backward-compatibility.md` on consent transitions.
    @Published var approval: ToolApproval {
        didSet { defaults.set(approval.rawValue, forKey: Self.key) }
    }

    /// Products the person allowed from the card itself, one at a time.
    ///
    /// Reads only, whatever the card was showing when they pressed it — see
    /// `allowReads(from:)`. A per-product memory rather than a second global
    /// switch because that is the decision actually in front of them: they are
    /// looking at Slack's card, not at a policy for everything they might ever
    /// connect.
    @Published private(set) var alwaysAllowed: Set<IntegrationProvider> {
        didSet { defaults.set(alwaysAllowed.map(\.rawValue).sorted(), forKey: Self.allowedKey) }
    }

    private let defaults: UserDefaults
    private static let key = "tools.approval"
    private static let allowedKey = "tools.approval.allowed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        approval = defaults.string(forKey: Self.key).flatMap(ToolApproval.init(rawValue:)) ?? .alwaysAsk
        alwaysAllowed = Set(
            (defaults.stringArray(forKey: Self.allowedKey) ?? []).compactMap(IntegrationProvider.init(rawValue:))
        )
    }

    func allowReads(from provider: IntegrationProvider) {
        alwaysAllowed.insert(provider)
    }

    func stopAllowing(_ provider: IntegrationProvider) {
        alwaysAllowed.remove(provider)
    }

    /// Whether this batch may run without a card.
    ///
    /// The whole batch, not each call: one card covers a model turn, and a turn
    /// that mixes a search with a write is a write. Splitting it would show the
    /// card for the write alone and let the read go first — which is the same
    /// answer, arrived at in an order nobody was shown.
    func runsUnasked(_ tools: [ChatTool], from provider: IntegrationProvider) -> Bool {
        guard !tools.isEmpty, tools.allSatisfy({ !$0.mutating }) else { return false }
        return approval == .allowReads || alwaysAllowed.contains(provider)
    }
}
