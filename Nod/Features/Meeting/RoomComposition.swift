import Foundation

/// Whether everybody on this call works here.
///
/// The question a live lookup has to answer before it draws anything: reading a
/// tracker onto the screen is safe in a team meeting and is a disclosure in a
/// customer call, and the two look identical from inside the recording. The
/// calendar is the only thing that can tell them apart, because it is the only
/// place the people in the room are named as addresses rather than as voices.
///
/// Conservative by construction. Every way of *not knowing* — no calendar, an
/// attendee with no address, an organization whose directory has not loaded —
/// resolves to `outsidersPresent`, for the same reason `KnowledgeChatStore`'s
/// calendar block never reports an empty window as "you are free": an account
/// whose sync has not landed looks exactly like an empty room, and guessing
/// wrong in that direction is the expensive one.
enum RoomComposition: Equatable {
    /// Nobody else is here. Not a room at all — one person at their own Mac.
    case solo
    /// Every other attendee is a colleague.
    case colleaguesOnly
    /// Somebody in the room is not accounted for, or the room cannot be
    /// established while somebody else is plainly in it.
    case outsidersPresent

    var mayReadFreely: Bool {
        self != .outsidersPresent
    }

    /// - Parameters:
    ///   - attendees: the calendar entry's invitees, the user included. Empty
    ///     when there is no invitation, which is most recordings.
    ///   - colleagues: every address the organization directory knows.
    ///   - hasRemoteVoice: whether any speech has arrived on the system-audio
    ///     stream. The only live signal that somebody else is actually present:
    ///     a call means voices coming out of the speakers, and no call means
    ///     nothing has come out of them.
    static func of(
        attendees: [CalendarAttendee],
        colleagues: Set<String>,
        hasRemoteVoice: Bool
    ) -> RoomComposition {
        let others = attendees.filter { !$0.isSelf }

        // Nobody invited and nobody audible. There is no audience to disclose
        // to: the screen belongs to the person asking, and what comes back is
        // their own account's data.
        //
        // This is the case the first cut got wrong. It treated "no calendar
        // entry" as "a room we cannot see into" and refused — which is right
        // for a call whose invitation Nod never saw, and wrong for the far
        // commoner thing, somebody recording alone. The two are told apart by
        // the speakers: a call Nod was not invited to still puts voices through
        // them.
        if others.isEmpty, !hasRemoteVoice { return .solo }

        // Somebody is here — audible, invited, or both — and the invitation is
        // the only thing that can name them. Without one, or with one name on
        // it that the directory does not know, the room is not ours.
        guard !others.isEmpty else { return .outsidersPresent }
        let known = others.allSatisfy { attendee in
            guard let email = attendee.email else { return false }
            return colleagues.contains(email)
        }
        return known ? .colleaguesOnly : .outsidersPresent
    }

    /// Directory addresses, normalised the way `CalendarAttendee` normalises
    /// its own — both sides have to agree on case for the match to mean
    /// anything, and one of them comes from a calendar server.
    static func colleagueAddresses(_ emails: [String?]) -> Set<String> {
        Set(
            emails
                .compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}
