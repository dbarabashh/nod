import Foundation

/// A recap layout the user picks — controls which section headings the
/// end-of-meeting summary is organized into. `.auto` lets the model choose the
/// sections from the content (anarlog-style); every other case supplies a
/// concrete section list the model must use. Persisted as a global default in
/// `UserDefaults` (key `summary.template`).
///
/// The titles below are written in English; the prompt tells the model to
/// translate them into the recap output language so a Ukrainian recap gets
/// Ukrainian headers. Sections with no grounded content are dropped, so an
/// interview that never reached a recommendation simply omits that heading.
enum SummaryTemplate: String, Codable, CaseIterable, Identifiable {
    case auto
    case standard
    case interview
    case salesCall
    case oneOnOne
    case standup

    var id: String {
        rawValue
    }

    /// The persisted default, read at recap time. Unknown/missing values fall
    /// back to `.auto`.
    static let defaultsKey = "summary.template"
    static var current: SummaryTemplate {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SummaryTemplate.init) ?? .auto
    }

    var displayName: String {
        switch self {
        case .auto: "Auto (let Nod decide)"
        case .standard: "Standard"
        case .interview: "Interview"
        case .salesCall: "Sales call"
        case .oneOnOne: "1:1"
        case .standup: "Standup"
        }
    }

    var settingsHint: String {
        switch self {
        case .auto: "Nod picks the sections that fit what was actually discussed."
        case .standard: "Topics, decisions, action items, and open questions."
        case .interview: "Candidate background, strengths, concerns, and a recommendation."
        case .salesCall: "Customer needs, objections, next steps, and commitments."
        case .oneOnOne: "Updates, wins, blockers, and action items."
        case .standup: "Done, in progress, blockers, and action items."
        }
    }

    /// Section titles the recap should use, in order. `nil` for `.auto` — the
    /// model picks its own sections. An empty section is dropped at generation
    /// time, so this is a suggested superset, not a hard requirement to fill.
    var sections: [String]? {
        switch self {
        case .auto:
            nil
        case .standard:
            ["Topics covered", "Decisions made", "Action items", "Open questions"]
        case .interview:
            ["Candidate background", "Strengths", "Concerns", "Recommendation", "Follow-ups"]
        case .salesCall:
            ["Customer needs", "Objections raised", "Next steps", "Commitments"]
        case .oneOnOne:
            ["Updates", "Wins", "Blockers", "Action items"]
        case .standup:
            ["Done", "In progress", "Blockers", "Action items"]
        }
    }
}
