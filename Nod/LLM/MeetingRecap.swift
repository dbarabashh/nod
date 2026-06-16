import Foundation

/// Structured meeting recap returned by the summary LLM call. The LLM emits
/// this as a JSON object (via `response_format = json_object`); we render it
/// to the same markdown contract the UI already consumes, so downstream code
/// (`MeetingDetailView`, `buildTitle`) keeps treating `meeting.summary` as a
/// markdown string.
///
/// Speaker attribution lives in a typed field (`Action.owner`) rather than as
/// inline `[Me]`/`[Them]` markers in the text, so the old class of "LLM
/// leaked the raw transcript label into the recap" bugs is impossible by
/// construction.
struct MeetingRecap: Codable, Equatable {
    struct Topic: Codable, Equatable {
        let text: String
        let quote: String?
    }

    struct Decision: Codable, Equatable {
        let text: String
        let why: String?
    }

    struct Action: Codable, Equatable {
        let owner: String
        let task: String
        let when: String?
    }

    struct OpenQuestion: Codable, Equatable {
        let text: String
    }

    let topics: [Topic]
    let decisions: [Decision]
    let actions: [Action]
    let openQuestions: [OpenQuestion]

    var isPlaceholderFallback: Bool {
        topics.count == 1 &&
            decisions.isEmpty &&
            actions.isEmpty &&
            openQuestions.isEmpty &&
            topics[0].text.localizedCaseInsensitiveContains("too short or unclear")
    }

    enum CodingKeys: String, CodingKey {
        case topics
        case decisions
        case actions
        case openQuestions = "open_questions"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topics = (try? c.decode([Topic].self, forKey: .topics)) ?? []
        decisions = (try? c.decode([Decision].self, forKey: .decisions)) ?? []
        actions = (try? c.decode([Action].self, forKey: .actions)) ?? []
        openQuestions = (try? c.decode([OpenQuestion].self, forKey: .openQuestions)) ?? []
    }
}

extension MeetingRecap {
    /// Render to the existing `**Section**` markdown contract. Section headers
    /// stay in English (matches the previous prompt's behaviour and the UI's
    /// hardcoded expectations); bullet content is whatever language the LLM
    /// produced.
    func toMarkdown() -> String {
        let everythingEmpty = topics.isEmpty && decisions.isEmpty && actions.isEmpty && openQuestions.isEmpty
        var out: [String] = []

        out.append("**Topics covered**")
        if topics.isEmpty {
            // Only claim "transcript too short" when there's literally nothing
            // to say — otherwise a recap with only decisions/actions would
            // mislead the user into thinking the meeting failed to transcribe.
            out.append(everythingEmpty
                ? "- Transcript too short or unclear to recap reliably."
                : "- None.")
        } else {
            for t in topics {
                if let q = t.quote, !q.isEmpty {
                    out.append("- \(t.text) \"\(q)\"")
                } else {
                    out.append("- \(t.text)")
                }
            }
        }

        out.append("")
        out.append("**Decisions made**")
        if decisions.isEmpty {
            out.append("- None.")
        } else {
            for d in decisions {
                if let why = d.why, !why.isEmpty {
                    out.append("- \(d.text) — \(why)")
                } else {
                    out.append("- \(d.text)")
                }
            }
        }

        out.append("")
        out.append("**Action items**")
        if actions.isEmpty {
            out.append("- None.")
        } else {
            for a in actions {
                if let when = a.when, !when.isEmpty {
                    out.append("- \(a.owner) — \(a.task) (by \(when))")
                } else {
                    out.append("- \(a.owner) — \(a.task)")
                }
            }
        }

        out.append("")
        out.append("**Open questions**")
        if openQuestions.isEmpty {
            out.append("- None.")
        } else {
            for q in openQuestions {
                out.append("- \(q.text)")
            }
        }

        return out.joined(separator: "\n")
    }
}

private func cleaned(_ strings: [String]) -> [String] {
    strings
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// "Catch me up" (`.hero`) structured output: the three catch-up slots,
/// rendered as one short paragraph (matches the previous plain-text contract).
struct CatchUp: Codable {
    let currentTopic: String
    let positions: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case currentTopic = "current_topic"
        case positions
        case status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentTopic = (try? c.decode(String.self, forKey: .currentTopic)) ?? ""
        positions = (try? c.decode(String.self, forKey: .positions)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
    }

    func toMarkdown() -> String {
        let parts = cleaned([currentTopic, positions, status])
        return parts.isEmpty ? "Not enough context yet." : parts.joined(separator: " ")
    }
}

/// "Key points" (`.smartReply`) structured output: bullets grouped by priority
/// category, flattened into one list in the order decisions → facts → open
/// questions.
struct KeyPoints: Codable {
    let decisions: [String]
    let facts: [String]
    let openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case decisions
        case facts
        case openQuestions = "open_questions"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decisions = (try? c.decode([String].self, forKey: .decisions)) ?? []
        facts = (try? c.decode([String].self, forKey: .facts)) ?? []
        openQuestions = (try? c.decode([String].self, forKey: .openQuestions)) ?? []
    }

    func toMarkdown() -> String {
        let bullets = cleaned(decisions + facts + openQuestions)
        guard !bullets.isEmpty else { return "Not enough discussion yet." }
        return bullets.map { "- \($0)" }.joined(separator: "\n")
    }
}

/// "Suggest follow-up questions" (`.followUp`) structured output.
struct FollowUpQuestions: Codable {
    let questions: [String]

    enum CodingKeys: String, CodingKey { case questions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questions = (try? c.decode([String].self, forKey: .questions)) ?? []
    }

    func toMarkdown() -> String {
        let qs = cleaned(questions)
        guard !qs.isEmpty else { return "No grounded follow-up questions yet." }
        return qs.map { "- \($0)" }.joined(separator: "\n")
    }
}

/// "Suggest reply" (`.suggestReply`) structured output — a single spoken line.
/// JSON-wrapping makes the preamble leakage ("You could say:") the plain-text
/// prompt fought with a long FORBIDDEN list structurally impossible.
struct SuggestedReply: Codable {
    let reply: String

    enum CodingKeys: String, CodingKey { case reply }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
    }

    func toMarkdown() -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Not enough context yet — keep talking and try again."
            : trimmed
    }
}
