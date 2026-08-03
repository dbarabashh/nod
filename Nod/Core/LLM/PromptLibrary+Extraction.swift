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
        participants: [String]
    ) -> (system: String, user: String) {
        let system = """
        You extract the entities a recording is ABOUT, so the app can link sessions that share them. From the transcript and recap, return these lists:

        - "people": real personal names of participants or people discussed. NOT roles ("the recruiter"), NOT the literal routing tags [Me]/[Them]. Only names that appear literally.
        - "projects": named projects, products, tools, teams, companies, or initiatives that appear literally.
        - "topics": 2-4 word phrases naming what the session was actually about (e.g. "pricing strategy", "onboarding redesign"). Specific, not generic.

        [RULES]
        - Only include items grounded in the transcript/recap. Do NOT invent.
        - No duplicates. No generic filler ("meeting", "call", "discussion", "update").
        - Keep each list to at most 8 items, the most central first.
        - Empty arrays are fine — return them rather than padding.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"people": [], "projects": [], "topics": []}
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

    // MARK: - Speaker naming (step 3, before the recap)

    /// Puts a real person to each diarized cluster, from the transcript's own
    /// evidence and the conferencing app's roster.
    ///
    /// Its own call, and it runs BEFORE the recap on purpose: the recap used to
    /// be written against `Speaker N` and the names resolved after it, so the
    /// summary said "Speaker 2 (Nicola)" while the transcript chips underneath
    /// said "Nicola" — two views of one meeting disagreeing, permanently, in the
    /// artefact the user shares.
    ///
    /// Only worth calling on a transcript that actually carries `Speaker N`
    /// tags. Asked for on an unclustered one, the model has nothing to key a map
    /// by and invents one, and a fabricated name is worse than no name.
    static func buildSpeakerNaming(
        transcript: String,
        participants: [String]
    ) -> (system: String, user: String) {
        let system = """
        You identify which real person each diarized voice cluster belongs to. The transcript tags the other party's turns as `[Them · Speaker N]`, where N is one clustered voice. Return a map from that number to the person's name.

        [EVIDENCE] — a cluster may be named ONLY on direct evidence inside the transcript:
        - the speaker introduces themselves ("This is Eric", "Eric here"),
        - someone addresses them by name and that cluster answers next,
        - someone attributes a line to them by name ("as Eric said, ...") and that cluster said it.

        [NOT EVIDENCE] — none of these may name a cluster:
        - turn-taking, seniority, who talks most, or the order names appear,
        - a name merely being mentioned in the room, or one person talking ABOUT another,
        - a name on the roster below that no cluster is tied to.

        [RULES]
        - When a cluster is ambiguous, OMIT it. A cluster with no entry is reported without an author, which is honest; a wrong name is a lie the user has to catch in a summary they may already have shared.
        - Never name the `[Me]` side — that is the user, and it carries no cluster number.
        - Never map two clusters to the same person, and never map one cluster to two names.
        - Speech-to-text mangles names, especially non-English ones. When a garbled name in the transcript is clearly the same person as a roster entry, use the ROSTER spelling. When it matches no roster entry and the roster is present, that is a reason to omit, not to invent a spelling.
        - Return `{}` when nothing is unambiguous. That is the expected result for most meetings, and it is a correct answer, not a failure.

        [OUTPUT] Respond with ONLY this JSON object, no prose, no code fence:
        {"speakers": {}}

        Example of a well-formed answer: {"speakers": {"2": "Eric Johnson", "5": "Priya Raman"}}
        """
        let roster = participants.isEmpty
            ? "No participant list was available for this call — rely on the transcript alone, and omit more freely.\n\n"
            : "[ROSTER] The conferencing app listed these people on the call: \(participants.joined(separator: ", ")). Some of them may never have spoken. A name you return should normally come from this list — but only when the transcript itself ties it to that cluster.\n\n"
        let user = """
        \(roster)Transcript:

        \(transcript)

        Map the clusters now.
        """
        return (system, user)
    }
}

/// The speaker-naming response: diarized cluster number → the person speaking
/// it. Optional so a model that answers `{}` — the expected result for most
/// meetings — still decodes.
struct NamedSpeakers: Decodable {
    var speakers: [String: String]?
}

/// How to read and attribute the ambient screen capture, and how to cross it
/// with what was said in sessions. At file scope because it is a page of prose
