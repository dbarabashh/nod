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
struct MeetingRecap: Codable {
    struct Topic: Codable {
        let text: String
        let quote: String?
    }

    struct Decision: Codable {
        let text: String
        let why: String?
    }

    struct Action: Codable {
        let owner: String
        let task: String
        let when: String?
    }

    struct OpenQuestion: Codable {
        let text: String
    }

    let topics: [Topic]
    let decisions: [Decision]
    let actions: [Action]
    let openQuestions: [OpenQuestion]

    enum CodingKeys: String, CodingKey {
        case topics
        case decisions
        case actions
        case openQuestions = "open_questions"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topics        = (try? c.decode([Topic].self,         forKey: .topics))        ?? []
        decisions     = (try? c.decode([Decision].self,      forKey: .decisions))     ?? []
        actions       = (try? c.decode([Action].self,        forKey: .actions))       ?? []
        openQuestions = (try? c.decode([OpenQuestion].self,  forKey: .openQuestions)) ?? []
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
