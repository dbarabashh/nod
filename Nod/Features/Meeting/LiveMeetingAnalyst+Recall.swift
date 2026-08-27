import Foundation

/// Bringing back what an earlier session already settled, while a new one is
/// running.
///
/// Lives on the analyst rather than beside it because there must be exactly one
/// thing deciding when to interrupt. Two schedulers, each politely rate-limited
/// on its own, still add up to twice the interruptions — and the user does not
/// experience them as two features.
extension LiveMeetingAnalyst {
    /// Deliberately mean. Three per meeting, at least four minutes apart, and
    /// never while a finding from this meeting is already on screen.
    ///
    /// The numbers are the product rule, not a tuning knob: one genuinely useful
    /// recall per meeting is the goal, and the failure mode being defended
    /// against is the second-best one arriving right behind the best and
    /// teaching the user to look away.
    static let recallsPerMeeting = 3
    static let recallInterval: TimeInterval = 240
    /// Below this the retrieval had nothing worth judging, and paying for a
    /// model call to be told so is waste. Above it the judge still rejects most
    /// of what it sees — this only decides what is worth *asking* about.
    static let recallFloor = 0.35

    func considerRecall(window: String) async {
        guard recallsUsed < Self.recallsPerMeeting else { return }
        guard notice == nil else { return }
        if let lastRecallAt, Date().timeIntervalSince(lastRecallAt) < Self.recallInterval { return }
        guard let session = currentMeetingID else { return }

        lastRecallAt = Date()

        // Before the memory search, and it takes the whole budget when it fires.
        // A promise the user made and has not kept outranks a fact from a
        // summary: one is owed to somebody in this conversation, the other is
        // merely true. It is also the cheaper question — the candidates are
        // picked locally, with no embedding call, so the common case of "no open
        // loop resembles this" costs nothing.
        if await surfaceOpenLoop(window: window, meetingID: session) { return }

        do {
            // Excludes the meeting in progress: what was said ten minutes ago is
            // not a recall, and the live pass already owns it.
            let matches = try await llm.searchKnowledge(query: window, matchCount: 6)
                .filter { $0.meetingID != session && $0.similarity >= Self.recallFloor }
            guard !matches.isEmpty else { return }

            let (system, user) = PromptLibrary.buildMemoryRecall(
                window: window,
                candidates: matches.map(\.content),
                language: recallLanguage
            )
            let verdict = try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.MemoryRecallResult.self
            )
            guard verdict.surface,
                  let index = verdict.source, index >= 1, index <= matches.count,
                  let text = verdict.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let kind = verdict.kind.flatMap(LiveRecall.Kind.init(rawValue:))
            else {
                Log.llm.info("live: recall considered, nothing worth surfacing")
                return
            }

            let source = matches[index - 1].meetingID
            guard let label = recallSourceLabel?(source) else { return }
            recallsUsed += 1
            Log.llm.info("live: recall surfaced kind=\(kind.rawValue) (\(recallsUsed)/\(Self.recallsPerMeeting))")
            raise(LiveRecall(kind: kind, text: text, sourceMeetingID: source, sourceLabel: label))
        } catch {
            Log.llm.error("live: recall failed: \(error.localizedDescription)")
        }
    }
}
