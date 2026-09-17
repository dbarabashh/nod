import Foundation

/// One reference to something in a connected product — a Linear issue, and
/// later a Notion page.
struct ProviderLinkItem: Identifiable, Equatable {
    let provider: IntegrationProvider
    let title: String
    let url: URL
    /// What the model said after the reference on the same line — a status,
    /// an assignee — kept as a fact beside the title rather than lost.
    var note: String?

    var id: URL {
        url
    }

    /// One line of an answer, if that line is a reference and nothing more
    /// than a short note after it.
    ///
    /// Asked a line at a time rather than a paragraph at a time: a reference
    /// almost always follows the sentence that introduces it, inside the same
    /// paragraph, and a rule that only recognised a block of pure links left
    /// exactly those references drawn as blue markdown text.
    ///
    /// A reference inside a sentence is not this — the sentence is the point,
    /// and it is drawn whole, with the reference inline (`AnswerText.inline`).
    ///
    /// `- [NOD-57 — Provide team access](https://linear.app/…) — In Progress`,
    /// bullet and note optional.
    static func item(in line: String) -> ProviderLinkItem? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        for bullet in ["- ", "* ", "• "] where rest.hasPrefix(bullet) {
            rest = rest.dropFirst(bullet.count)
        }
        guard rest.hasPrefix("["),
              let split = rest.range(of: "](", options: .backwards),
              let close = rest[split.upperBound...].firstIndex(of: ")")
        else { return nil }

        let title = rest[rest.index(after: rest.startIndex) ..< split.lowerBound]
        let link = rest[split.upperBound ..< close]
        let tail = rest[rest.index(after: close)...]
        guard let url = URL(string: String(link)),
              let provider = IntegrationProvider(linkHost: url.host()),
              !title.isEmpty, !title.contains("]"),
              let note = note(from: tail)
        else { return nil }
        return ProviderLinkItem(provider: provider, title: String(title), url: url, note: note)
    }

    private static let noteLeads: Set<Character> = ["—", "–", "-", ":", "(", "["]

    /// Nil when the tail is not a note but prose the link opened — a sentence
    /// stays a sentence. `.some(nil)` when there is no tail at all.
    private static func note(from tail: Substring) -> String?? {
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let lead = trimmed.first, noteLeads.contains(lead) else { return nil }
        var note = Substring(trimmed).drop { noteLeads.contains($0) || $0 == " " }
        while let last = note.last, last == "." || last == " " || last == "—" || last == "–" {
            note = note.dropLast()
        }
        let closers: [Character: Character] = ["(": ")", "[": "]"]
        if let closer = closers[lead], note.last == closer, !note.contains(lead) {
            note = note.dropLast()
        }
        return .some(note.isEmpty ? nil : String(note))
    }
}
