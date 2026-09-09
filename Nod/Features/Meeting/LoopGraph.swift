import Foundation

/// Which open loops a conversation is standing on, answered by walking the
/// entity graph rather than by counting shared words.
///
/// `LoopCandidates` compares the transcript to the loop's own sentence, which
/// works only when both happen to use the same wording — and a promise recorded
/// as "send the updated deck" is invisible to a room saying "коли буде презентація".
/// The graph does not care: both meetings carry the same project, and the edge
/// is already there.
///
/// Deliberately built on things and not on people. Nod has no meeting bot, so
/// there is no participant list — a name against a voice comes from a model
/// guessing, on the minority of sessions that are diarized at all. Identity is
/// the least reliable thing this product knows and projects are among the most,
/// so the retrieval that has to work every time is built on those, and a
/// resolved person stays a bonus rather than a prerequisite.
enum LoopGraph {
    /// An entity beside the content words of its name, tokenised once when the
    /// index is built rather than on every question asked of it.
    struct Named: Equatable {
        let entity: Entity
        let tokens: Set<String>
    }

    /// The graph, small enough to hold. Both tables are per-user and in the low
    /// thousands, so the whole traversal is a dictionary lookup — no round trip
    /// per pass, and nothing for a live meeting to wait on.
    struct Index: Equatable {
        let entities: [Named]
        /// Which entities each meeting carries.
        let byMeeting: [UUID: Set<UUID>]

        init(entities: [Entity], byMeeting: [UUID: Set<UUID>]) {
            self.entities = entities.map { Named(entity: $0, tokens: LoopCandidates.words(in: $0.name)) }
            self.byMeeting = byMeeting
        }

        var isEmpty: Bool {
            entities.isEmpty || byMeeting.isEmpty
        }

        static let empty = Index(entities: [], byMeeting: [:])
    }

    /// Entities the conversation is actually naming.
    ///
    /// Through `EntityMatcher`, which is where both ways of answering this
    /// question live. The transcript takes the every-word-in-any-order form: a
    /// graph entered through the wrong door returns confident nonsense rather
    /// than no answer, and "Nod mobile" and "mobile carrier billing" share a
    /// word and nothing else.
    static func mentioned(in spoken: Set<String>, among index: Index) -> [Entity] {
        guard !spoken.isEmpty else { return [] }
        return index.entities
            .filter { EntityMatcher.names($0.tokens, spokenIn: spoken) }
            .map(\.entity)
    }

    /// Open loops from meetings that carry any of those entities, most-shared
    /// first.
    ///
    /// Ordered by how much of the conversation's subject the loop's meeting was
    /// also about, and ties broken to the older loop — the same rule
    /// `LoopCandidates` sorts by, and for the same reason: the point of this
    /// screen is the promise nobody has thought about, and a tie broken towards
    /// the recent one quietly buries it.
    static func loops(
        touching entities: [Entity],
        in index: Index,
        among loops: [ActionItem],
        excluding meetingID: UUID
    ) -> [ActionItem] {
        guard !entities.isEmpty else { return [] }
        let wanted = Set(entities.map(\.id))

        var shared: [UUID: Int] = [:]
        for (meeting, carried) in index.byMeeting where meeting != meetingID {
            let overlap = carried.intersection(wanted).count
            if overlap > 0 { shared[meeting] = overlap }
        }
        guard !shared.isEmpty else { return [] }

        var reached: [Reached] = []
        for loop in loops where loop.isReachable(excluding: meetingID) {
            guard let overlap = shared[loop.meetingID] else { continue }
            reached.append(Reached(loop: loop, shared: overlap))
        }

        reached.sort { left, right in
            if left.shared != right.shared { return left.shared > right.shared }
            return (left.loop.createdAt ?? .distantFuture) < (right.loop.createdAt ?? .distantFuture)
        }
        return reached.map(\.loop)
    }

    private struct Reached {
        let loop: ActionItem
        let shared: Int
    }
}
