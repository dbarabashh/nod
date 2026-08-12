import Foundation

/// One thing a turn did before it answered.
///
/// The chat's counterpart to a reasoning trace — except Nod doesn't ask models
/// for their reasoning (`LLMProxyClient.reasoning(for:)` turns it off), so what
/// is worth showing isn't what the model thought but what it *did*: which
/// product it reached into, with what, and whether it got anything. That is the
/// part a user can check.
struct ChatTurnStep: Identifiable, Equatable {
    enum Outcome: Equatable {
        case ran
        case declined
        case failed(String)
    }

    let id = UUID()
    let provider: IntegrationProvider
    /// The tool's action, e.g. `search_issues`.
    let action: String
    /// The argument worth reading back — the query, the title. Empty when the
    /// call carried nothing a person would recognise.
    let detail: String
    let outcome: Outcome

    /// "Searched Linear", "Created in Linear" — the verb comes from `ChatTool`,
    /// the same place the approval card takes it from.
    var title: String {
        "\(ChatTool.verb(for: action)) \(provider.displayName)"
    }
}
