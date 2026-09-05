import Foundation

/// Open commitments arranged under the session that produced them, so the
/// source is drawn once per group rather than repeated on every row.
struct ActionGroup: Identifiable, Equatable {
    /// The session's id. Every commitment carries one, so a group keeps a
    /// stable identity even when the meeting itself is not in the cache.
    let id: UUID
    let title: String
    /// When the session happened. Nil when the meeting isn't in the cache.
    let subtitle: String?
    let items: [ActionItem]
}

enum ActionGrouping {
    /// Groups in the order their first item appears, items keeping the order
    /// they arrived in. The caller has already sorted for recency, and a
    /// grouping that re-sorts would move commitments the person just looked at.
    static func bySession(
        _ items: [ActionItem],
        meetings: [UUID: Meeting],
        dateFormatter: DateFormatter = Meeting.shortDateFormatter
    ) -> [ActionGroup] {
        var order: [UUID] = []
        var buckets: [UUID: [ActionItem]] = [:]
        for item in items {
            if buckets[item.meetingID] == nil {
                order.append(item.meetingID)
            }
            buckets[item.meetingID, default: []].append(item)
        }
        return order.compactMap { meetingID in
            guard let bucket = buckets[meetingID], !bucket.isEmpty else { return nil }
            let meeting = meetings[meetingID]
            // An untitled session already reads as "Meeting on 3 Sep", so a
            // date beside it would print the same day twice.
            let titled = meeting?.title?.trimmingCharacters(in: .whitespaces).isEmpty == false
            return ActionGroup(
                id: meetingID,
                title: meeting?.displayTitle(dateFormatter: dateFormatter) ?? "Another session",
                subtitle: titled ? meeting.map { dateFormatter.string(from: $0.startedAt) } : nil,
                items: bucket
            )
        }
    }
}
