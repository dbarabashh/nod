import XCTest
@testable import Nod

final class SpeakerAssignmentTests: XCTestCase {
    private func turn(_ start: TimeInterval, _ end: TimeInterval, _ speaker: Int) -> DiarizedTurn {
        DiarizedTurn(start: start, end: end, speaker: speaker)
    }

    func testNormalizedCompactsSparseClusterIds() {
        let turns = [turn(0, 1, 3), turn(1, 2, 8), turn(2, 3, 3)]

        XCTAssertEqual(SpeakerAssignment.normalized(turns).map(\.speaker), [1, 2, 1])
    }

    func testNormalizedLabelsByFirstAppearanceNotByRawOrder() {
        let turns = [turn(5, 6, 0), turn(0, 1, 7)]

        let normalized = SpeakerAssignment.normalized(turns)

        XCTAssertEqual(normalized.map(\.start), [0, 5])
        XCTAssertEqual(normalized.map(\.speaker), [1, 2])
    }

    func testNormalizedKeepsBoundariesIntact() {
        let normalized = SpeakerAssignment.normalized([turn(1.25, 3.5, 4)])

        XCTAssertEqual(normalized.first?.start, 1.25)
        XCTAssertEqual(normalized.first?.end, 3.5)
    }

    func testSpeakerPicksTheCoveringTurn() {
        let turns = [turn(0, 5, 1), turn(5, 10, 2)]

        XCTAssertEqual(SpeakerAssignment.speaker(from: 6, to: 9, in: turns), 2)
    }

    func testOverlappingSpeechResolvesToTheGreaterOverlap() {
        // Simultaneous speech surfaces as intersecting turns rather than a
        // flag, so a chunk can match two speakers at once.
        let turns = [turn(11.46, 12.97, 1), turn(12.67, 13.77, 2)]

        XCTAssertEqual(SpeakerAssignment.speaker(from: 12.6, to: 13.6, in: turns), 2)
        XCTAssertEqual(SpeakerAssignment.speaker(from: 11.5, to: 12.8, in: turns), 1)
    }

    func testTieGoesToTheEarlierTurn() {
        let turns = [turn(0, 2, 1), turn(2, 4, 2)]

        XCTAssertEqual(SpeakerAssignment.speaker(from: 1, to: 3, in: turns), 1)
    }

    func testChunkInSilenceHasNoSpeaker() {
        let turns = [turn(0, 1, 1), turn(10, 11, 2)]

        XCTAssertNil(SpeakerAssignment.speaker(from: 4, to: 6, in: turns))
    }

    func testTouchingBoundaryIsNotOverlap() {
        XCTAssertNil(SpeakerAssignment.speaker(from: 5, to: 7, in: [turn(0, 5, 1)]))
    }

    func testEmptySpanHasNoSpeaker() {
        XCTAssertNil(SpeakerAssignment.speaker(from: 3, to: 3, in: [turn(0, 5, 1)]))
    }

    func testSpansResolveThroughTheConcatenatedSpeechTimeline() {
        let first = UUID()
        let second = UUID()
        let spans = [
            DiarizationBuffer.Span(id: first, startSample: 0, endSample: 16_000),
            DiarizationBuffer.Span(id: second, startSample: 16_000, endSample: 32_000)
        ]
        let turns = [turn(0, 1, 1), turn(1, 2, 2)]

        let resolved = DiarizationBuffer.speakers(for: spans, in: turns, sampleRate: 16_000)

        XCTAssertEqual(resolved[first], 1)
        XCTAssertEqual(resolved[second], 2)
    }

    func testUnattributedSpanIsOmittedRatherThanGuessed() {
        let span = DiarizationBuffer.Span(id: UUID(), startSample: 96_000, endSample: 112_000)

        let resolved = DiarizationBuffer.speakers(for: [span], in: [turn(0, 1, 1)], sampleRate: 16_000)

        XCTAssertTrue(resolved.isEmpty)
    }

    func testRecordingSegmentsBuildsContiguousSpans() {
        let buffer = DiarizationBuffer()
        let first = buffer.record([Float](repeating: 0.5, count: 16_000))
        let second = buffer.record([Float](repeating: -0.5, count: 8_000))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(buffer.retainedSeconds, 1.5, accuracy: 0.001)
        XCTAssertFalse(buffer.isEmpty)
    }

    func testEmptySegmentIsNotRecorded() {
        let buffer = DiarizationBuffer()

        XCTAssertNil(buffer.record([]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testVoiceNoteIsNeverDiarized() {
        XCTAssertFalse(SessionKind.voiceNote.supportsDiarization)
        XCTAssertTrue(SessionKind.meeting.supportsDiarization)
        XCTAssertTrue(SessionKind.media.supportsDiarization)
    }
}

final class DiarizationBufferCapacityTests: XCTestCase {
    func testBufferStopsGrowingPastItsCap() {
        let buffer = DiarizationBuffer(sampleRate: 16_000, maxRetainedSeconds: 1)
        let halfSecond = [Float](repeating: 0.2, count: 8_000)

        XCTAssertNotNil(buffer.record(halfSecond))
        XCTAssertNotNil(buffer.record(halfSecond))
        // Third segment would exceed one second of retained speech.
        XCTAssertNil(buffer.record(halfSecond))
        XCTAssertEqual(buffer.retainedSeconds, 1, accuracy: 0.001)
    }

    func testEarlierSpansStillResolveAfterTheCap() {
        let buffer = DiarizationBuffer(sampleRate: 16_000, maxRetainedSeconds: 1)
        let id = buffer.record([Float](repeating: 0.2, count: 16_000))
        XCTAssertNil(buffer.record([Float](repeating: 0.2, count: 16_000)))

        XCTAssertNotNil(id)
        XCTAssertFalse(buffer.isEmpty)
    }

    func testDefaultCapIsNinetyMinutes() {
        XCTAssertEqual(DiarizationBuffer.maxRetainedSeconds, 5400)
    }
}

final class TranscriptLabelTests: XCTestCase {
    private func record(source: String, speaker: Int?) -> TranscriptRecord {
        TranscriptRecord(
            id: UUID(),
            meetingID: UUID(),
            userID: UUID(),
            createdAt: nil,
            source: source,
            text: "hello",
            ts: Date(timeIntervalSince1970: 0),
            idx: 0,
            speaker: speaker
        )
    }

    func testResolvedSpeakerNarrowsTheThemLabel() {
        XCTAssertEqual(record(source: "them", speaker: 2).displayLabel(), "Them · Speaker 2")
    }

    func testUnresolvedLinesKeepThePlainLabel() {
        XCTAssertEqual(record(source: "them", speaker: nil).displayLabel(), "Them")
    }

    /// The user's own mic is a single known speaker and is never clustered, so a
    /// stray value must not turn "Me" into "Me · Speaker 1".
    func testTheUserIsNeverGivenASpeakerNumber() {
        XCTAssertEqual(record(source: "me", speaker: 1).displayLabel(), "Me")
    }

    func testDroppingSpeakerFallsBackToThePlainLabel() {
        XCTAssertEqual(record(source: "them", speaker: 3).droppingSpeaker().displayLabel(), "Them")
    }

    func testANamedClusterRendersAsThePersonAlone() {
        XCTAssertEqual(
            record(source: "them", speaker: 2).displayLabel(names: ["2": "Eric Johnson"]),
            "Eric Johnson"
        )
    }

    /// `[Them]` is a routing hint every playbook rule keys on, so the prompt
    /// label narrows it with the name instead of dropping it.
    func testThePromptLabelKeepsTheRoutingTag() {
        XCTAssertEqual(
            record(source: "them", speaker: 2).promptLabel(names: ["2": "Eric Johnson"]),
            "Them · Eric Johnson"
        )
        XCTAssertEqual(record(source: "them", speaker: 2).promptLabel(), "Them · Speaker 2")
        XCTAssertEqual(record(source: "me", speaker: nil).promptLabel(names: ["1": "Eric"]), "Me")
    }

    /// Naming is sparse by design — the extraction pass only maps clusters the
    /// transcript identifies outright, so the rest must keep their number.
    func testAnUnnamedClusterKeepsItsNumber() {
        XCTAssertEqual(
            record(source: "them", speaker: 3).displayLabel(names: ["2": "Eric Johnson"]),
            "Them · Speaker 3"
        )
    }

    /// A model that answers `{"2": ""}` must not produce a dangling "Them · ".
    func testABlankNameFallsBackToTheNumber() {
        XCTAssertEqual(
            record(source: "them", speaker: 2).displayLabel(names: ["2": "   "]),
            "Them · Speaker 2"
        )
    }

    func testNamesNeverApplyToTheUsersOwnSide() {
        XCTAssertEqual(record(source: "me", speaker: 1).displayLabel(names: ["1": "Eric"]), "Me")
    }
}

final class TranscriptPromptContextTests: XCTestCase {
    private func record(_ idx: Int, source: String, speaker: Int?, text: String) -> TranscriptRecord {
        TranscriptRecord(
            id: UUID(),
            meetingID: UUID(),
            userID: UUID(),
            createdAt: nil,
            source: source,
            text: text,
            ts: Date(timeIntervalSince1970: Double(idx)),
            idx: idx,
            speaker: speaker
        )
    }

    /// Every surface that grounds a model in a saved meeting must hand it the
    /// same shape, or a playbook rule keyed on `[Them]` fires on one and not
    /// the other.
    func testContextTagsEveryLineTheSameWay() {
        let records = [
            record(0, source: "me", speaker: nil, text: "hi"),
            record(1, source: "them", speaker: 2, text: "hello"),
            record(2, source: "them", speaker: 3, text: "morning")
        ]

        XCTAssertEqual(
            records.promptContext(names: ["2": "Eric"]),
            "[Me]: hi\n[Them · Eric]: hello\n[Them · Speaker 3]: morning"
        )
    }
}
