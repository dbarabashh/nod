import XCTest
@testable import Nod

/// The scorer is the instrument every diarization decision will be read
/// through, so it is checked against cases whose answer is known by hand. These
/// need no audio and run in CI; the fixture runs that use it do not.
final class DiarizationScoreTests: XCTestCase {
    private let lines = (0 ..< 4).map { _ in UUID() }

    private var truth: [UUID: String] {
        [lines[0]: "Anna", lines[1]: "Anna", lines[2]: "Leo", lines[3]: "Leo"]
    }

    func testPerfectRunScoresFullWhateverTheClusterNumbersAre() {
        // Cluster ids are arbitrary, so numbering Leo first must not be an error.
        let hypothesis = [lines[0]: 7, lines[1]: 7, lines[2]: 3, lines[3]: 3]
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: truth)
        XCTAssertEqual(score.accuracy, 1, accuracy: 0.001)
        XCTAssertEqual(score.speakerCountError, 0)
        XCTAssertEqual(score.mapping[7], "Anna")
        XCTAssertEqual(score.mapping[3], "Leo")
    }

    func testTwoVoicesMergedIntoOneLosesHalfTheLines() {
        let hypothesis = lines.reduce(into: [UUID: Int]()) { $0[$1] = 1 }
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: truth)
        XCTAssertEqual(score.confusion, 0.5, accuracy: 0.001)
        XCTAssertEqual(score.unattributed, 0, accuracy: 0.001)
        XCTAssertEqual(score.speakerCountError, -1)
    }

    func testAPhantomSpeakerShowsAsWrongLinesPlusACountError() {
        // Leo's two lines land in separate clusters — the rollback's failure.
        let hypothesis = [lines[0]: 1, lines[1]: 1, lines[2]: 2, lines[3]: 3]
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: truth)
        XCTAssertEqual(score.speakerCountError, 1)
        XCTAssertEqual(score.confusion, 0.25, accuracy: 0.001)
    }

    func testAnUnlabelledLineIsUnattributedNotWrong() {
        // The pipeline leaves a span holding two voices alone rather than
        // handing it to whoever occupied more of it. That is a different, and
        // much cheaper, failure than naming it wrongly.
        let hypothesis = [lines[0]: 1, lines[1]: 1, lines[2]: 2]
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: truth)
        XCTAssertEqual(score.unattributed, 0.25, accuracy: 0.001)
        XCTAssertEqual(score.confusion, 0, accuracy: 0.001)
    }

    func testSwappedSpeakersAreEntirelyWrong() {
        // No mapping rescues this, which is the point — it is the failure the
        // user actually notices in a summary they have already shared.
        let hypothesis = [lines[0]: 1, lines[1]: 2, lines[2]: 1, lines[3]: 2]
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: truth)
        XCTAssertEqual(score.speakerCountError, 0)
        XCTAssertEqual(score.confusion, 0.5, accuracy: 0.001)
    }

    func testEmptyRunIsEntirelyUnattributed() {
        let score = DiarizationScorer.score(hypothesis: [:], truth: truth)
        XCTAssertEqual(score.unattributed, 1, accuracy: 0.001)
        XCTAssertEqual(score.accuracy, 0, accuracy: 0.001)
        XCTAssertEqual(score.speakerCountError, -2)
    }

    func testLinesTheFixtureLeftUnlabelledAreNotScored() {
        // Crosstalk a person could not attribute either is left out of the
        // ground truth rather than guessed at, and must not count against a run.
        let partial = [lines[0]: "Anna", lines[2]: "Leo"]
        let hypothesis = [lines[0]: 1, lines[1]: 9, lines[2]: 2, lines[3]: 9]
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: partial)
        XCTAssertEqual(score.accuracy, 1, accuracy: 0.001)
        XCTAssertEqual(score.lines, 2)
    }
}
