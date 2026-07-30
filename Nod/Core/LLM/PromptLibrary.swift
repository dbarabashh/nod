import Foundation

enum PromptKind {
    case hero // "Catch me up"
    case smartReply // "Key points"
    case followUp // "Suggest follow-up questions"
    case summary // "Recap so far" / "Meeting Summary"
    case suggestReply // "Suggest reply" — real-time response suggestion
    case ask // live "Ask" box — free-form question / context during recording

    /// How many recent transcript entries this prompt actually needs. `nil`
    /// means "everything" — only `.summary` (end-of-meeting recap) and the
    /// kinds whose prompts explicitly anchor on the entire history qualify.
    /// Mid-call cards bounded to a recent window cut input tokens on long
    /// meetings without degrading the answer (the prompt itself constrains
    /// what's relevant — see each `case` for the justification).
    var contextWindow: Int? {
        switch self {
        // Both prompts say "current topic" / "current meeting" — anything
        // older than the recent window is by design out of scope for them.
        // ~80 entries ≈ 5-10 min of dialogue at typical 5s Whisper chunks.
        case .hero, .followUp:
            80
        // "Pull out 3-5 most important points discussed SO FAR" — needs
        // more history than hero. End-of-meeting summary still uses full.
        case .smartReply:
            200
        // suggestReply's prompt explicitly requires the ENTIRE transcript
        // ("Previous [Me] answers are LOAD-BEARING") — truncating breaks
        // the persona/consistency property the suggestion depends on.
        case .suggestReply:
            nil
        // A live question can reach back anywhere in the call ("what did we
        // decide at the start?"), so give it the full transcript like the recap.
        case .ask:
            nil
        // End-of-meeting recap must surface decisions and actions that
        // happened anywhere in the call.
        case .summary:
            nil
        }
    }
}

enum PromptLibrary {
    /// Shared [STYLE] rule keeping chat replies within what the inline-only
    /// `renderRecapMarkdown` can render — block syntax leaks through as raw
    /// characters otherwise.
    static let inlineMarkdownStyle = "Formatting: use **bold** for any section label and \"- \" for bullet items. Do NOT use \"#\"/\"##\" headings, numbered lists, tables, or code fences — the app renders only inline Markdown, so those show up as raw characters."

    static func build(
        kind: PromptKind,
        transcript: String,
        language: AppLanguage = .english,
        personalContext: String = "",
        sessionKind: SessionKind = .meeting,
        replyContext: ReplyContext = .auto,
        summaryTemplate: SummaryTemplate = .auto,
        modeFocus: String = "",
        meetingDate: String = "",
        userQuestion: String = "",
        participants: [String] = []
    ) -> (system: String, user: String) {
        let context = transcript.isEmpty
            ? "(No transcript captured yet.)"
            : transcript
        let base = system(
            for: kind,
            language: language,
            sessionKind: sessionKind,
            replyContext: replyContext,
            summaryTemplate: summaryTemplate
        )
        // Layer the user-level context blocks ahead of the task prompt: who the
        // user is, when the session happened (the relative-date anchor), then
        // what they're focused on in this meeting mode.
        let system = [
            personalContext,
            dateBlock(meetingDate),
            focusBlock(modeFocus),
            participantsBlock(participants),
            base
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        return (system, userMessage(for: kind, context: context, question: userQuestion))
    }

    /// Absolute, unambiguous date string for a session, used as the
    /// relative-time anchor in the prompts. POSIX locale keeps it stable
    /// regardless of device settings; the recap language is handled separately.
    /// Who the conferencing app said was on the call. A hint for resolving
    /// `Speaker N`, never an assertion that these people spoke — someone can sit
    /// on a call in silence, and the prompt is told to leave a speaker unnamed
    /// rather than guess.
    private static func participantsBlock(_ participants: [String]) -> String {
        guard !participants.isEmpty else { return "" }
        return """
        [CALL PARTICIPANTS]
        The conferencing app listed these people on the call: \(participants.joined(separator: ", ")).
        Some of them may not have spoken. Use this only to put a name to a voice when the transcript makes it unambiguous.
        """
    }

    static func sessionDateString(_ date: Date) -> String {
        sessionDateFormatter.string(from: date)
    }

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter
    }()

    /// Wall-clock time with the zone spelled out. A date alone leaves "20
    /// minutes ago" and "this morning" unanchored, and every timestamp we hand
    /// the model — screen captures, session labels — is already local, so the
    /// zone has to be stated or it can convert times that need no converting.
    static func localTimeString(_ date: Date) -> String {
        localTimeFormatter.string(from: date)
    }

    /// Timestamp on a screen-context block. Device locale on purpose — unlike
    /// the session/`localTimeString` stamps it labels something the user saw
    /// minutes ago, and it reads back to them in the answer.
    static let observationStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm zzz (ZZZZZ)"
        return formatter
    }()

    /// The `[SESSION DATE]` anchor block. Gives the model an absolute date so it
    /// can resolve relative references ("next week", "in two months") instead of
    /// guessing — the source of the June/August-style date errors. Empty when no
    /// date is supplied, so callers that don't pass one are unaffected.
    static func dateBlock(_ date: String) -> String {
        let trimmed = date.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        [SESSION DATE]
        This session was recorded on \(trimmed). Treat it as the anchor for every relative time reference in the transcript ("today", "yesterday", "next week", "in two months"). Resolve relatives against it; never invent a date that was not stated.
        """
    }

    /// The `[MEETING FOCUS]` block — the active mode's free-text focus. Only the
    /// meeting generations pass a non-empty value (it's gated to meeting kind at
    /// the call site), so a voice note or media recap never carries it.
    private static func focusBlock(_ focus: String) -> String {
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        [MEETING FOCUS — what the user is paying attention to in this conversation]
        \(trimmed)
        Use this to prioritize what to surface and how to frame the answer, but never invent facts to satisfy it — stay grounded in the transcript.
        """
    }

    /// The `[SITUATION]` block for the suggest-reply prompt. `[Me]` is always
    /// `[Me]` is the user being coached; `[Them]` is the counterpart.
    ///
    /// The one-line directive that opens `[SITUATION]`: it only *selects* which
    /// playbook applies. The playbooks themselves live once in
    /// `situationPlaybooks` (always in the prompt body), so `.auto` — which
    /// classifies then applies — is as strong as an explicit pin instead of a
    /// thinner fallback, and the explicit cases can't drift apart.
    static func kindFraming(_ sessionKind: SessionKind) -> String {
        switch sessionKind {
        case .meeting:
            "You are a meeting copilot producing the recap of a meeting that just ended. The user was on the call and may have forgotten details — give them a clear, useful read-out so nothing important slips through."
        case .voiceNote:
            """
            You are producing the recap of a SOLO VOICE NOTE — the user thinking out loud, with no second party. The transcript is almost entirely [Me]; there is no [Them] to attribute to.
            - `topics` = the distinct ideas / threads the user worked through.
            - `decisions` = conclusions the user reached for themselves ("I'll go with X").
            - `actions` = things the user told themselves to do — owner is always the user (use their name from [ABOUT THE USER] if present, otherwise "You").
            - `open_questions` = things they were still unsure about or left to figure out later.
            Do not invent a second speaker. Do not expect dialogue.
            """
        case .media:
            """
            You are producing the recap of MEDIA the user listened to — a video, podcast, talk, or recording. [Them] is the content being played; [Me] is the user's own occasional remark and is usually sparse or absent.
            - `topics` = what the media actually covered, with its conclusions.
            - `open_questions` = questions the content raised or left unresolved.
            - `decisions` and `actions` will usually be EMPTY — this is listening, not a meeting. Leave them empty unless the user explicitly stated a personal takeaway action out loud ([Me]); never invent owners or commitments for the speakers in the media.
            """
        }
    }

    /// "Catch me up" framing per session kind. The JSON contract
    /// (`current_topic` / `positions` / `status`) is fixed — only the framing
    /// and what each slot means shift, since a solo note has no "positions in
    /// play" and media has no [Me] side. `CatchUp.toMarkdown` joins the three
    /// slots into one paragraph, so the relabelling is invisible downstream.

    private static func userMessage(for kind: PromptKind, context: String, question: String = "") -> String {
        switch kind {
        case .ask:
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            Transcript so far:

            \(context)

            The user just sent you this message:

            \(trimmed.isEmpty ? "(empty)" : trimmed)

            Respond now.
            """
        default:
            return "Transcript so far:\n\n\(context)\n\nRespond now."
        }
    }
}
