import Foundation

/// The two-line answer to "what is in my memory right now", shown under the
/// chat's openers so the home screen says something before the user types.
///
/// Counts only — no model call, no invented priority. Everything here is
/// already on the device; the point is that the user shouldn't have to ask a
/// question to find out they owe three follow-ups.
struct MemoryBrief: Equatable {
    /// Sessions captured today, or — when today is empty — over the past week,
    /// so a Monday morning doesn't read as "you have nothing".
    let captured: Int
    let capturedSpansWeek: Bool
    let openCommitments: Int
    let unresolved: Int
    /// What the week actually settled — the half of memory that isn't a to-do.
    /// Without it the brief only ever counted work outstanding, which is the
    /// reading of Nod this UX is moving away from.
    let decisions: Int
    /// The session the user has been in most recently: what "where was I"
    /// resolves to without asking.
    let mostActiveContext: String?

    /// True when there is nothing worth taking the space for.
    var isEmpty: Bool {
        captured == 0 && openCommitments == 0 && unresolved == 0 && decisions == 0
    }

    /// `openCommitments` is passed in rather than derived: it's a server-side
    /// count, and the whole point of taking it as a number is not pulling two
    /// hundred rows in to call `.count` on them.
    static func build(
        meetings: [Meeting],
        openCommitments: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MemoryBrief {
        // Already newest-first, so both windows are prefixes — no need to scan
        // years of history to count today.
        let live = meetings.liveNewestFirst()
        let today = live.prefix { calendar.isDate($0.startedAt, inSameDayAs: now) }
        let week = live.prefix { now.timeIntervalSince($0.startedAt) <= 7 * 24 * 60 * 60 }

        return MemoryBrief(
            captured: today.isEmpty ? week.count : today.count,
            capturedSpansWeek: today.isEmpty,
            openCommitments: openCommitments,
            unresolved: TodayDigest.openPointCount(meetings: meetings, now: now),
            decisions: SessionKnowledge.across(Array(week)).decisions,
            mostActiveContext: live.first?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        )
    }

    /// "3 sessions today · 5 open commitments · 2 unresolved" — assembled from
    /// the parts that are non-zero, so the line never pads itself with noise.
    var summary: String {
        summaryParts.joined(separator: " · ")
    }

    private var summaryParts: [String] {
        var parts: [String] = []
        if captured > 0 {
            parts.append("\(captured) \(captured == 1 ? "session" : "sessions") \(capturedSpansWeek ? "this week" : "today")")
        }
        if openCommitments > 0 {
            parts.append("\(openCommitments) open \(openCommitments == 1 ? "commitment" : "commitments")")
        }
        if decisions > 0 {
            parts.append("\(decisions) \(decisions == 1 ? "decision" : "decisions") this week")
        }
        if unresolved > 0 {
            parts.append("\(unresolved) unresolved")
        }
        return parts
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
