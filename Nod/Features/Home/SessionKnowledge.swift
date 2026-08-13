import Foundation

/// What Nod extracted from a session, as three numbers.
///
/// The unit the product is actually about: a session is not a recording with a
/// summary attached, it is some number of decisions, commitments and loose ends.
/// Saying so on the card is what makes a list of sessions read as knowledge
/// rather than as files.
///
/// Counted from the recap already on the device — no model call, and no second
/// definition of "decision" anywhere else in the app.
struct SessionKnowledge: Equatable {
    let actions: Int
    let decisions: Int
    let unresolved: Int

    var isEmpty: Bool {
        actions == 0 && decisions == 0 && unresolved == 0
    }

    static let empty = SessionKnowledge(actions: 0, decisions: 0, unresolved: 0)

    /// "3 actions · 2 decisions · 1 unresolved", built from the non-zero parts
    /// so a session with one decision doesn't advertise two zeroes.
    var summary: String {
        var parts: [String] = []
        if actions > 0 { parts.append("\(actions) \(actions == 1 ? "action" : "actions")") }
        if decisions > 0 { parts.append("\(decisions) \(decisions == 1 ? "decision" : "decisions")") }
        if unresolved > 0 { parts.append("\(unresolved) unresolved") }
        return parts.joined(separator: " · ")
    }

    static func + (lhs: SessionKnowledge, rhs: SessionKnowledge) -> SessionKnowledge {
        SessionKnowledge(
            actions: lhs.actions + rhs.actions,
            decisions: lhs.decisions + rhs.decisions,
            unresolved: lhs.unresolved + rhs.unresolved
        )
    }

    /// Actions come from the recap rather than from `ActionItemStore`: this runs
    /// per row in a list of hundreds, and the store's rows for a session are a
    /// filter over every task the account owns.
    static func of(_ meeting: Meeting) -> SessionKnowledge {
        guard let recap = meeting.recap else { return .empty }
        var decisions = 0
        var unresolved = 0
        for section in recap.sections {
            let bullets = section.bullets.count { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if TodayDigest.leavesSomethingOpen(section.title) {
                unresolved += bullets
            } else if TodayDigest.settlesSomething(section.title) {
                decisions += bullets
            }
        }
        return SessionKnowledge(
            actions: recap.actionItems.count { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            decisions: decisions,
            unresolved: unresolved
        )
    }

    static func across(_ meetings: [Meeting]) -> SessionKnowledge {
        meetings.reduce(.empty) { $0 + of($1) }
    }
}

private extension Collection {
    func count(where isIncluded: (Element) -> Bool) -> Int {
        reduce(0) { $0 + (isIncluded($1) ? 1 : 0) }
    }
}
