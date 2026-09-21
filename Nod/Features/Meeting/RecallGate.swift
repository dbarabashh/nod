import Foundation

/// Which recall candidates the room is actually standing on, asked as one
/// typed question per candidate before the model that writes the card is asked
/// anything.
///
/// It only ever takes candidates away. Most passes have nothing worth raising,
/// and saying so is a closed question — so it is answered by a model built for
/// closed questions, and the writer is called only for what is left. A
/// candidate the gate is unsure of stays in: the cost of a wrong no here is a
/// reminder that never appeared, and nobody sees that to complain about it.
enum RecallGate {
    struct Request: JudgeRequest {
        struct State: Encodable {
            let said: String
            let candidates: [String]
        }

        let purpose = JudgePurpose.recall
        let state: State
        let questions: [String: JudgeQuestion]
    }

    /// The end of the window: what the room is on now, not what it was on
    /// four minutes ago.
    static let saidLength = 4000
    /// A whole indexed chunk. Retrieval matched it for a sentence that can be
    /// anywhere in it, and judged on its first half it is only ever "the same
    /// topic".
    static let candidateLength = 1500
    /// Stricter than a block in a prompt: a wrong no here is a reminder that
    /// never appears, which nobody sees and so nobody reports. Held this low
    /// until the gate has been measured on Ukrainian transcripts.
    static let sureNo = 0.05

    static func request(window: String, candidates: [String]) -> Request {
        var questions: [String: JudgeQuestion] = [:]
        for index in candidates.indices {
            questions[key(index)] = .noul(
                "Is the conversation in `said` about the same specific matter as `candidates[\(index)]`?",
                yes: "The same commitment, decision, question or fact is being discussed, in any language or wording",
                no: "At most the same project, person or topic comes up, or nothing in common at all"
            )
        }
        return Request(
            state: Request.State(
                said: String(window.suffix(saidLength)),
                candidates: candidates.map { String($0.prefix(candidateLength)) }
            ),
            questions: questions
        )
    }

    /// The candidates that were not ruled out, in their original order.
    static func kept(_ count: Int, given answers: [String: JudgeAnswer]) -> [Int] {
        (0 ..< count).filter { answers.holds(key($0), atMost: sureNo) != false }
    }

    private static func key(_ index: Int) -> String {
        "candidate_\(index)"
    }
}
