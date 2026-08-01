import XCTest
@testable import Nod

@MainActor
final class UISoundTests: XCTestCase {
    /// The silence rule, asserted rather than trusted: anything Nod plays on
    /// speakers is heard by the whole call and re-enters through our own
    /// microphone. Exactly one cue is allowed to break it, and only because it
    /// announces a countdown that ends the recording by itself.
    func testOnlyTheCountdownCueMaySoundWhileRecording() {
        XCTAssertTrue(UISound.actionRequired.interruptsRecording)
        XCTAssertFalse(UISound.meetingDetected.interruptsRecording)
        XCTAssertFalse(UISound.summaryReady.interruptsRecording)
    }

    /// A cue whose file is missing is a cue that silently never plays, and the
    /// resource name is a string the compiler does not check.
    func testEveryCueHasItsFileInTheBundle() {
        for sound in [UISound.meetingDetected, .summaryReady, .actionRequired] {
            XCTAssertNotNil(
                Bundle(for: Self.self).url(forResource: sound.rawValue, withExtension: "wav")
                    ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "wav"),
                "\(sound.rawValue).wav is not in the bundle"
            )
        }
    }
}
