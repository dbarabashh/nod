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
    func ask(_ question: String, language: AppLanguage) async throws -> String {
        let transcript = store.recentContext(maxEntries: Self.catchUpMaxEntries)
        let known = LiveFinding.notes(from: findings)
        let prompt = PromptLibrary.buildAsk(question: question, transcript: transcript, known: known, language: language)
        let result = try await llm.completeJSON(
            system: prompt.system,
            user: prompt.user,
            as: PromptLibrary.AskResult.self,
            primaryModel: llm.chatModel
        )
        return result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
