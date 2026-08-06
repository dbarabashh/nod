import Foundation

/// Who a recording is with, and how many voices other than the user's it should
/// contain.
///
/// Two sources answer this, and they are not equal. The calendar holds an
/// invitation someone wrote: it names people, and it knows which one is the
/// user. The conferencing app's window holds whatever that application happens
/// to label — which for a call in a browser is the toolbar, the tab strip and
/// the user's bookmarks. A real Google Meet call read that way came back as
/// sixteen "participants", against four people actually invited.
///
/// So the calendar wins whenever it has an answer, and the window is what is
/// left for a call nobody put in a calendar.
struct MeetingParticipants: Equatable {
    /// Names for the recap and the speaker-naming pass.
    ///
    /// The user is left out when the source knows which one they are, which the
    /// calendar does and a window does not. Not a wart worth flattening: the
    /// naming pass is asked to map *other* people's voices, so dropping the user
    /// where possible removes a name it could wrongly attach to one — and where
    /// it is not possible, the same prompt already forbids naming the user's own
    /// side.
    let names: [String]
    /// How many distinct voices other than the user's the recording should hold.
    /// Zero means *unknown*, not *nobody*: clustering then picks its own
    /// threshold rather than being pinned to a number nothing supports.
    let expectedOtherVoices: Int
    let source: Source

    enum Source: Equatable {
        case calendar
        case conferencingApp
        case unknown
    }

    static let unknown = MeetingParticipants(names: [], expectedOtherVoices: 0, source: .unknown)
}

extension MeetingParticipants {
    static func resolve(calendar: CalendarOccurrence?, roster: MeetingRoster?) -> MeetingParticipants {
        // A calendar entry with nobody on it — a note to self, a blocked-out
        // hour — says nothing about who is in the room, so it does not get to
        // overrule a roster that does.
        if let others = calendar?.others, !others.isEmpty {
            return MeetingParticipants(
                names: others.map(\.display),
                expectedOtherVoices: others.count,
                source: .calendar
            )
        }
        if let roster, roster.speakerCount > 1 {
            return MeetingParticipants(
                names: roster.participants,
                // The window lists everyone including the user, and gives no way
                // to tell which entry is them — hence the subtraction the
                // calendar does not need.
                expectedOtherVoices: roster.speakerCount - 1,
                source: .conferencingApp
            )
        }
        return .unknown
    }
}
