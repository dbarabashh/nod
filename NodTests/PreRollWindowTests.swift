import XCTest
@testable import Nod

/// The window pads a segment's onset with the audio just before it. Every way it
/// can fail is silent — a misaligned index or an exhausted window simply returns
/// nothing and the padding stops happening — so the arithmetic is pinned here
/// rather than discovered in a meeting.
final class PreRollWindowTests: XCTestCase {
    private let rate = 16_000

    /// A ramp, so a returned slice identifies exactly where it came from.
    private func ramp(_ range: Range<Int>) -> [Float] {
        range.map(Float.init)
    }

    private func feed(_ window: inout PreRollWindow, _ samples: [Float], at start: Int) {
        samples.withUnsafeBufferPointer { window.append($0, startingAt: start) }
    }

    /// Sizes as shipped: a quarter second prepended, thirty seconds reachable.
    private func liveWindow() -> PreRollWindow {
        PreRollWindow(retaining: 30 * rate, leadIn: rate / 4)
    }

    /// The regression the first version of this type shipped with, and the reason
    /// retention and lead-in are separate numbers.
    ///
    /// A segment reaches `drainSegments` only once its speech has ended *and* the
    /// silence that closes it has elapsed — so its onset is a whole utterance
    /// behind the write head. Sized to the lead-in alone, the window has always
    /// rolled past that onset, and every segment goes unpadded while every unit
    /// test of the arithmetic still passes.
    func testLeadInSurvivesTheDelayBetweenOnsetAndDrain() {
        var window = liveWindow()
        let onset = 2 * rate
        // Six seconds of speech, then the quarter second of silence that closes
        // the segment — the earliest the drain can see it.
        let writeHead = onset + 6 * rate + rate / 4
        feed(&window, ramp(0 ..< writeHead), at: 0)

        XCTAssertEqual(window.leadIn(before: onset).count, rate / 4)
    }

    /// Same shape, at the ceiling `SpeechSegmentSplit` enforces: a 25 s segment's
    /// onset must still be reachable when it finally drains.
    func testLeadInSurvivesASegmentAtTheSplitCeiling() {
        var window = liveWindow()
        let onset = rate
        feed(&window, ramp(0 ..< onset + 25 * rate + rate / 4), at: 0)

        XCTAssertEqual(window.leadIn(before: onset).count, rate / 4)
    }

    func testLeadInReturnsTheSamplesImmediatelyBeforeTheOnset() {
        var window = PreRollWindow(retaining: 100, leadIn: 4)
        feed(&window, ramp(0 ..< 10), at: 0)

        XCTAssertEqual(window.leadIn(before: 10), [6, 7, 8, 9])
    }

    func testLeadInIsCappedAtTheLeadInSizeNotTheRetention() {
        var window = PreRollWindow(retaining: 100, leadIn: 3)
        feed(&window, ramp(0 ..< 100), at: 0)

        XCTAssertEqual(window.leadIn(before: 100), [97, 98, 99])
    }

    /// The window rolls once retention is exceeded, so its own start advances.
    /// An onset addressed against the absolute clock must still land right.
    func testWindowTracksTheAbsoluteSampleClockAsItRolls() {
        var window = PreRollWindow(retaining: 4, leadIn: 4)
        feed(&window, ramp(0 ..< 6), at: 0)
        feed(&window, ramp(6 ..< 12), at: 6)

        XCTAssertEqual(window.start, 8)
        XCTAssertEqual(window.leadIn(before: 12), [8, 9, 10, 11])
    }

    /// Mid-window onsets happen whenever a segment starts inside a buffer rather
    /// than on its edge — the common case.
    func testLeadInStopsAtTheOnsetRatherThanRunningPastIt() {
        var window = PreRollWindow(retaining: 100, leadIn: 8)
        feed(&window, ramp(0 ..< 8), at: 0)

        XCTAssertEqual(window.leadIn(before: 5), [0, 1, 2, 3, 4])
    }

    /// The opening moments of a meeting: nothing precedes the first segment.
    func testLeadInIsEmptyAtTheStartOfTheStream() {
        var window = liveWindow()
        feed(&window, ramp(0 ..< 4), at: 0)

        XCTAssertEqual(window.leadIn(before: 0), [])
    }

    /// Past retention the onset is genuinely gone. Returning nothing is correct —
    /// returning the wrong samples would prepend audio from elsewhere entirely.
    func testLeadInIsEmptyForAnOnsetOlderThanRetention() {
        var window = PreRollWindow(retaining: 4, leadIn: 4)
        feed(&window, ramp(0 ..< 100), at: 0)

        XCTAssertEqual(window.leadIn(before: 10), [])
    }

    /// Guards the same-clock assumption: an onset past everything fed so far can
    /// only mean the window and the VAD have diverged.
    func testLeadInIsEmptyForAnOnsetBeyondWhatHasBeenFed() {
        var window = liveWindow()
        feed(&window, ramp(0 ..< 8), at: 0)

        XCTAssertEqual(window.leadIn(before: 999), [])
    }

    /// A lead-in wider than the retention is a misconfiguration, not a licence to
    /// read past the buffer.
    func testLeadInNeverExceedsRetention() {
        var window = PreRollWindow(retaining: 4, leadIn: 64)
        feed(&window, ramp(0 ..< 100), at: 0)

        XCTAssertEqual(window.leadInSamples, 4)
        XCTAssertEqual(window.leadIn(before: 100), [96, 97, 98, 99])
    }

    func testResetDropsTheWindowAndItsClock() {
        var window = liveWindow()
        feed(&window, ramp(0 ..< 8), at: 0)

        window.reset()

        XCTAssertEqual(window.start, 0)
        XCTAssertEqual(window.samples, [])
        XCTAssertEqual(window.leadIn(before: 8), [])
    }

    /// After a reset the clock restarts wherever the next meeting's audio does,
    /// so the first segment of the new stream still gets padded.
    func testWindowRealignsToTheNextStreamAfterReset() {
        var window = PreRollWindow(retaining: 100, leadIn: 4)
        feed(&window, ramp(0 ..< 8), at: 0)
        window.reset()

        feed(&window, ramp(0 ..< 4), at: 0)

        XCTAssertEqual(window.leadIn(before: 4), [0, 1, 2, 3])
    }
}
