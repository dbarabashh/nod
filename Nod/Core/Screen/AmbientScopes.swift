import Foundation

/// Where ambient context may be used, beyond the one place it has always fed.
///
/// The published contract (`privacy.md` § 3.10(b)) is that the screen record
/// exists so the person can *ask* about their own work. Surfacing it anywhere
/// else — a Today suggestion, an addition offered while drafting a message —
/// widens that contract, so each new surface is its own opt-in, off until the
/// person flips it. Nothing here is a capture setting: what is read and kept
/// is governed by the ambient switch, exclusions and retention exactly as
/// before; these only govern where what was already kept may appear.
enum AmbientScopes {
    /// Private "you worked on this" hints on Today and in an action's context.
    static let todaySuggestionsKey = "screen.scopes.todaySuggestions"
    /// Offering ambient-derived additions while drafting an outgoing message.
    /// Offer only — nothing is ever added to a message except by the person's
    /// own click, into an editor they are looking at.
    static let draftingKey = "screen.scopes.drafting"

    static var todaySuggestions: Bool {
        UserDefaults.standard.bool(forKey: todaySuggestionsKey)
    }

    static var drafting: Bool {
        UserDefaults.standard.bool(forKey: draftingKey)
    }

    /// "Today 14:32" / "Yesterday 15:04" / "Aug 28" — when a piece of related
    /// work was on the screen, in the words a hint line uses.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension ScreenObservation {
    /// The app as a person names it — "Figma", not "com.figma.Desktop". The
    /// directory's answer, so every surface calls one app one thing.
    @MainActor var appDisplayName: String {
        AppDirectory.identity(forBundleID: sourceApp).name
    }
}
