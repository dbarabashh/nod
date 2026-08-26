import Foundation

/// The two things worth asking Nod for mid-meeting, on demand.
///
/// Both read the live pass's own memory (`LiveMeetingAnalyst.findings`, the
/// same notes the end-of-meeting recap is grounded on) so the answer agrees
/// with whatever the live pass already surfaced instead of re-deriving it from
/// a cold read of the transcript.
extension PromptLibrary {
    /// "What have I missed?" — one short paragraph, not a bullet dump. The
    /// reader tuned out or was multitasking on the same call; they need to be
    /// back up to speed in the time it takes to read one paragraph, not asked
    /// to reconstruct a meeting from a list of fragments.
    static func buildCatchUp(
        transcript: String,
        known: [String],
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You are catching the user up on a meeting they are still in, after they tuned out or were multitasking for a stretch.

        Write 3-5 short sentences, in plain prose, present or recent-past tense: what has been discussed, what (if anything) has been decided, and what the conversation is on right now. Read like something a colleague would lean over and tell you, not a report.

        \(humanProseStyle)

        - Ground every sentence in the transcript or in [ALREADY KNOWN]. Never invent a decision, a name, or a number that isn't there.
        - Skip small talk and scene-setting. Lead with what changed or what matters, not "the meeting started with introductions."
        - If nothing substantial has happened yet, say so plainly in one sentence — don't pad it out.
        - LANGUAGE: write in \(lang) unless the transcript is clearly in another language, in which case match the transcript.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"summary": ""}
        """

        let memory = numberedMemoryBlock(header: "[ALREADY KNOWN]", empty: "Nothing flagged yet.", known: known)

        let user = """
        \(memory)[TRANSCRIPT SO FAR]

        \(transcript)

        Catch the user up.
        """
        return (system, user)
    }

    struct CatchUpResult: Decodable {
        let summary: String
    }

    /// "What should I ask next?" — read the recent turns and suggest 2-4
    /// concrete questions the user could put to the other side. Distinct from
    /// what the live pass extracts: that reports what the room already said;
    /// this proposes what the user hasn't asked yet.
    static func buildFollowUps(
        window: String,
        known: [String],
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You are helping the user, mid-conversation, think of good questions to ask the other side next.

        Read the recent turns and suggest 2 to 4 short, specific questions the user could ask right now to move the conversation forward: probe an unstated assumption, ask for a number that was implied but not given, or follow a thread that was raised and dropped.

        \(humanProseStyle)

        - Every question has to follow from something actually said in the window — not a generic question that would fit any conversation.
        - Do NOT suggest a question that [ALREADY KNOWN] shows was already answered or decided.
        - Each question is one sentence, phrased as the user would say it out loud (second person, direct).
        - If the window has nothing worth following up on (pure small talk, nothing concrete raised), return an empty list — that is the correct answer, not a reason to invent a generic one.
        - LANGUAGE: write in \(lang) unless the transcript is clearly in another language, in which case match the transcript.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"questions": []}
        """

        let memory = numberedMemoryBlock(header: "[ALREADY KNOWN]", empty: "Nothing flagged yet.", known: known)

        let user = """
        \(memory)[WINDOW — the last few minutes]

        \(window)

        Suggest what to ask next. An empty list is a correct answer.
        """
        return (system, user)
    }

    struct FollowUpsResult: Decodable {
        let questions: [String]
    }

    /// The live "Ask" box — a free-form question the user typed mid-recording,
    /// for whatever the fixed catch-up/follow-ups cards don't cover. A one-off,
    /// ephemeral Q&A grounded in the transcript so far; it does not persist and
    /// never feeds the recap.
    static func buildAsk(
        question: String,
        transcript: String,
        known: [String],
        thread: AskThread = AskThread(),
        now: Date = Date(),
        language: AppLanguage = .english
    ) -> (system: String, user: String) {
        let lang = language.promptName
        let system = """
        You are answering a question the user typed while still in a meeting, about that meeting so far.

        \(nowBlock(now))

        Answer in 1-3 short sentences, plain prose. Get to the answer first; skip any preamble like "Based on the transcript".

        \(humanProseStyle)

        - Ground the answer only in the transcript or [ALREADY KNOWN]. Never invent a name, number, or decision that isn't there.
        - If the transcript doesn't say, say so plainly in one sentence rather than guessing.
        - [EARLIER IN THIS ASK BOX] is your own conversation with this user, in order. Read the question as the next turn in it.
        - A follow-up like "and the previous one?" refers to what you were just asked and just answered, not to the meeting.
        - Never say what you can or cannot reach: you are given this meeting's words, not the list of tools the user connected.
        - "I don't have access to Slack" is therefore a claim you cannot check, and it has been wrong. Say what the transcript says, or that it doesn't cover this.
        - LANGUAGE: write in \(lang) unless the transcript is clearly in another language, in which case match the transcript.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"answer": ""}
        """

        let memory = numberedMemoryBlock(header: "[ALREADY KNOWN]", empty: "Nothing flagged yet.", known: known)

        let user = """
        \(thread.block)\(memory)[TRANSCRIPT SO FAR]

        \(transcript)

        [QUESTION]
        \(question)
        """
        return (system, user)
    }

    struct AskResult: Decodable {
        let answer: String
    }
}
