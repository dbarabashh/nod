import Foundation

/// What a session was ABOUT — people, projects, topics, and which diarized
/// cluster is which person. Feeds the "Related sessions" links and the speaker
/// names on the transcript, both durable and user-visible.
extension PromptLibrary {
    // MARK: - Entity extraction (step 4)

    /// Pulls the people / projects / topics a session is about so sessions
    /// that share them can be surfaced as "Related". Grounded strictly in the
    /// transcript + recap — these become durable, user-visible links, so a
    /// hallucinated name is worse than a missed one. Output is English-keyed
    /// JSON; names stay in whatever language they appear.
    static func buildEntityExtraction(
        transcript: String,
        summary: String,
        participants: [String],
        speakersLabelled: Bool
    ) -> (system: String, user: String) {
        let system = """
        You extract the entities a recording is ABOUT, so the app can link sessions that share them. From the transcript and recap, return these lists:

        - "people": real personal names of participants or people discussed. NOT roles ("the recruiter"), NOT the literal routing tags [Me]/[Them]. Only names that appear literally.
        - "projects": named projects, products, tools, teams, companies, or initiatives that appear literally.
        - "topics": 2-4 word phrases naming what the session was actually about (e.g. "pricing strategy", "onboarding redesign"). Specific, not generic.
        \(speakersLabelled ? speakerMappingRules : "")

        [RULES]
        - Only include items grounded in the transcript/recap. Do NOT invent.
        - No duplicates. No generic filler ("meeting", "call", "discussion", "update").
        - Keep each list to at most 8 items, the most central first.
        - Empty arrays are fine — return them rather than padding.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"people": [], "projects": [], "topics": []\(speakersLabelled ? ", \"speakers\": {}" : "")}
        """
        let candidates = participants.isEmpty
            ? ""
            : "The conferencing app listed these people on the call: \(participants.joined(separator: ", ")). A speaker name should normally come from this list — but only when the transcript itself ties the name to that cluster.\n\n"
        let user = """
        \(candidates)Recap:

        \(summary)

        Transcript:

        \(transcript)

        Extract the entities now.
        """
        return (system, user)
    }
}

/// Emitted only when the transcript actually carries `Speaker N` tags. Asked
/// for on an unclustered transcript, the model has nothing to key a map by
/// and invents one — and a fabricated name is worse than no name, because
/// the late relabel pass then attaches it to a real cluster.
private let speakerMappingRules = """
- "speakers": which real person each diarized cluster is, keyed by the number in the transcript's `[Them · Speaker N]` tags — {"2": "Eric Johnson"}.

[SPEAKERS] — the strict part
- Map a cluster ONLY on direct evidence inside the transcript: the speaker introduces themselves ("This is Eric Johnson"), someone addresses them and they answer, or someone attributes a line to them by name.
- Turn-taking, seniority, who talks most, and the order names appear are NOT evidence. Neither is a name merely being mentioned in the room.
- When a cluster is ambiguous, OMIT it. A missing entry renders as "Speaker 2", which is correct; a wrong name is a lie the user has to catch.
- Never map the `[Me]` side — that is the user, and it carries no cluster number.
- Return `{}` when nothing is unambiguous. That is the expected result for most meetings.
"""

/// How to read and attribute the ambient screen capture, and how to cross it
/// with what was said in sessions. At file scope because it is a page of prose
