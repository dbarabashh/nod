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
