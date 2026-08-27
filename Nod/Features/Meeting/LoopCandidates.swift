import Foundation

/// Which open loops a conversation might have moved.
///
/// A model call that carried every open loop would carry four hundred of them,
/// and most of a promise made in June has nothing to do with a call about
/// pricing. So the model is shown a short list, chosen here, cheaply and
/// locally — no embedding call, no round trip.
///
/// Two ways in, in this order. `LoopGraph` walks the entity edges the meeting
/// extractor already wrote: it finds a promise from a session about the same
/// project even when the two describe it in different words, or different
/// languages, which is most of the time here. What is left is topped up by the
/// shared-word filter below, which reaches the fifth of sessions the graph has
/// no entities for, and the loops whose wording is simply obvious.
///
/// The word filter is deliberately dumb, and stays because it is the tail rather
/// than the retrieval. Its only job is to be wrong in the safe direction — a
/// loop that reaches the model and is not mentioned costs a few tokens, and a
/// loop that never reaches it stays open forever. Precision is the model's
/// problem; recall is this one's.
enum LoopCandidates {
    /// Enough that a conversation touching several threads is fully covered,
    /// few enough that the prompt stays a page. Chosen for the prompt's size,
    /// not for any property of the loops.
    static let maximum = 30

    /// Words that appear in every meeting and therefore separate nothing.
    /// Ukrainian and English both, because the transcript is whichever the room
    /// spoke and the loops are whichever the recap wrote.
    private static let ignored: Set<String> = [
        "that", "this", "with", "from", "have", "will", "about", "there", "then",
        "what", "when", "need", "needs", "should", "would", "could", "make",
        "made", "into", "them", "they", "were", "been", "also", "just", "your",
        "щоб", "який", "яка", "яке", "цього", "цей", "той", "там", "тому",
        "потрібно", "треба", "буде", "було", "після", "перед", "разом", "тоді"
    ]

    /// Open loops from *other* meetings the conversation might have moved: what
    /// the graph reaches first, then what the wording reaches, up to `limit`.
    ///
    /// The meeting's own loops are excluded: they were raised from this very
    /// transcript minutes ago, and asking whether this conversation resolved
    /// what this conversation just raised is asking the model to agree with
    /// itself.
    ///
    /// An empty `graph` is the honest state of an account whose sessions have
    /// not been through entity extraction yet, not an error — the wording filter
    /// alone is what this did before the graph existed, and it still works.
    static func pick(
        from loops: [ActionItem],
        mentionedIn transcript: String,
        excluding meetingID: UUID,
        graph: LoopGraph.Index = .empty,
        limit: Int = maximum
    ) -> [ActionItem] {
        // Tokenised once and handed to both passes: the resolver calls this with
        // a whole meeting's transcript, and doing it twice is doing it twice.
        let spoken = words(in: transcript)
        guard !spoken.isEmpty else { return [] }

        var picked: [ActionItem] = []
        var seen: Set<UUID> = []

        if !graph.isEmpty {
            for loop in LoopGraph.loops(
                touching: LoopGraph.mentioned(in: spoken, among: graph),
                in: graph,
                among: loops,
                excluding: meetingID
            ) where picked.count < limit {
                picked.append(loop)
                seen.insert(loop.id)
            }
        }
        guard picked.count < limit else { return picked }

        picked.append(contentsOf: byWording(
            from: loops,
            spoken: spoken,
            excluding: meetingID,
            skipping: seen,
            limit: limit - picked.count
        ))
        return picked
    }

    /// The tail: loops the graph could not reach, ranked by how much of their
    /// wording the conversation used.
    private static func byWording(
        from loops: [ActionItem],
        spoken: Set<String>,
        excluding meetingID: UUID,
        skipping seen: Set<UUID>,
        limit: Int
    ) -> [ActionItem] {
        let elsewhere = loops.filter { $0.isReachable(excluding: meetingID) && !seen.contains($0.id) }

        var scored: [Scored] = []
        scored.reserveCapacity(elsewhere.count)
        for loop in elsewhere {
            // The room's own sentence counts alongside the extractor's summary of
            // it. "Send Anna the deck" and «я скину презентацію» are the same
            // promise, and only one of them is what anybody will say again.
            let overlap = words(in: loop.matchable).intersection(spoken).count
            guard overlap > 0 else { continue }
            scored.append(Scored(loop: loop, overlap: overlap))
        }

        // Ties to the older loop: the whole point is the one that has been
        // forgotten, and a tie broken towards the recent one quietly buries it.
        scored.sort { left, right in
            if left.overlap != right.overlap { return left.overlap > right.overlap }
            return (left.loop.createdAt ?? .distantFuture) < (right.loop.createdAt ?? .distantFuture)
        }
        return scored.prefix(limit).map(\.loop)
    }

    private struct Scored {
        let loop: ActionItem
        let overlap: Int
    }

    /// Content words, lowercased. Four characters is the floor: shorter than
    /// that and English is mostly grammar, while Ukrainian is mostly endings.
    static func words(in text: String) -> Set<String> {
        Set(TextTokens.contentWords(in: text, longerThan: 4, excluding: ignored))
    }
}
