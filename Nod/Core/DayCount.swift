import Foundation

/// Whole days between two instants, by calendar day rather than by elapsed
/// hours — 23:59 and 00:05 are a day apart.
///
/// One copy so a session label, a prompt's clock block and a loop's age can
/// never disagree about what "yesterday" means. They are read side by side in
/// one answer, and two copies of this arithmetic is how one instant ends up
/// dated twice.
enum DayCount {
    static func between(_ earlier: Date, and later: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: earlier),
            to: calendar.startOfDay(for: later)
        ).day ?? 0
    }
}
