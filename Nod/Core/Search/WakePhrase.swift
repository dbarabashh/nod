import Foundation

/// Finds "Hey Nod, …" in a line of transcript and hands back what came after.
///
/// A matcher over text Nod is already producing, not a second audio path. The
/// microphone is transcribed continuously while a meeting runs, so a wake word
/// costs nothing more than reading the lines that arrive — and a dedicated
/// listener would be a second always-on capture of the same room, which is a
/// privacy claim we would rather not have to make.
///
/// Pure and table-driven, the way `QuestionIntent` is. Speech recognition
/// punctuates and capitalises the name however it likes, and it mishears it:
/// "Hey Nod" comes back as "Hey, Nod.", "hey not", "Hey node". The table
/// carries those, because a wake word that only works when the transcript is
/// perfect does not work.
enum WakePhrase {
    /// What Nod may be called.
    ///
    /// Most of this list is not the name — it is what a transcriber returns
    /// when somebody says the name. Whisper has no idea the word is a product,
    /// so it reaches for the nearest real word in whatever language it decided
    /// the speaker is using, and the nearest real word is almost never "Nod".
    /// Observed: "Гей, Нот" for a Ukrainian speaker saying "Hey Nod" — which is
    /// what sent this list back for a second pass.
    ///
    /// Cheap to be generous here, because a name only counts at the start of a
    /// sentence or after a greeting (see `request(in:)`). "нот" is a real word
    /// in the middle of a Ukrainian sentence and never triggers there.
    private static let names = [
        "nod", "node", "not", "nought", "knot", "note", "nada",
        "нод", "нот", "ноут", "ноуд", "нода", "ноте", "нат"
    ]

    /// What may open the address. Empty string included on purpose: "Nod, what
    /// is …" is how people speak to something once they are used to it.
    private static let greetings = [
        "hey", "hi", "hello", "ok", "okay", "yo",
        "гей", "хей", "привіт", "окей", "ок",
        "эй", "привет"
    ]

    /// The request, with the address stripped, or nil when the line was not
    /// addressed to Nod.
    ///
    /// Returns nil for an address with nothing after it too. "Hey Nod" on its
    /// own is somebody getting the room's attention, and answering a request
    /// nobody made is the failure mode this whole surface is trying to avoid.
    static func request(in line: String) -> String? {
        let words = tokens(of: line)
        guard !words.isEmpty else { return nil }

        for (index, word) in words.enumerated() {
            guard names.contains(word) else { continue }
            // A bare name only counts when it opens the sentence — mid-sentence
            // it is far more likely to be the word "not", or the product being
            // talked about rather than talked to.
            let addressed = index == 0 || greetings.contains(words[index - 1])
            guard addressed, index + 1 < words.count else { continue }
            return rest(of: line, after: words[0 ... index])
        }
        return nil
    }

    /// True when the line addresses Nod at all, whether or not it asked for
    /// anything. Kept separate so a bare "Hey Nod" can be answered by prompting
    /// rather than by silence.
    static func isAddressed(_ line: String) -> Bool {
        let words = tokens(of: line)
        return words.enumerated().contains { index, word in
            names.contains(word) && (index == 0 || greetings.contains(words[index - 1]))
        }
    }

    private static func tokens(of line: String) -> [String] {
        line
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Everything after the address, taken from the original line so the
    /// request keeps its case, its punctuation and its numbers.
    private static func rest(of line: String, after address: ArraySlice<String>) -> String? {
        guard let last = address.last else { return nil }
        // Search case-insensitively for the final word of the address, then cut
        // after it. Working from the original avoids rebuilding the sentence
        // out of lowercased tokens, which would hand the model "q3 pricing" for
        // a line that said "Q3 pricing".
        guard let range = line.range(of: last, options: [.caseInsensitive]) else { return nil }
        let tail = line[range.upperBound...]
            .drop { !$0.isLetter && !$0.isNumber }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }
}
