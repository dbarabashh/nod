import Foundation

/// One typed question for a System One model (TypeSafe's Jev): it answers with
/// a probability or a pick from a closed set, never with text. The wire shape
/// is TypeSafe's `POST /v1/systemone`, relayed by `llm-proxy` as `kind: judge`.
enum JudgeQuestion: Encodable, Equatable {
    /// Whether a condition holds. The answer is the probability of yes.
    case noul(String, yes: String? = nil, no: String? = nil)
    /// One of a closed set. `options` maps each key to what picking it means.
    case choice(String, options: [String: String])

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .noul(instructions, yes, no):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            if let yes, let no {
                try container.encode(["true": yes, "false": no], forKey: .criteria)
            }
        case let .choice(instructions, options):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(options, forKey: .criteria)
        }
    }
}

/// What a judgment is for, because what it carries differs: a typed question
/// is the user's own words, a recall check is the room's. The proxy can allow
/// one without the other.
enum JudgePurpose: String, Encodable {
    case question
    case recall
}

protocol JudgeRequest: Encodable {
    var purpose: JudgePurpose { get }
}

struct JudgeAnswer: Decodable, Equatable {
    var noul: Double?
    var choice: String?
    var confidence: Double?
}

extension [String: JudgeAnswer] {
    /// Yes or no, or nil while the model is between the two. A probability
    /// near one half is "as likely as not", not a weak yes, and the caller has
    /// a fallback that is better than a coin.
    ///
    /// The bar for no is the higher one. Here a yes adds something to a prompt
    /// and a no takes it away, and a block that should not have been there
    /// costs room while one that should have been costs the answer.
    func holds(_ id: String, atLeast yes: Double = 0.7, atMost no: Double = 0.15) -> Bool? {
        guard let probability = self[id]?.noul else { return nil }
        if probability >= yes { return true }
        if probability <= no { return false }
        return nil
    }

    /// The pick, or nil when the distribution is too flat to act on.
    func picked(_ id: String, confidence floor: Double = 0.6) -> String? {
        guard let answer = self[id], let choice = answer.choice, (answer.confidence ?? 0) >= floor else { return nil }
        return choice
    }
}
