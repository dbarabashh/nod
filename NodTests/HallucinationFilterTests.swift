import XCTest
@testable import Nod

final class HallucinationFilterTests: XCTestCase {
    private func seg(
        _ text: String,
        noSpeech: Double? = nil,
        logprob: Double? = nil,
        compression: Double? = nil
    ) -> TranscriptionSegment {
        // Timings are irrelevant here — the filter reads only quality metrics.
        TranscriptionSegment(
            text: text,
            avgLogprob: logprob,
            noSpeechProb: noSpeech,
            compressionRatio: compression,
            start: nil,
            end: nil
        )
    }

    // Drops the canned junk we saw in the real transcript.

    func testDropsCannedBoilerplate() {
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Once again,"))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Thanks for watching"))
    }

    func testDropsForeignThanksAndSubtitleCredits() {
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Obrigado"))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Procorro"))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Thank you for watching"))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Продолжение следует..."))
    }

    func testDropsShortForeignScriptBlip() {
        // Korean blip from a noise clip in the real transcript.
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "더"))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "字幕"))
    }

    func testDropsMusicMarkers() {
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "♪♪♪"))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Музыка"))
    }

    // Keeps real speech — no false positives.

    func testKeepsBareFunctionWords() {
        // Real one-word turns: question turned back, a prompt to continue, a
        // trailed-off article. These must NOT be dropped.
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "You?"))
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "So?"))
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "The..."))
    }

    func testKeepsShortCyrillicBackchannels() {
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "так"))
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "да, да, да"))
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "ага"))
    }

    func testKeepsShortEnglishBackchannels() {
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "ok"))
        XCTAssertFalse(HallucinationFilter.isHallucination(text: "yeah"))
    }

    func testKeepsRealUkrainianSentence() {
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "А які хайлайти у тебе з подорожі?"
        ))
    }

    func testKeepsAccentedAndVietnameseLatin() {
        XCTAssertFalse(HallucinationFilter.isForeignScriptBlip("Lisboa é café"))
        XCTAssertFalse(HallucinationFilter.isForeignScriptBlip("Việt Nam xin chào"))
    }

    func testKeepsLongForeignLanguageSentence() {
        // A real, long sentence in a shipped non-Latin/Cyrillic output language
        // (Hindi) must survive — the script signal only fires on short blips.
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "मुझे लगता है कि हमें नई जगह की अवधारणा पर ध्यान देना चाहिए"
        ))
    }

    func testKeepsStrayGlyphInsideRealCyrillic() {
        // One stray foreign glyph in an otherwise-real Cyrillic line is a
        // minority, so the chunk is kept (only the glyph would ideally be lost).
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "ми відкриваємо нову локацію 字 наступного місяця"
        ))
    }

    // Metric signal (verbose_json) — gated on poor confidence.

    func testDropsHighNoSpeechLowConfidence() {
        XCTAssertTrue(HallucinationFilter.isHallucination(
            text: "thanks",
            segments: [seg("thanks", noSpeech: 0.92, logprob: -1.6)]
        ))
    }

    func testDropsDegenerateRepetitionWhenLowConfidence() {
        XCTAssertTrue(HallucinationFilter.isHallucination(
            text: "так так так так так так",
            segments: [seg("так так так так так так", logprob: -1.5, compression: 3.1)]
        ))
    }

    func testKeepsConfidentEmphaticRepetition() {
        // High compression but confident decode → real speech, not degenerate.
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "так так так",
            segments: [seg("так так так", noSpeech: 0.02, logprob: -0.2, compression: 2.6)]
        ))
    }

    func testKeepsConfidentSpeechDespiteSegments() {
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "ми відкриваємо нову локацію",
            segments: [seg("ми відкриваємо нову локацію", noSpeech: 0.02, logprob: -0.3, compression: 1.4)]
        ))
    }

    // Prompt-echo leakage — only on a low-confidence clip.

    func testDropsPromptEchoOnLowConfidenceClip() {
        let prompt = "ми обговорювали концепцію нового закладу і арт дірекшн"
        XCTAssertTrue(HallucinationFilter.isHallucination(
            text: "концепцію нового закладу і арт",
            segments: [seg("концепцію нового закладу і арт", noSpeech: 0.8, logprob: -1.3)],
            promptContext: prompt
        ))
    }

    func testKeepsConfidentRestatementMatchingPrompt() {
        // Same text as the prompt tail, but the clip is confident speech — a
        // genuine restatement, not a prompt-leak echo. Must be kept.
        let prompt = "ми обговорювали концепцію нового закладу і арт дірекшн"
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "концепцію нового закладу і арт",
            segments: [seg("концепцію нового закладу і арт", noSpeech: 0.03, logprob: -0.25)],
            promptContext: prompt
        ))
    }

    func testShortRepeatIsNotEcho() {
        // A short backchannel that happens to appear in the prompt tail is below
        // the echo length floor, so it survives regardless of confidence.
        XCTAssertFalse(HallucinationFilter.isHallucination(
            text: "так",
            promptContext: "добре так зробимо"
        ))
    }
}
