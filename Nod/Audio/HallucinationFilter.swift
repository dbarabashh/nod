import Foundation

/// Decides whether a Whisper transcription chunk is a hallucination rather than
/// real speech, so the transcriber can drop it before it reaches the live
/// transcript, the recap, the entity extractor, and the search index.
///
/// Whisper invents text when fed silence, breath, music, or a sub-second noise
/// blip — classic symptoms are canned phrases ("Thank you for watching",
/// "Obrigado"), subtitle credits, music marks, and short stray foreign-script
/// blips ("더"). Per-chunk isolation (each utterance is its own REST call) makes
/// this worse, and the cloud route can't set Whisper's own `no_speech`/`logprob`
/// thresholds, so we filter on the client.
///
/// Bias is toward KEEPING speech: every drop rule is either an unmistakable
/// canned phrase or is gated so it can't erase confident, real, long-form
/// speech. In particular a real non-Latin/Cyrillic language (the app ships
/// Mandarin, Hindi, Arabic, Bengali, Urdu as output languages and transcription
/// is multilingual), emphatic repetition, and genuine restatements all survive.
enum HallucinationFilter {
    static func isHallucination(
        text: String,
        segments: [TranscriptionSegment] = [],
        promptContext: String? = nil
    ) -> Bool {
        let norm = normalize(text)
        if norm.isEmpty { return true }

        // Unmistakable canned hallucinations: subtitle credits, "thank you",
        // foreign "thanks". Exact normalized match only — never bare function
        // words like "you"/"so"/"the", which are real one-word turns.
        if blocklist.contains(norm) { return true }

        // Music / non-speech markers.
        if text.contains("♪") || text.contains("♫") { return true }
        if norm == "music" || norm == "музыка" || norm == "музика" { return true }

        // Short stray foreign-script blip: a noise clip decoded into a script the
        // speaker isn't using ("더"). Gated on short + majority-foreign so a real
        // long sentence in a non-Latin/Cyrillic language, or a real Cyrillic/Latin
        // line with one stray glyph, is NOT dropped.
        if isForeignScriptBlip(text) { return true }

        let confidence = segmentConfidence(segments)

        // Prompt-echo leak: Whisper echoes its conditioning prompt verbatim on a
        // quiet clip. Only treat a prompt substring as an echo when the segment
        // metrics confirm the clip was low-confidence/near-silent — otherwise a
        // genuine confident restatement (people repeat names/numbers/decisions)
        // would be dropped.
        if confidence == .low,
           let context = promptContext,
           isPromptEcho(norm, promptNormalized: normalize(context)) {
            return true
        }

        if metricsIndicateNonSpeech(segments) { return true }

        return false
    }

    /// Lowercased, punctuation/whitespace-stripped form for exact-match + echo
    /// comparison. Keeps letters and digits across every script.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// True only for a SHORT chunk whose letters are mostly outside Latin +
    /// Cyrillic — the signature of a foreign-script noise blip ("더", "字幕"). A
    /// long utterance (real speech in any language, including Mandarin/Hindi/
    /// Arabic/Bengali/Urdu) is never flagged here, and a single stray foreign
    /// glyph inside a real Latin/Cyrillic line is a minority, so it's kept.
    static func isForeignScriptBlip(_ text: String) -> Bool {
        var foreign = 0
        var total = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            total += 1
            if !isLatin(scalar), !isCyrillic(scalar) { foreign += 1 }
        }
        guard total > 0 else { return false }
        return total <= maxBlipLetters && foreign * 2 > total
    }

    /// A real foreign-script utterance is longer than a hallucinated blip; at or
    /// below this many letters we may drop on script, above it never.
    private static let maxBlipLetters = 8

    private static func isLatin(_ s: Unicode.Scalar) -> Bool {
        // Basic Latin, Latin-1 Supplement, Latin Extended-A/B, and Latin Extended
        // Additional (Vietnamese, fully-accented forms) — covers Latin-script
        // languages without admitting other scripts.
        (0x0041 ... 0x005A).contains(s.value) || (0x0061 ... 0x007A).contains(s.value) ||
            (0x00C0 ... 0x024F).contains(s.value) || (0x1E00 ... 0x1EFF).contains(s.value)
    }

    private static func isCyrillic(_ s: Unicode.Scalar) -> Bool {
        (0x0400 ... 0x04FF).contains(s.value) || (0x0500 ... 0x052F).contains(s.value)
    }

    private static func isPromptEcho(_ normalized: String, promptNormalized: String) -> Bool {
        guard normalized.count >= 12, !promptNormalized.isEmpty else { return false }
        return promptNormalized.contains(normalized)
    }

    private enum Confidence { case unknown, ok, low }

    /// Classify a clip from its `verbose_json` metrics. `.unknown` when the
    /// provider returned no segments (we can't tell, so callers don't gate on it).
    private static func segmentConfidence(_ segments: [TranscriptionSegment]) -> Confidence {
        guard !segments.isEmpty else { return .unknown }
        let maxNoSpeech = segments.compactMap(\.noSpeechProb).max() ?? 0
        let logprobs = segments.compactMap(\.avgLogprob)
        let meanLogprob = logprobs.isEmpty ? 0 : logprobs.reduce(0, +) / Double(logprobs.count)
        return (maxNoSpeech > 0.6 || meanLogprob < -1.0) ? .low : .ok
    }

    /// `verbose_json` metrics that mark a clip as non-speech. Empty segments →
    /// not dropped (the text signals already ran). Both the silence and the
    /// repetition rule require poor decode confidence too, so confident real
    /// speech — including emphatic repetition ("так так так") — is never dropped
    /// here. Thresholds mirror Whisper's defaults (no_speech 0.6, logprob -1.0,
    /// compression 2.4).
    private static func metricsIndicateNonSpeech(_ segments: [TranscriptionSegment]) -> Bool {
        guard !segments.isEmpty else { return false }

        let logprobs = segments.compactMap(\.avgLogprob)
        let meanLogprob = logprobs.isEmpty ? 0 : logprobs.reduce(0, +) / Double(logprobs.count)

        // Degenerate repetition: low-entropy text AND low decode confidence.
        // Confident emphatic repetition (high logprob) is real speech, not this.
        if segments.contains(where: { ($0.compressionRatio ?? 0) > 2.4 }), meanLogprob < -0.5 {
            return true
        }

        // Whole clip reads as silence: every segment flagged no-speech AND the
        // mean confidence is poor.
        let allNoSpeech = segments.allSatisfy { ($0.noSpeechProb ?? 0) > 0.6 }
        return allNoSpeech && meanLogprob < -1.0
    }

    /// Normalized canned hallucinations. Every entry is multi-word boilerplate or
    /// foreign "thanks" that no one says as a standalone real utterance in a
    /// uk/ru/en meeting turn — NOT bare function words ("you"/"so"/"the"), which
    /// are real one-word turns and must survive.
    private static let blocklist: Set<String> = [
        "yeah yeah yeah yeah",
        // English subtitle boilerplate.
        "thank you", "thank you very much", "thanks for watching",
        "thank you for watching", "please subscribe", "once again",
        // Foreign "thanks" that surface as hallucinations on uk/ru/en audio.
        "obrigado", "obrigada", "procorro", "gracias", "dziekuje", "merci", "grazie",
        // Subtitle-community credits (multilingual classics).
        "amara org", "subtitles by the amara org community",
        "продолжение следует", "субтитры сделал dimatorzok",
        "редактор субтитров а семкин корректор а егорова"
    ]
}
