import XCTest
@testable import Nod

final class WhisperSegmentSplitTests: XCTestCase {
    private let rate = 16_000

    private func tone(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        [Float](repeating: amplitude, count: Int(Double(rate) * seconds))
    }

    func testSegmentWithinCeilingPassesThroughWhole() {
        let samples = tone(seconds: 12)
        let pieces = SpeechSegmentSplit.pieces(of: samples)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].count, samples.count)
    }

    func testProductionWorstCaseSplitsIntoWhisperSizedPieces() {
        let pieces = SpeechSegmentSplit.pieces(of: tone(seconds: 97.7))
        XCTAssertEqual(pieces.count, 4)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 30 * rate, "every piece must fit Whisper's 30s window")
        }
    }

    func testPiecesTileTheSegmentWithoutGapOrOverlap() {
        let samples = tone(seconds: 60)
        let pieces = SpeechSegmentSplit.pieces(of: samples)
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), samples.count)
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(previous.endIndex, next.startIndex)
        }
        XCTAssertEqual(pieces[0].startIndex, 0)
    }

    func testCutsAtTheQuietestPointNotTheCeiling() {
        var samples = tone(seconds: 40)
        // A 0.4s pause 2s before the ceiling — the cut should land there, not at 25s.
        let silenceStart = Int(22.8 * Double(rate))
        let silenceCount = Int(0.4 * Double(rate))
        for offset in silenceStart ..< silenceStart + silenceCount {
            samples[offset] = 0
        }

        let pieces = SpeechSegmentSplit.pieces(of: samples)
        let cut = pieces[0].endIndex
        XCTAssertGreaterThanOrEqual(cut, silenceStart)
        XCTAssertLessThanOrEqual(cut, silenceStart + silenceCount)
    }

    func testSliceOffsetsMapBackToSourceSamples() {
        let pieces = SpeechSegmentSplit.pieces(of: tone(seconds: 55))
        // `drainSegments` derives each piece's timestamp from segment.start +
        // piece.startIndex, so the slices must stay based on the original array.
        XCTAssertEqual(pieces.last?.endIndex, 55 * rate)
    }
}
