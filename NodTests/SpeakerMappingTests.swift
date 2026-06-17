import XCTest
@testable import Nod

final class SpeakerMappingTests: XCTestCase {
    private func range(_ start: Float, _ end: Float, _ speaker: Int) -> DiarizedRange {
        DiarizedRange(start: start, end: end, speaker: speaker)
    }

    func testAssignsByOverlapAndRenumbersByFirstAppearance() {
        // Two 1 s utterances back to back; diarizer used arbitrary ids 5 and 9.
        let segs = [SegmentRange(start: 0, count: 16_000), SegmentRange(start: 16_000, count: 16_000)]
        let diar = [range(0, 1, 5), range(1, 2, 9)]
        XCTAssertEqual(SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000), [0, 1])
    }

    func testFirstSpeakerHeardIsLabelZero() {
        let segs = [SegmentRange(start: 0, count: 16_000), SegmentRange(start: 16_000, count: 16_000)]
        let diar = [range(0, 1, 9), range(1, 2, 5)] // 9 heard first → 0
        XCTAssertEqual(SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000), [0, 1])
    }

    func testPicksMajorityOverlapSpeaker() {
        let segs = [SegmentRange(start: 0, count: 16_000), SegmentRange(start: 16_000, count: 16_000)]
        // seg0 mostly speaker 8; seg1 mostly speaker 7.
        let diar = [range(0, 0.4, 7), range(0.4, 1.4, 8), range(1.4, 2.0, 7)]
        XCTAssertEqual(SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000), [0, 1])
    }

    func testUncoveredSegmentInheritsPreviousSpeaker() {
        let segs = [
            SegmentRange(start: 0, count: 16_000),
            SegmentRange(start: 16_000, count: 16_000), // no diar overlap
            SegmentRange(start: 32_000, count: 16_000)
        ]
        let diar = [range(0, 1, 3), range(2, 3, 3)]
        XCTAssertEqual(SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000), [0, 0, 0])
    }

    // assign() must pass the diarizer's speaker count through unchanged — given a
    // clean 4-speaker diarization spanning 10 minutes, it renumbers to exactly 4
    // labels and never invents extra speakers. (The "13 speakers for 4 people" bug
    // lived in the now-removed windowing path that fed assign(); assign() itself
    // was always pure mapping. This pins that contract so the mapping layer can't
    // regress into inflation.)
    func testLongMeetingPreservesDiarizedSpeakerCount() {
        let speakerIds = [12, 7, 3, 20] // 4 distinct people; arbitrary diarizer ids
        var segs: [SegmentRange] = []
        var diar: [DiarizedRange] = []
        let total = 600 // 600 one-second utterances → 10 minutes
        for i in 0 ..< total {
            segs.append(SegmentRange(start: i * 16_000, count: 16_000))
            diar.append(range(Float(i), Float(i) + 1, speakerIds[i % speakerIds.count]))
        }

        let labels = SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000)

        XCTAssertEqual(labels.count, total)
        XCTAssertEqual(Set(labels).count, 4, "4 diarized speakers must not inflate")
        XCTAssertEqual(Set(labels), [0, 1, 2, 3], "renumbered 0..<4 by first appearance")
        XCTAssertEqual(Array(labels.prefix(4)), [0, 1, 2, 3], "first appearances in order heard")
    }

    // A single-speaker them-stream (solo dictation, 1-on-1 where only the remote
    // talks) must stay one speaker — never split into "Them 1 / Them 2".
    func testSingleSpeakerThroughoutStaysOneSpeaker() {
        let segs = [
            SegmentRange(start: 0, count: 16_000),
            SegmentRange(start: 16_000, count: 16_000),
            SegmentRange(start: 32_000, count: 16_000)
        ]
        let diar = [range(0, 3, 5)] // one speaker spans all three utterances

        let labels = SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000)

        XCTAssertEqual(labels, [0, 0, 0])
        XCTAssertEqual(Set(labels).count, 1)
    }

    // On an exact overlap tie, the earlier diarized range wins (assign uses a
    // strict `>` so the first match isn't displaced). Pinning this keeps the
    // tiebreak stable across refactors: seg0 ties 7 vs 9 and must resolve to 7,
    // not 9 — otherwise both segments collapse to one speaker.
    func testOverlapTieResolvesToEarlierDiarizedRange() {
        let segs = [
            SegmentRange(start: 0, count: 32_000), // 0–2 s: 7 and 9 each overlap 1 s
            SegmentRange(start: 32_000, count: 16_000) // 2–3 s: speaker 9 only
        ]
        let diar = [range(0, 1, 7), range(1, 2, 9), range(2, 3, 9)]

        let labels = SpeakerMapping.assign(segmentRanges: segs, diarization: diar, sampleRate: 16_000)

        XCTAssertEqual(labels, [0, 1], "seg0 takes the earlier (7), so 7→0 and 9→1")
    }

    func testEmptyInputs() {
        XCTAssertEqual(SpeakerMapping.assign(segmentRanges: [], diarization: [], sampleRate: 16_000), [])
        XCTAssertEqual(
            SpeakerMapping.assign(
                segmentRanges: [SegmentRange(start: 0, count: 16_000)],
                diarization: [],
                sampleRate: 16_000
            ),
            [0]
        )
    }
}
