import Foundation

/// Structured meeting recap returned by the summary LLM call. The LLM emits
/// this as a JSON object (via `response_format = json_object`); we render it
/// to the `**Section**` + `- bullet` markdown contract the UI already consumes,
/// so downstream code (`MeetingDetailView`, `buildTitle`) keeps treating
/// `meeting.summary` as a markdown string.
///
/// The recap is a flat list of named `sections`, each with bullets — the model
/// (or the chosen `SummaryTemplate`) decides what the sections are, so an
/// interview recap reads differently from a standup. Speaker attribution lives
/// inside the bullet text (resolved to a name/role by the prompt), never as raw
/// `[Me]`/`[Them]` markers.
struct MeetingRecap: Codable, Equatable {
    struct Bullet: Codable, Equatable {
        let text: String
        /// Optional 3-10 word verbatim quote from the transcript — the grounding
        /// tripwire carried over from the typed recap. Rendered in quotes.
        let quote: String?

        init(text: String, quote: String? = nil) {
            self.text = text
            self.quote = quote
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
            quote = try? c.decodeIfPresent(String.self, forKey: .quote)
        }
    }

    struct Section: Codable, Equatable {
        /// What a section holds, said by the model rather than read off its
        /// heading. Topic headings are free text in the user's language, and a
        /// keyword match on them counts "Marketing spending" as unresolved and
        /// "Відкриття офісу" as an open question. nil on recaps written before
        /// the field existed, which still count by heading.
        enum Kind: String, Codable {
            case overview, topic, decisions, unresolved, facts, other
        }

        let title: String
        let bullets: [Bullet]
        let kind: Kind?

        init(title: String, bullets: [Bullet], kind: Kind? = nil) {
            self.title = title
            self.bullets = bullets
            self.kind = kind
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            bullets = (try? c.decode([Bullet].self, forKey: .bullets)) ?? []
            kind = try? c.decodeIfPresent(Kind.self, forKey: .kind)
        }
    }

    /// A single action item, emitted by the recap in a dedicated top-level
    /// `action_items` array (NOT as a `sections` entry) so the app can promote
    /// each to a first-class, checkable to-do. `deadline` is the verbatim
    /// deadline if one was stated.
    ///
    /// `owner` is not an assignee field and does not become one: the person is
    /// still named inside `text`, and this stays a single-user product. It
    /// answers one question the checklist cannot work out for itself — is this
    /// the user's to do? — and it is set only when the answer is no. A meeting
    /// the user sat in on without speaking is otherwise all commitments and no
    /// tasks, and the recap had no way to say so except by dropping them.
    struct Action: Codable, Equatable {
        let text: String
        let deadline: String?
        let owner: String?

        init(text: String, deadline: String? = nil, owner: String? = nil) {
            self.text = text
            self.deadline = deadline
            self.owner = owner
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
            deadline = try? c.decodeIfPresent(String.self, forKey: .deadline)
            owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        }

        /// Somebody other than the user committed to this. A blank string is
        /// the model's own way of saying "nobody in particular" and means the
        /// same as the field being absent.
        var isSomeoneElses: Bool {
            guard let owner else { return false }
            return !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    let sections: [Section]
    let actionItems: [Action]

    init(sections: [Section], actionItems: [Action] = []) {
        self.sections = sections
        self.actionItems = actionItems
    }

    /// Lenient decode. New rows carry `{"sections":[…]}`. Rows generated before
    /// the dynamic-section recap shipped carry the legacy
    /// `{topics,decisions,actions,open_questions}` shape — map those onto
    /// sections so an old recap still renders if it's ever re-serialized.
    /// Display never depends on this (the rendered markdown lives in
    /// `meeting.summary`), so a fully unrecognised payload decodes to empty
    /// rather than throwing and breaking the parent `Meeting` decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let sections = try? c.decode([Section].self, forKey: .sections) {
            self.sections = sections
            actionItems = (try? c.decode([Action].self, forKey: .actionItems)) ?? []
            return
        }
        sections = Self.legacySections(from: c)
        actionItems = Self.legacyActions(from: c)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sections, forKey: .sections)
        try c.encode(actionItems, forKey: .actionItems)
    }

    enum CodingKeys: String, CodingKey {
        case sections
        case actionItems = "action_items"
        // Legacy keys, decode-only.
        case topics
        case decisions
        case actions
        case openQuestions = "open_questions"
    }

    private struct LegacyTopic: Decodable { let text: String?; let quote: String? }
    private struct LegacyDecision: Decodable { let text: String?; let why: String? }
    private struct LegacyAction: Decodable { let owner: String?; let task: String?; let when: String? }
    private struct LegacyOpen: Decodable { let text: String? }

    private static func legacySections(from c: KeyedDecodingContainer<CodingKeys>) -> [Section] {
        var out: [Section] = []
        if let topics = try? c.decode([LegacyTopic].self, forKey: .topics), !topics.isEmpty {
            out.append(Section(
                title: "Topics covered",
                bullets: topics.map { Bullet(text: $0.text ?? "", quote: $0.quote) }
            ))
        }
        if let decisions = try? c.decode([LegacyDecision].self, forKey: .decisions), !decisions.isEmpty {
            out.append(Section(
                title: "Decisions made",
                bullets: decisions.map { d in
                    Bullet(text: [d.text, d.why].compactMap { $0 }.joined(separator: " — "))
                }
            ))
        }
        if let open = try? c.decode([LegacyOpen].self, forKey: .openQuestions), !open.isEmpty {
            out.append(Section(title: "Open questions", bullets: open.map { Bullet(text: $0.text ?? "") }))
        }
        return out
    }

    /// Legacy `actions` (the pre-dynamic-section `{owner,task,when}` shape) map
    /// onto the new structured `actionItems`. The owner is folded into `text`
    /// (single-user product has no owner field) and `when` becomes `deadline`.
    private static func legacyActions(from c: KeyedDecodingContainer<CodingKeys>) -> [Action] {
        guard let actions = try? c.decode([LegacyAction].self, forKey: .actions) else { return [] }
        return actions.map { a in
            let owner = a.owner ?? ""
            let task = a.task ?? ""
            let text = owner.isEmpty ? task : "\(owner) — \(task)"
            return Action(text: text, deadline: a.when)
        }
    }

    /// True when no section carries any bullet — the model returned nothing
    /// grounded. Distinct from the explicit "too short" placeholder.
    var isEmpty: Bool {
        sections.allSatisfy(\.bullets.isEmpty)
    }

    /// True for the model's explicit "couldn't recap" fallback — one section,
    /// one bullet, naming the too-short/unclear reason. Kept so the retry path
    /// can tell a real fallback from a sparse-but-valid recap.
    var isPlaceholderFallback: Bool {
        guard sections.count == 1, sections[0].bullets.count == 1 else { return false }
        return sections[0].bullets[0].text.localizedCaseInsensitiveContains("too short or unclear")
    }

    /// Where a bullet sits, so a view can name the one being edited without
    /// carrying indices around.
    struct BulletID: Hashable {
        let section: Int
        let bullet: Int
    }

    /// The recap with one bullet rewritten by hand.
    ///
    /// The quote goes with it. A bullet's quote is a verbatim line from the
    /// transcript, carried so a reader can check the recap against what was
    /// actually said — once somebody edits the sentence it was attached to, it
    /// no longer stands behind anything, and leaving it there would dress a
    /// human correction up as something the transcript confirms.
    ///
    /// An empty edit removes the bullet: clearing the text of a line you are
    /// correcting is how a person deletes it, and a blank bullet renders as a
    /// stray dash nobody can get rid of.
    func replacing(_ id: BulletID, with text: String) -> MeetingRecap {
        guard sections.indices.contains(id.section),
              sections[id.section].bullets.indices.contains(id.bullet)
        else { return self }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rebuilt = sections
        var bullets = rebuilt[id.section].bullets
        if trimmed.isEmpty {
            bullets.remove(at: id.bullet)
        } else {
            bullets[id.bullet] = Bullet(text: trimmed, quote: nil)
        }
        rebuilt[id.section] = Section(title: rebuilt[id.section].title, bullets: bullets, kind: rebuilt[id.section].kind)
        // A section with nothing left in it is not a heading, it is a hole.
        rebuilt.removeAll { $0.bullets.isEmpty }
        return MeetingRecap(sections: rebuilt, actionItems: actionItems)
    }

    func toMarkdown() -> String {
        Self.markdown(for: sections)
    }

    /// Render a (possibly partial, mid-stream) section list to the
    /// `**Section**` + `- bullet` markdown the inline renderer consumes. Shared
    /// by the final recap and the live streaming preview.
    static func markdown(for sections: [Section]) -> String {
        let nonEmpty = sections.filter { !$0.bullets.isEmpty }
        guard !nonEmpty.isEmpty else {
            return "- Transcript too short or unclear to recap reliably."
        }
        var blocks: [String] = []
        for section in nonEmpty {
            var lines = ["**\(section.title)**"]
            for bullet in section.bullets {
                if let q = bullet.quote, !q.isEmpty {
                    lines.append("- \(bullet.text) \"\(q)\"")
                } else {
                    lines.append("- \(bullet.text)")
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Streaming

    /// Extracts the fully-closed `Section` objects from a partially-streamed
    /// `{"sections":[ … ]}` payload, ignoring the trailing element still being
    /// produced. Returns `[]` until the first section closes. Lets the recap
    /// fill in section-by-section live instead of popping in at the end.
    static func partialSections(fromStreamingJSON raw: String) -> [Section] {
        let chars = Array(raw)
        guard let arrayStart = sectionsArrayStart(in: chars) else { return [] }
        let decoder = JSONDecoder()
        var sections: [Section] = []
        var i = arrayStart
        while i < chars.count {
            // Skip whitespace and separators between elements.
            while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\r" || chars[i] == "\t" || chars[i] == "," {
                i += 1
            }
            guard i < chars.count else { break }
            if chars[i] == "]" { break }
            guard chars[i] == "{" else { i += 1; continue }
            guard let close = matchingBrace(in: chars, from: i) else { break }
            let objectString = String(chars[i ... close])
            if let data = objectString.data(using: .utf8),
               let section = try? decoder.decode(Section.self, from: data) {
                sections.append(section)
            }
            i = close + 1
        }
        return sections
    }

    /// Index of the character immediately after the `[` that opens the
    /// `"sections"` array.
    private static func sectionsArrayStart(in chars: [Character]) -> Int? {
        let key = Array("\"sections\"")
        guard let keyStart = firstRange(of: key, in: chars) else { return nil }
        var i = keyStart + key.count
        while i < chars.count, chars[i] != "[" {
            // Bail if we hit the value start that isn't an array (malformed).
            if chars[i] == "{" { return nil }
            i += 1
        }
        return i < chars.count ? i + 1 : nil
    }

    /// Index of the `}` matching the `{` at `start`, honoring string literals
    /// and escapes. nil when the object hasn't finished streaming.
    private static func matchingBrace(in chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    private static func firstRange(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0 ... (haystack.count - needle.count) {
            var matched = true
            for j in 0 ..< needle.count where haystack[start + j] != needle[j] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
