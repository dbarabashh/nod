import Foundation

/// One person invited to a calendar event.
///
/// The calendar is the only honest source for this. Reading the conferencing
/// app's window instead — which is what Nod did before — returns whatever the
/// application happens to label: a Google Meet call in Chrome came back as
/// sixteen "participants" made of toolbar buttons and the user's bookmarks,
/// against four people actually invited.
struct CalendarAttendee: Equatable {
    /// What to put on screen.
    let display: String
    /// The account this Mac is signed in as. `EventKit` answers this directly,
    /// so telling the user apart from everyone else never involves matching an
    /// address against anything.
    let isSelf: Bool
    /// The address the invitation carries, lowercased, when it carries one.
    ///
    /// Kept because it is the only thing here that can be matched against
    /// anything else. `display` is a name for a human to read — two people can
    /// share one, and one person shows up under three — so a room described by
    /// names alone cannot be told apart from a room of strangers. Address is
    /// what joins an attendee to `people.primary_email`, and that join is what
    /// says whether the person on this call is a colleague or a customer.
    ///
    /// `nil` for a local EventKit entry that names somebody without one.
    let email: String?

    init(display: String, isSelf: Bool, email: String? = nil) {
        self.display = display
        self.isSelf = isSelf
        self.email = email.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension CalendarAttendee {
    /// A person's name for display, from whatever the calendar actually holds.
    ///
    /// `EKParticipant.name` is a display name when the invite carried one and
    /// the raw address when it did not — and on a real calendar the second case
    /// dominates: of 67 people invited across two months here, 22 had a display
    /// name and 45 had only an address.
    ///
    /// So the address is read for a name, and *not* read when it plainly holds
    /// none. A wrong-looking name is worse than an address: "Dbarabashh" reads
    /// as a person Nod is confused about, where `dbarabashh@gmail.com` reads as
    /// what it is.
    static func display(from name: String) -> String {
        guard let local = emailLocalPart(of: name) else { return name }
        guard let words = nameWords(in: local) else { return name }
        return words.joined(separator: " ")
    }

    /// The part before `@`, with any `+tag` dropped — but only for something
    /// shaped like a single address. A display name that happens to contain an
    /// address ("Sales <sales@x.com>") is left alone.
    private static func emailLocalPart(of name: String) -> String? {
        let parts = name.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return nil }
        let local = parts[0].split(separator: "+", omittingEmptySubsequences: false)[0]
        return local.isEmpty ? nil : String(local)
    }

    /// The words of a name inside an address's local part, or nil when it holds
    /// none to find.
    private static func nameWords(in local: String) -> [String]? {
        let lowered = local.lowercased()
        guard !roleAddresses.contains(lowered) else { return nil }
        guard lowered.allSatisfy({ $0.isLetter || Self.separators.contains($0) }) else { return nil }

        let tokens = lowered.split(whereSeparator: { Self.separators.contains($0) })
        guard (1 ... 3).contains(tokens.count) else { return nil }

        // One token has to *be* a given name — nothing separates a first from a
        // last. Real given names sit inside a narrow length; past it the token
        // is a run-together first and last ("dbarabashh") that cannot be split
        // without guessing where.
        if tokens.count == 1 {
            guard (3 ... longestGivenName).contains(tokens[0].count) else { return nil }
        }
        return tokens.map { token in
            // A lone letter is an initial, and reads as one only with the dot.
            token.count == 1 ? "\(token.uppercased())." : token.capitalized
        }
    }

    private static let separators: Set<Character> = [".", "_", "-"]
    private static let longestGivenName = 9

    /// Addresses that belong to a desk rather than a person. Capitalising one
    /// invents a colleague called Info.
    private static let roleAddresses: Set<String> = [
        "info", "support", "noreply", "no-reply", "donotreply", "admin", "team",
        "hello", "contact", "billing", "sales", "hr", "office", "notifications",
        "nc-calendar", "meetings", "invite", "invites", "events", "help", "accounts"
    ]
}
