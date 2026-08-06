import Foundation

/// What the home screen puts in front of the user: the few things that need
/// attention right now, derived from data already on the device — the extracted
/// action items and the recap sections that were left open. No extra model call,
/// no priority engine: recency and stated deadlines are the whole ranking.
enum TodayDigest {
    /// Past this, an open thread is history rather than something to act on —
    /// a question raised a month ago that nobody chased is not "unresolved",
    /// it's abandoned, and listing it forever would make the screen noise.
    static let attentionWindow: TimeInterval = 14 * 24 * 60 * 60

    struct OpenAction: Identifiable, Equatable {
        let item: ActionItem
        let meeting: Meeting
        /// Resolved only when the meeting stated one, so the row can say
        /// "overdue" rather than repeat a stale "by Friday".
        let deadline: ActionItemDeadline.Display?

        var id: UUID {
            item.id
        }
    }

    /// One bullet from a recap section that the meeting left open — an open
    /// question, a decision that was deferred, a raised risk.
    struct OpenPoint: Identifiable {
        let id: String
        let text: String
        let meeting: Meeting
    }

    /// Outstanding tasks, most urgent first: a missed deadline outranks one
    /// that's near, and within the same urgency the newer meeting wins.
    static func openActions(
        items: [ActionItem],
        meetings: [Meeting],
        now: Date = Date(),
        limit: Int = 6
    ) -> [OpenAction] {
        let byID = Dictionary(
            meetings.live().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items
            .filter { !$0.done }
            .compactMap { item -> OpenAction? in
                guard let meeting = byID[item.meetingID] else { return nil }
                let phrase = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let display = phrase.isEmpty
                    ? nil
                    : ActionItemDeadline.display(phrase: phrase, spokenAt: meeting.startedAt, now: now)
                return OpenAction(item: item, meeting: meeting, deadline: display)
            }
            .sorted { a, b in
                let left = urgencyRank(a.deadline?.urgency)
                let right = urgencyRank(b.deadline?.urgency)
                if left != right { return left < right }
                if a.meeting.startedAt != b.meeting.startedAt {
                    return a.meeting.startedAt > b.meeting.startedAt
                }
                return a.item.position < b.item.position
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Questions and deferred decisions from recent sessions, newest first.
    static func openPoints(
        meetings: [Meeting],
        now: Date = Date(),
        limit: Int = 4
    ) -> [OpenPoint] {
        let recent = meetings
            .liveNewestFirst()
            .filter { now.timeIntervalSince($0.startedAt) <= attentionWindow }

        var points: [OpenPoint] = []
        for meeting in recent {
            guard let sections = meeting.recap?.sections else { continue }
            for (sectionIndex, section) in sections.enumerated() where leavesSomethingOpen(section.title) {
                for (bulletIndex, bullet) in section.bullets.enumerated() {
                    let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    points.append(
                        OpenPoint(
                            id: "\(meeting.id.uuidString)-\(sectionIndex)-\(bulletIndex)",
                            text: text,
                            meeting: meeting
                        )
                    )
                    if points.count >= limit { return points }
                }
            }
        }
        return points
    }

    /// Just how many there are. The home brief needs the number, and building
    /// the full list to call `.count` copied a `Meeting` struct per bullet.
    static func openPointCount(meetings: [Meeting], now: Date = Date()) -> Int {
        var total = 0
        for meeting in meetings
            where meeting.deletedAt == nil && now.timeIntervalSince(meeting.startedAt) <= attentionWindow {
            guard let sections = meeting.recap?.sections else { continue }
            for section in sections where leavesSomethingOpen(section.title) {
                for bullet in section.bullets
                    where !bullet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    total += 1
                }
            }
        }
        return total
    }

    static func recentSessions(_ meetings: [Meeting], limit: Int = 5) -> [Meeting] {
        Array(meetings.liveNewestFirst().prefix(limit))
    }

    /// Section titles are written by the recap model in the user's output
    /// language, so the match is on the signal words both languages settle on
    /// ("Open questions" / "Відкриті питання"). A plain "Questions" section —
    /// what an interview recap produces — is deliberately NOT a signal: those
    /// are questions that were asked and answered, not left open.
    static func leavesSomethingOpen(_ sectionTitle: String) -> Bool {
        let title = sectionTitle.lowercased()
        return openSignals.contains { title.contains($0) }
    }

    private static let openSignals = [
        "open question", "open thread", "open item", "unresolved", "undecided",
        "pending", "to decide", "risk", "blocker",
        "відкрит", "невиріш", "нерозв", "ризик"
    ]

    private static func urgencyRank(_ urgency: ActionItemDeadline.Urgency?) -> Int {
        switch urgency {
        case .overdue: 0
        case .imminent: 1
        case .upcoming: 2
        case .vague: 3
        case nil: 4
        }
    }
}
