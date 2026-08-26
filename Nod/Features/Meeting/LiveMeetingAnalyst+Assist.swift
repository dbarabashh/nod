import Foundation

/// The pull half of the live pass — deliberately apart from the push loop in
/// `LiveMeetingAnalyst.swift`.
///
/// Everything in the main file is autonomous and budget-gated: `tick()` only
/// fires on its own schedule, throttled by `minNewLines`/`minInterval` because
/// nobody asked for it and the app is paying for it regardless. The two calls
/// here are the opposite shape — a user tap, spending once, on request — so
/// they skip every one of those gates on purpose rather than being a special
/// case bolted onto a loop that was never designed to run on demand.
///
/// Both still read `llm`/`store`/`findings` from the same instance: the
/// answer should agree with whatever the background pass already surfaced,
/// not re-derive it from a cold read.
extension LiveMeetingAnalyst {
    /// How much transcript "catch me up" reads — effectively the whole
    /// meeting, not a recent window. A tune-out can happen anywhere, and
    /// unlike the background pass this is a single on-demand call, not a
    /// per-minute one, so reading wide costs one call, not sixty.
    private static let catchUpMaxEntries = 500

    /// "What have I missed?" — a one-shot read of the whole transcript so far,
    /// grounded on the same standing findings the recap uses.
    func catchUp(language: AppLanguage) async throws -> String {
        let transcript = store.recentContext(maxEntries: Self.catchUpMaxEntries)
        let known = LiveFinding.notes(from: findings)
        let prompt = PromptLibrary.buildCatchUp(transcript: transcript, known: known, language: language)
        let result = try await llm.completeJSON(
            system: prompt.system,
            user: prompt.user,
            as: PromptLibrary.CatchUpResult.self,
            primaryModel: llm.chatModel
        )
        return result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "What should I ask next?" — reads the same size window the live pass
    /// itself reads (recent turns matter here, not the whole meeting), grounded
    /// the same way.
    func suggestFollowUps(language: AppLanguage) async throws -> [String] {
        let window = store.recentContext(maxEntries: Self.windowLines)
        let known = LiveFinding.notes(from: findings)
        let prompt = PromptLibrary.buildFollowUps(window: window, known: known, language: language)
        let result = try await llm.completeJSON(
            system: prompt.system,
            user: prompt.user,
            as: PromptLibrary.FollowUpsResult.self,
            primaryModel: llm.chatModel
        )
        return result.questions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A free-form question about the meeting so far, typed by the user rather
    /// than one of the two canned asks above. Same wide read as `catchUp` —
    /// the question could be about anything already said, not just the recent
    /// window.
    func ask(_ question: String, thread: AskThread = AskThread(), language: AppLanguage) async throws -> String {
        let transcript = store.recentContext(maxEntries: Self.catchUpMaxEntries)
        switch await answerFromTools(question, thread: thread) {
        case let .answered(text):
            return text
        // A tool ran and had nothing. The transcript gets the question only if
        // it has something to answer with; on an empty one the fallback is not
        // "the meeting's own words", it is a model with no context inventing a
        // reason, and the reason it invents is that it has no access.
        case let .checked(provider) where transcript.isEmpty:
            return LiveLookup.nothingFound(in: provider)
        case .checked, .notTried:
            break
        }
        let known = LiveFinding.notes(from: findings)
        let prompt = PromptLibrary.buildAsk(
            question: question,
            transcript: transcript,
            known: known,
            thread: thread,
            language: language
        )
        let result = try await llm.completeJSON(
            system: prompt.system,
            user: prompt.user,
            as: PromptLibrary.AskResult.self,
            primaryModel: llm.chatModel
        )
        return result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The typed question, tried against the connected tools before the
    /// transcript.
    ///
    /// The room is not consulted here. It is consulted inside `MeetingLookup`,
    /// per call, because the follow-up read is chosen after this function has
    /// stopped looking — a gate at this one call site is a gate the hop walks
    /// around.
    ///
    /// "Is that already tracked" is not a question about what this room said,
    /// and answering it from the transcript is how the box came to reply that
    /// it had no access to Linear on an account where Linear was connected.
    /// The spoken request has reached the tools since it existed; this one was
    /// pointed at the meeting's own words and nothing else.
    ///
    /// Nothing here writes — `MeetingLookup` never shows the model a mutating
    /// tool — so the answer needs no confirmation the box has no way to carry.
    ///
    /// `.notTried` hands the question back to the transcript unconditionally:
    /// no tool was chosen, so nothing was learned that the meeting's own words
    /// don't cover better. `.checked` is the caller's judgement call — see
    /// `ask`.
    private enum ToolAttempt {
        case answered(String)
        /// A tool was reached, and what came back did not answer the question.
        case checked(IntegrationProvider)
        /// No connected tool was chosen for this question at all.
        case notTried
    }

    private func answerFromTools(_ question: String, thread: AskThread) async -> ToolAttempt {
        guard let meetingLookup else { return .notTried }
        guard let routed = await meetingLookup.routing(for: question, thread: thread) else { return .notTried }

        Log.llm.info("live: ask routed to \(routed.tool.name)\(routed.tool.mutating ? " (needs approval)" : "")")
        switch await meetingLookup.answer(question, running: routed, thread: thread) {
        case let .refused(refusal):
            Log.llm.info("live: ask refused — \(refusal)")
            return .answered(refusal.label)
        // Not "found nothing". The product never answered, and the two are
        // opposite pieces of news to somebody deciding whether to go and look
        // themselves — so the reason is passed on rather than flattened.
        case let .failed(failure):
            Log.llm.error("live: ask failed — \(failure.label)")
            return .answered(failure.label)
        case .empty:
            Log.llm.info("live: ask \(routed.provider.rawValue) had nothing")
            return .checked(routed.provider)
        case let .answered(answer):
            // Provenance, in the one string this box can return: which product
            // said it and which record it was read from. An answer repeated
            // into a meeting by the person who read it is one the room will act
            // on, and one they cannot place is one nobody can check.
            let mark = [answer.provider?.displayName, answer.subject]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            guard !mark.isEmpty else { return .answered(answer.text) }
            return .answered("\(answer.text) · \(mark.joined(separator: " · "))")
        }
    }
}
