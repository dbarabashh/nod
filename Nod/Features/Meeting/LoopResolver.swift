import Foundation

/// Closes what a later conversation closed.
///
/// The reason a loop is not a checklist row. A promise made in June sits open
/// until somebody ticks it, and nobody ticks it — but the July call where it was
/// said to be done is already recorded, and nothing was reading it.
///
/// Its own type rather than more of `MeetingEnrichment`, for the reason
/// `ProposalRaiser` is its own: enrichment is about making *this* meeting
/// findable, and this is about every meeting before it. They fail differently,
/// and an account with one meeting should make this produce nothing at all.
@MainActor
struct LoopResolver {
    let llm: LLMProxyClient
    let items: ActionItemStore

    /// Which rule moved a loop, versioned. A rule that turns out to close
    /// things wrongly has to be findable afterwards.
    static let resolver = "meeting-said-so/1"

    /// Below this the model is guessing from a fragment, and a guess that moves
    /// somebody's promise is worse than leaving it open.
    static let minimumTranscript = 400

    func resolve(after meeting: Meeting, transcript: String, graph: LoopGraph.Index = .empty) async {
        guard transcript.count >= Self.minimumTranscript else { return }
        // The same slice the prompt shows. Choosing candidates from words the
        // model never sees is choosing them on evidence it cannot check.
        let read = PromptLibrary.loopTranscript(transcript)
        let candidates = await LoopCandidates.pick(
            from: items.openLoops(),
            mentionedIn: read,
            excluding: meeting.id,
            graph: graph
        )
        guard !candidates.isEmpty else { return }

        let prompt = PromptLibrary.buildLoopResolution(
            loops: candidates,
            transcript: read,
            meetingTitle: meeting.displayTitle(dateFormatter: Meeting.listDateFormatter)
        )
        let moves: PromptLibrary.LoopMoves
        do {
            moves = try await llm.completeJSON(
                system: prompt.system,
                user: prompt.user,
                as: PromptLibrary.LoopMoves.self,
                primaryModel: llm.utilityModel
            )
        } catch {
            Log.llm.error("loops: reading the meeting failed — \(error.localizedDescription)")
            return
        }

        let applied = await apply(moves, to: candidates, from: meeting)
        Log.llm.info("loops: \(meeting.id) moved \(applied) of \(candidates.count) candidate(s)")
    }

    /// Applies what survives checking.
    ///
    /// The model answers with numbers against the list it was shown, and every
    /// number is checked back against that list — a number outside it is not a
    /// loop, whatever it looks like. Same rule the tool router follows, and for
    /// the same reason: the model proposes, code decides.
    private func apply(
        _ moves: PromptLibrary.LoopMoves,
        to candidates: [ActionItem],
        from meeting: Meeting
    ) async -> Int {
        var moved = 0
        var seen: Set<UUID> = []
        for move in moves.moved {
            guard candidates.indices.contains(move.loop) else {
                Log.llm.error("loops: ignored out-of-range \(move.loop)")
                continue
            }
            guard let state = Self.state(for: move.to) else { continue }
            let loop = candidates[move.loop]
            // One move per loop per meeting. A model that names the same number
            // twice is not more certain about it.
            guard seen.insert(loop.id).inserted else { continue }

            let said = move.said?.nilIfBlank
            await items.move(
                loop,
                to: state,
                actor: .system,
                reason: said.map { "\"\($0)\"" } ?? "said in \(meeting.displayTitle(dateFormatter: Meeting.listDateFormatter))",
                evidence: [.init(provider: nil, key: nil, url: nil, meetingID: meeting.id, idx: nil)],
                confidence: 0.7,
                resolver: Self.resolver
            )
            moved += 1
        }
        return moved
    }

    /// The three verbs the prompt allows, and nothing else.
    ///
    /// `done` lands on `probablyDone` and never on closure: somebody saying
    /// they sent a thing is good evidence and not the person who was waiting
    /// for it confirming they got it. Closure stays with a person — see
    /// `LoopClosure`.
    nonisolated static func state(for verb: String) -> ActionItem.LoopState? {
        switch verb.lowercased() {
        case "done": .probablyDone
        case "progressed": .inProgress
        case "blocked": .blocked
        default: nil
        }
    }
}
