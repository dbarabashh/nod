import Foundation

/// Deciding whether the meeting has just said again something it already said.
///
/// Its own file for the same reason `LiveMeetingAnalyst+Recall.swift` is: the
/// pass in `LiveMeetingAnalyst.swift` reads the room, and this reads the pass's
/// own output back against the meeting's memory. Different question, different
/// call, and the one place a standing finding can be retired without the room
/// having said anything about it.
extension LiveMeetingAnalyst {
    /// Which of these the meeting has already said, decided by the model.
    ///
    /// The guards in `verify` refuse what can be refused on its face. This is
    /// the rest: "we need to research cheaper models" arriving an hour after
    /// "we should research cheaper models for titles" is one thing said twice,
    /// and nothing in the two strings says so. See
    /// `PromptLibrary.buildFindingSettlement` for why no comparison does either.
    ///
    /// Every standing finding goes, not a shortlist. A filter would have to
    /// find the pair before the model could judge it, and the pairs that need
    /// judging are the ones a filter cannot see: "ship the release" and "push
    /// v2 to production" share no word, and Apple's own sentence embeddings put
    /// them further apart (0.87) than two plainly different tasks (0.76). The
    /// list is short one-liners, so sending all of it costs less than being
    /// wrong about which half to send.
    ///
    /// Fails open. A finding the user should have seen and did not is the
    /// failure this whole file is written against, and a duplicate is the
    /// cheaper of the two mistakes by a wide margin — so a judge that errors,
    /// times out, or answers nonsense leaves the findings exactly as they were.
    func settle(_ fresh: [LiveFinding]) async -> [LiveFinding] {
        // A finding the model has already been told about is settled: it named
        // what it revises, and asking a second model to second-guess that is
        // how one promise ends up classified two ways on one call.
        let asking = fresh.filter { $0.revisionOf == nil }
        let standing = Array(findings.filter { $0.state == .standing }.suffix(Self.settlementDepth))
        // A first pass has nothing open to compare against, but it can still
        // hold two readings of one commitment — `[TWO AT ONCE]` is about the
        // fresh list alone, so two items are reason enough to ask.
        guard !asking.isEmpty, !standing.isEmpty || asking.count > 1 else { return fresh }

        let prompt = PromptLibrary.buildFindingSettlement(
            standing: standing.map { (kind: $0.kind.rawValue, text: $0.text) },
            fresh: asking.map { (kind: $0.kind.rawValue, text: $0.text) }
        )
        do {
            let verdicts = try await llm.completeJSON(
                system: prompt.system,
                user: prompt.user,
                as: PromptLibrary.FindingSettlement.self,
                primaryModel: llm.utilityModel
            )
            return Self.settle(fresh, asking: asking, standing: standing, by: verdicts.items)
        } catch {
            // A pause cancels the request, and that is not a fault to report.
            if Task.isCancelled {
                Log.llm.info("live: settlement cancelled, keeping all")
            } else {
                Log.llm.error("live: settlement failed, keeping all — \(error.localizedDescription)")
            }
            return fresh
        }
    }

    /// The model's half of the settlement, checked. Its own function for the
    /// same reason `verify` is: it is arithmetic over numbers a model chose,
    /// and every way of getting it wrong loses or duplicates a finding.
    ///
    /// Both indexes are 1-based into the two lists the prompt numbered. A
    /// verdict naming neither, naming a number out of range, or naming a
    /// finding a verdict has already spoken for is ignored, and the item it
    /// was about survives — the same fail-open the call site takes.
    nonisolated static func settle(
        _ fresh: [LiveFinding],
        asking: [LiveFinding],
        standing: [LiveFinding],
        by verdicts: [PromptLibrary.FindingVerdict]
    ) -> [LiveFinding] {
        var byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var settled: Set<UUID> = []
        // One original is revised once. Two items in a response can both point
        // at it, and honouring both leaves two live revisions of one finding —
        // two "changed X became Y" lines in the recap for one change of mind.
        var claimed = Set(fresh.compactMap(\.revisionOf))

        for verdict in verdicts {
            guard asking.indices.contains(verdict.heard - 1) else { continue }
            let heard = asking[verdict.heard - 1]
            // One verdict per item, the first that names it. A second is the
            // model contradicting itself, and taking the later one is how an
            // item a "repeat" dropped comes back as a cooldown-skipping change.
            guard settled.insert(heard.id).inserted else { continue }

            // The two lists are numbered separately, so both indexes are logged
            // — the whole change is justified by a measurement, and a verdict
            // nobody can attribute afterwards is a measurement nobody can make.
            // Numbers, never the text: this is `.info`.
            guard let index = verdict.open else {
                // A repeat naming nothing is this response repeating itself —
                // the prompt's one case for it. Which of the twins the model
                // numbers is its own choice, so the position is not the guard;
                // what is, is that a twin of the same kind is still standing to
                // be repeated. Of the items being judged, not of `fresh`: a
                // revision the pass declared is not up for this, and counting
                // it made a stray verdict drop the only finding in the
                // response. Same kind, for the reason the guard below the
                // switch exists — a dated commitment is not a repeat of the
                // vague follow-up beside it.
                if verdict.verdict.lowercased() == "repeat",
                   asking.contains(where: {
                       $0.id != heard.id && $0.kind == heard.kind && byID[$0.id] != nil
                   }) {
                    byID[heard.id] = nil
                    Log.llm.info("live: dropped — item \(verdict.heard) repeats one beside it")
                }
                continue
            }
            guard standing.indices.contains(index - 1) else { continue }
            let open = standing[index - 1]

            // A task and the decision behind it are not each other, in either
            // direction. `change` has always said so; `repeat` gained the
            // traffic when the pass's own claim started rejecting cross-kind
            // supersedes — and `repeat` is the destructive one, so a "book
            // thirty minutes with legal Thursday" read as a repeat of "talk to
            // legal before we sign" deletes the dated commitment outright.
            guard heard.kind == open.kind else { continue }

            switch verdict.verdict.lowercased() {
            case "repeat":
                byID[heard.id] = nil
                Log.llm.info("live: dropped — item \(verdict.heard) repeats open finding \(index)")
            case "change":
                guard !claimed.contains(open.id) else { continue }
                claimed.insert(open.id)
                byID[heard.id] = heard.revising(open.id)
                Log.llm.info("live: item \(verdict.heard) changes open finding \(index)")
            default:
                continue
            }
        }
        return fresh.compactMap { byID[$0.id] }
    }
}
