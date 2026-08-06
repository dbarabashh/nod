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

    /// Name the one voice the conversation never named, when arithmetic leaves
    /// only one answer.
    ///
    /// The naming pass can only work from what was said out loud: somebody has
    /// to introduce a person, address them by name, or quote them. A great many
    /// meetings never do — above all the most common shape of all, the 1:1,
    /// where two people who know each other have no reason to say each other's
    /// names once. That call ends with an invitation naming exactly one other
    /// person, one voice cluster, and a transcript labelled "Speaker 1".
    ///
    /// So this is not a guess and not a model call. When the invitation lists
    /// exactly as many people as clustering found voices, and every name the
    /// pass produced is one of them, the leftover cluster and the leftover
    /// attendee have nobody else to be.
    ///
    /// The equality is what makes it safe, and it is doing real work: an invitee
    /// who never joined leaves fewer clusters than names, someone dialling in
    /// uninvited leaves more, and either way this declines to answer rather than
    /// pairing two leftovers that are not a pair.
    static func closingTheGap(
        _ named: [String: String],
        clusters: [Int],
        people: MeetingParticipants
    ) -> [String: String] {
        // Only the calendar. A conferencing window lists everyone including the
        // user and gives no way to tell which entry is them — which is why
        // `expectedOtherVoices` subtracts one above. Clusters here are the
        // `them` stream only, so the leftover name on that path can be the
        // user's own, and stamping it onto somebody else's voice is precisely
        // the lie the naming prompt exists to prevent. The count mismatch
        // normally declines for us; over-splitting by exactly one would not.
        guard people.source == .calendar else { return named }

        let attendees = people.names
        let clusters = Set(clusters)
        guard !attendees.isEmpty, clusters.count == attendees.count else { return named }

        let unnamed = clusters.filter { named["\($0)"] == nil }
        guard let cluster = unnamed.first, unnamed.count == 1 else { return named }

        // Every name the pass produced has to be somebody on the invitation. A
        // name it picked up from the room — a person being discussed, a customer
        // quoted — means the count below is counting different things, and the
        // leftover attendee is not the leftover voice.
        let taken = Set(named.values.map { $0.lowercased() })
        guard taken.allSatisfy({ name in attendees.contains { $0.lowercased() == name } }) else {
            return named
        }

        let spare = attendees.filter { !taken.contains($0.lowercased()) }
        guard let name = spare.first, spare.count == 1 else { return named }

        var closed = named
        closed["\(cluster)"] = name
        return closed
    }
}
