import Foundation

/// What kind of conversation "Suggest reply" is helping with. Drives the
/// situation framing in the suggest-reply prompt so an interview answer reads
/// differently from a standup interjection. `.auto` lets the model infer the
/// situation from the transcript; the explicit cases assert it. Persisted as a
/// global default in `UserDefaults` (key `suggestReply.context`).
enum ReplyContext: String, Codable, CaseIterable, Identifiable {
    case auto
    case interview
    case meeting
    case salesCall
    case oneOnOne
    case negotiation
    case casual

    var id: String {
        rawValue
    }

    /// The persisted default, read at suggest-reply time. Unknown/missing
    /// values fall back to `.auto`.
    static let defaultsKey = "suggestReply.context"
    static var current: ReplyContext {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ReplyContext.init) ?? .auto
    }

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .interview: "Q&A"
        case .meeting: "Meeting"
        case .salesCall: "Sales call"
        case .oneOnOne: "1:1"
        case .negotiation: "Negotiation"
        case .casual: "Casual chat"
        }
    }

    var settingsHint: String {
        switch self {
        case .auto: "Let Nod infer the situation from the conversation."
        case .interview: "Direct, well-grounded answers to pointed questions."
        case .meeting: "Sharp, useful contributions to a work discussion."
        case .salesCall: "Advance the deal — handle concerns, propose a next step."
        case .oneOnOne: "Thoughtful, candid, personal responses."
        case .negotiation: "Hold your position and steer toward a good outcome."
        case .casual: "Relaxed, friendly, and brief."
        }
    }
}
