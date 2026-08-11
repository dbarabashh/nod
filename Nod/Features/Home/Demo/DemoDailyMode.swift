import SwiftUI

/// A scripted daily surface shown in the main window's demo section — the
/// breadth of what Nod does beyond one meeting's transcript, walked as a
/// small sidebar of modes rather than a single card.
///
/// Fully scripted, like `DemoScenario`: no live data, one content set per
/// `DemoScenario` so the fictional story the notch already tells stays
/// consistent when a viewer clicks over here.
enum DemoDailyMode: String, CaseIterable, Identifiable {
    case morningBriefing
    case catchUp
    case actionPlan
    case deepWork
    case inbox
    case meetingPrep
    case dailyRecap

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .morningBriefing: "Morning Briefing"
        case .catchUp: "Catch Up"
        case .actionPlan: "Action Plan"
        case .deepWork: "Deep Work"
        case .inbox: "Inbox"
        case .meetingPrep: "Meeting Prep"
        case .dailyRecap: "Daily Recap"
        }
    }

    var icon: String {
        switch self {
        case .morningBriefing: "nc-sparkle-3"
        case .catchUp: "nc-refresh-2"
        case .actionPlan: "nc-tasks-2"
        case .deepWork: "nc-target"
        case .inbox: "nc-inbox-arrow-down"
        case .meetingPrep: "nc-calendar-days"
        case .dailyRecap: "nc-window-chart-line"
        }
    }
}

/// What a row's leading glyph shows — a teammate's photo, an integration's
/// mark, or a plain system icon for a task that has neither.
enum DemoDailyGlyph: Equatable {
    case person(name: String, tint: Color)
    case tool(DemoTool)
    case system(icon: String, tint: Color = Theme.Palette.muted)
}

extension DemoDailyGlyph {
    /// One fixed photo per cast member, picked by hand rather than hashed —
    /// a hashed seed (pravatar's `?u=`) has no notion of gender and put a
    /// bearded man on "Maya Ostrowski". `randomuser.me`'s men/women split
    /// makes that mistake structurally impossible: the path itself carries
    /// the gender, not a guess from the name.
    private static let castPhotos: [String: URL] = [
        "Sofia Marchetti": randomUserPortrait(.women, 44),
        "Daniel Okoye": randomUserPortrait(.men, 32),
        "Rachel Adeyemi": randomUserPortrait(.women, 65),
        "Ines Duarte": randomUserPortrait(.women, 21),
        "Jonas Hedlund": randomUserPortrait(.men, 75),
        "Maya Ostrowski": randomUserPortrait(.women, 68),
        "Tobias Krause": randomUserPortrait(.men, 12),
        "Ayesha Rahman": randomUserPortrait(.women, 53)
    ]

    private enum RandomUserGender: String {
        case men
        case women
    }

    private static func randomUserPortrait(_ gender: RandomUserGender, _ index: Int) -> URL {
        guard let url = URL(string: "https://randomuser.me/api/portraits/\(gender.rawValue)/\(index).jpg") else {
            fatalError("malformed randomuser.me portrait URL for \(gender.rawValue)/\(index)")
        }
        return url
    }

    /// A cast member's photo, or nil for a name not in `castPhotos` — a new
    /// scenario's author adds a row here rather than the view falling back to
    /// a randomly-gendered guess.
    static func avatarURL(for name: String) -> URL? {
        castPhotos[name]
    }

    /// Fallback shown while the photo loads, or if it never does — this is a
    /// scripted demo reaching an external host, not the app's own data, so a
    /// blocked or offline network must not leave a broken image behind.
    static func initials(for name: String) -> String {
        let letters = name.split(separator: " ").compactMap(\.first)
        return String(letters.prefix(2)).uppercased()
    }
}

/// One line in a mode's list: a teammate's update, an email, a task, a
/// meeting. One shape covers all seven modes rather than a layout each.
struct DemoDailyRow: Identifiable {
    let glyph: DemoDailyGlyph
    let title: String
    let subtitle: String?
    /// Trailing label — a time, a due date, a count.
    let meta: String?

    var id: String {
        title + (subtitle ?? "") + (meta ?? "")
    }
}

/// Everything one mode shows for one scenario.
struct DemoDailyModeContent {
    /// The personal opening line, when the mode has one — Morning Briefing
    /// and Daily Recap greet by name, the others open on the summary directly.
    let greeting: String?
    let summary: String
    let rows: [DemoDailyRow]
    let footerAction: String?
}

extension DemoDailyMode {
    /// The seven modes' content for one scenario, keyed by mode — built once
    /// per scenario selection rather than per row, so switching modes in the
    /// demo is just a dictionary read.
    static func content(for scenario: DemoScenario) -> [DemoDailyMode: DemoDailyModeContent] {
        switch scenario {
        case .productEngineering: productEngineeringDailyModes
        case .sales: salesDailyModes
        case .recruiting: recruitingDailyModes
        case .management: managementDailyModes
        }
    }
}
