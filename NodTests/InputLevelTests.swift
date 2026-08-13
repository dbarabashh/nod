import XCTest
@testable import Nod

@MainActor
final class InputLevelTests: XCTestCase {
    /// A quiet room, one buffer at a time: silence is not literal zero at the
    /// mic, so the meter only goes flat if the hold is allowed to decay all the
    /// way there. Decaying off the published value instead stalls it — each
    /// step is a fifth of the level, so the steps shrink inside the publish
    /// deadband and the meter freezes part-raised for the rest of the meeting.
    func testHoldDecaysToZeroThroughSilence() {
        let level = InputLevel()
        level.hold(peak: 0.9)

        for _ in 0 ..< 60 {
            level.hold(peak: 0.0005)
        }

        XCTAssertEqual(level.value, 0)
    }

    func testHoldRisesInstantlyToALoudFrame() {
        let level = InputLevel()

        level.hold(peak: 0.7)

        XCTAssertEqual(level.value, 0.7, accuracy: 0.0001)
    }

    /// The deadband's own job: a hold sitting still must not republish, or the
    /// meter restarts its animation on capsules already where they belong.
    func testRepeatedIdenticalPeaksSettleAndStopMoving() {
        let level = InputLevel()
        level.hold(peak: 0.5)

        for _ in 0 ..< 20 {
            level.hold(peak: 0.5)
        }

        XCTAssertEqual(level.value, 0.5, accuracy: 0.0001)
    }

    func testResetFlattensAPartlyDecayedMeter() {
        let level = InputLevel()
        level.hold(peak: 0.6)
        level.hold(peak: 0)

        level.reset()

        XCTAssertEqual(level.value, 0)
    }

    /// Mute zeroes through `reset()` on every buffer, and the hold has to stay
    /// zeroed with it — a decay resuming from the pre-mute level would flash
    /// the meter back up on unmute before the first real frame arrives.
    func testHoldResumesFromZeroAfterReset() {
        let level = InputLevel()
        level.hold(peak: 0.8)
        level.reset()

        level.hold(peak: 0.1)

        XCTAssertEqual(level.value, 0.1, accuracy: 0.0001)
    }
}
