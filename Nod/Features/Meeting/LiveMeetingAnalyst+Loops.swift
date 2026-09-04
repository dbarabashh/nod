import Foundation

/// Raising something the user still owes, at the moment the room stands on it.
///
/// The other half of the loops feature. `LoopResolver` reads a finished meeting
/// and moves what the conversation resolved; this runs mid-sentence and says
/// nothing at all unless the thing being discussed *is* an open promise.
///
/// It shares the recall budget rather than getting its own. Two proactive passes
/// each politely rate-limited still add up to twice the interruptions, and the
/// user does not experience them as two features — the same argument
/// `LiveMeetingAnalyst+Recall` makes for living on the analyst at all.
extension LiveMeetingAnalyst {
    /// Fewer than the resolver's thirty. That call reads a whole transcript once
    /// and can afford a page of candidates; this one fires every pass, and the
    /// question it asks is narrower — a conversation is standing on one thing at
    /// a time, not on thirty.
    static let loopCandidates = 8

    /// True when a loop went on screen, so the caller knows not to also run the
    /// memory search. An open promise the user made outranks a fact from a
    /// summary: one is a thing they owe somebody, the other is a thing they knew.
    func surfaceOpenLoop(window: String, meetingID: UUID) async -> Bool {
        guard let openLoops else { return false }
        let loops = await openLoops()
        let candidates = await LoopCandidates.pick(
            from: loops,
            mentionedIn: window,
            excluding: meetingID,
            graph: loopGraph?() ?? .empty,
            limit: Self.loopCandidates
        )
        guard !candidates.isEmpty else { return false }

        do {
            let (system, user) = PromptLibrary.buildOpenLoopRecall(
                loops: candidates,
                window: window,
                language: recallLanguage
            )
            let verdict = try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.OpenLoopRecall.self
            )
            guard let recall = resolve(verdict, among: candidates) else {
                Log.llm.info("live: open loops considered, nothing worth surfacing")
                return false
            }
            guard !Task.isCancelled else { return false }
            recallsUsed += 1
            Log.llm.info("live: open loop surfaced (\(recallsUsed)/\(Self.recallsPerMeeting))")
            raise(recall)
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            Log.llm.error("live: open-loop recall failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The model's half of the contract, checked. An index out of range, an
    /// empty sentence, or a loop whose meeting we cannot name all mean no card
    /// — the last one because a claim about a session the user is not in, with
    /// no way to go and check it, is the one thing this surface refuses to make.
    private func resolve(
        _ verdict: PromptLibrary.OpenLoopRecall,
        among candidates: [ActionItem]
    ) -> LiveRecall? {
        guard let index = verdict.loop, candidates.indices.contains(index) else { return nil }
        guard let said = verdict.say?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else {
            return nil
        }
        let loop = candidates[index]
        guard let label = recallSourceLabel?(loop.meetingID) else { return nil }

        return LiveRecall(
            kind: Self.recallKind(for: loop.kind),
            text: said,
            sourceMeetingID: loop.meetingID,
            sourceLabel: label,
            origin: .openLoop(days: loop.daysOpen())
        )
    }

    /// How the card introduces it, taken from the loop's own kind rather than
    /// asked of the model. The classification was already made when the loop was
    /// raised, and asking a second model to redo it from one sentence is how the
    /// same promise ends up labelled two different ways on two different days.
    nonisolated static func recallKind(for kind: ActionItem.Kind) -> LiveRecall.Kind {
        switch kind {
        case .question: .unresolved
        case .decision: .decision
        case .action, .theirs, .followUp, .risk: .commitment
        }
    }
}
