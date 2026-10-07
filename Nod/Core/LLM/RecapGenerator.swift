import Foundation

/// Turns a built recap prompt into a finished `MeetingRecap` plus its
/// event-style title. Shared by the end-of-meeting finalize and the manual
/// regeneration in the detail view, so a recap produced after the fact goes
/// through the same streaming, retry and sanitising rules as the original.
@MainActor
struct RecapGenerator {
    let llm: LLMProxyClient

    /// Streams the recap, handing partial markdown to `onPartial`
    /// section-by-section so a view can fill it in live instead of popping the
    /// whole recap in at the end. On a clean finish it parses the full JSON and
    /// runs the same bounded retry as the one-shot path. Any stream failure —
    /// or unparseable JSON — falls back to the buffered `recap`, which yields a
    /// guaranteed-complete recap (a half-streamed recap must never be persisted
    /// as final).
    func streamedRecap(
        system: String,
        user: String,
        transcript: String,
        language: AppLanguage,
        meetingID: UUID? = nil,
        onPartial: @MainActor @escaping (String) -> Void
    ) async throws -> MeetingRecap {
        var accumulated = ""
        var lastPublish = Date.distantPast
        do {
            for try await delta in llm.streamComplete(
                system: system,
                user: user,
                jsonMode: true,
                longRunning: true,
                reasoningEffort: Self.reasoningEffort,
                context: GenerationContext(purpose: .recap, meetingID: meetingID)
            ) {
                accumulated += delta
                // Re-parse + publish at ~6 fps. Each pass renders whatever
                // sections have fully closed so far; the trailing, still-
                // streaming section is ignored until it closes.
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= 0.15 {
                    let sections = MeetingRecap.partialSections(fromStreamingJSON: accumulated)
                    if !sections.isEmpty {
                        onPartial(MeetingRecap.markdown(for: sections))
                    }
                    lastPublish = now
                }
            }
        } catch {
            try Task.checkCancellation()
            // An entitlement 403 already opened the paywall and can't recover by
            // retrying the one-shot path — that re-hits the same gate and posts
            // the paywall notification a second time. Propagate it instead.
            if case LLMProxyClient.ClientError.entitlementRequired = error { throw error }
            Log.llm.error("recap stream failed after \(accumulated.count) chars — falling back to one-shot: \(error.localizedDescription)")
            return try await recap(system: system, user: user, transcript: transcript, language: language, meetingID: meetingID)
        }

        let cleaned = LLMProxyClient.extractJSON(accumulated)
        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(MeetingRecap.self, from: data)
        else {
            Log.llm.error("recap stream produced unparseable JSON — falling back to one-shot")
            return try await recap(system: system, user: user, transcript: transcript, language: language, meetingID: meetingID)
        }
        Log.llm.info("recap stream done — \(parsed.sections.count) sections")
        // Settle the live view on the finished recap before any retry runs.
        onPartial(parsed.toMarkdown())
        return try await refined(parsed, system: system, user: user, transcript: transcript, language: language, meetingID: meetingID)
    }

    /// Buffered one-shot recap — used for the rare mid-call `.summary` path and
    /// as `streamedRecap`'s fallback. Shares the bounded retry below.
    func recap(system: String, user: String, transcript: String, language: AppLanguage, meetingID: UUID? = nil) async throws -> MeetingRecap {
        let recap = try await llm.completeJSON(
            system: system,
            user: user,
            as: MeetingRecap.self,
            longRunning: true,
            reasoningEffort: Self.reasoningEffort,
            context: GenerationContext(purpose: .recap, meetingID: meetingID)
        )
        return try await refined(recap, system: system, user: user, transcript: transcript, language: language, meetingID: meetingID)
    }

    static var reasoningEffort: String? {
        UserDefaults.standard.string(forKey: "openrouter.recap.reasoningEffort")
    }

    /// Best-effort LLM call to produce a short event-style title. Returns
    /// nil on failure (Meeting.displayTitle falls back to a date label).
    func title(from summary: String, language: AppLanguage) async -> String? {
        let (system, user) = PromptLibrary.buildTitle(summary: summary, language: language)
        do {
            let raw = try await llm.complete(system: system, user: user, primaryModel: llm.titleModel)
            return Self.sanitizedTitle(raw)
        } catch {
            Log.llm.error("title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// One bounded retry that addresses whatever the first pass got wrong, shared
    /// by the streamed and one-shot recap paths. Two deterministic failure modes
    /// trigger it: (1) the model returned the "too short / unclear" fallback — or
    /// nothing grounded at all — on a substantive transcript; (2) the model
    /// ignored the language directive and wrote the recap in the wrong language
    /// (Gemini in JSON mode has been seen emitting Chinese for a Russian-selected,
    /// Russian-spoken meeting). Both are checked against the output, not trusted
    /// to the prompt. Returns the original recap when nothing needs fixing.
    private func refined(
        _ recap: MeetingRecap,
        system: String,
        user: String,
        transcript: String,
        language: AppLanguage,
        meetingID: UUID?
    ) async throws -> MeetingRecap {
        var overrides: [String] = []

        if recap.isPlaceholderFallback || recap.isEmpty, Self.hasSubstance(transcript) {
            Log.llm.info("summary empty/placeholder on substantive transcript — will retry")
            overrides.append("""
            RETRY OVERRIDE — EMPTY/FALLBACK:
            Your previous response \(
                recap.isEmpty ? "contained no grounded content" : "used the \"Transcript too short or unclear\" fallback"
            ), but this transcript has enough intelligible content to recap.
            Do NOT return an empty or fallback recap. Produce at least one section with 2-4 grounded bullets, translating non-English content into the requested output language.
            """)
        }

        if let got = Self.languageMismatch(recap, expected: language) {
            Log.llm.info("recap language mismatch got=\(got) expected=\(language.rawValue) — will retry")
            overrides.append("""
            RETRY OVERRIDE — LANGUAGE:
            Your previous response was written in the WRONG language (it came out in \(got)). Write EVERY string value — section titles and bullet text — in \(
                language.promptName
            ), and nothing else. Leave verbatim `quote` values exactly as spoken; JSON keys stay in English.
            """)
        }

        guard !overrides.isEmpty else { return recap }
        let retrySystem = system + "\n\n" + overrides.joined(separator: "\n\n")
        return try await llm.completeJSON(
            system: retrySystem,
            user: user,
            as: MeetingRecap.self,
            longRunning: true,
            reasoningEffort: Self.reasoningEffort,
            context: GenerationContext(purpose: .recap, meetingID: meetingID)
        )
    }

    /// Detects whether the recap's PROSE (section titles + bullet text, NOT the
    /// verbatim `quote` values, which stay in the spoken language) was written in
    /// a language other than the one the user selected. Returns the offending
    /// language code, or nil when it matches / is too short to call confidently.
    private static func languageMismatch(_ recap: MeetingRecap, expected: AppLanguage) -> String? {
        let prose = recap.sections.flatMap { section in
            [section.title] + section.bullets.map(\.text)
        }
        let joined = prose.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count >= 12, let detected = AppLanguage.detect(from: joined) else { return nil }
        if detected == expected { return nil }
        // NLLanguageRecognizer routinely confuses Ukrainian and Russian (both
        // Cyrillic, closely related) — the founder's home-market pair. A uk↔ru
        // "mismatch" is almost always a misdetection of a correct recap, so
        // don't burn a full re-generation on it (and re-prompting wouldn't
        // reliably flip uk↔ru anyway). Real wrong-language cases here are
        // cross-script (e.g. Chinese), which this still catches.
        let cyrillicPair: Set<AppLanguage> = [.russian, .ukrainian]
        if cyrillicPair.contains(expected), cyrillicPair.contains(detected) { return nil }
        return detected.rawValue
    }

    private static func hasSubstance(_ transcript: String) -> Bool {
        let words = transcript
            .split { $0.isWhitespace || $0.isNewline }
            .filter { $0.contains { $0.isLetter } }
        return words.count >= 40
    }

    /// Models occasionally wrap titles in **bold**, prefix them with
    /// "Title: ", or echo quotes around them despite the prompt's
    /// instructions. Strip the common artefacts before storing.
    static func sanitizedTitle(_ raw: String) -> String? {
        // 1. Whitespace + first-line only — models sometimes follow with a
        //    blank line + explanation.
        var line = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        // 2. Surrounding quotes / backticks.
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        // 3. Surrounding `**bold**` markers — the LLM sometimes emits the
        //    title in bold despite the no-markdown rule.
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            line.removeFirst(2)
            line.removeLast(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 4. Leading "Title:" / "Заголовок:" / "Тема:" / "Назва:" prefixes
        //    (case-insensitive).
        for prefix in ["title:", "заголовок:", "тема:", "назва:"] {
            if line.lowercased().hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 5. Trailing punctuation that doesn't belong in a title.
        while let last = line.last, ".!?;,".contains(last) {
            line.removeLast()
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap at 120 chars — enough headroom for Ukrainian/Russian/Polish
        // 7-word titles whose roots are longer than English equivalents.
        guard !line.isEmpty, line.count <= 120 else {
            Log.ui.info("title rejected (empty or too long): len=\(line.count)")
            Log.ui.sensitive("title rejected: '\(line.prefix(40))…'")
            return nil
        }
        return line
    }
}
