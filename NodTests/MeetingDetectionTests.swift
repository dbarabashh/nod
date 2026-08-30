import XCTest
@testable import Nod

final class MeetingDetectionTests: XCTestCase {
    // MARK: - Which app is in a call

    func testNativeAppWithACallWindowIsTheCall() {
        let signals = CallSignals(running: [.zoom, .chrome], titles: [.zoom: "Zoom Meeting"])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.app, .zoom)
    }

    func testRunningAloneIsNotACall() {
        // Zoom sits in the menu bar all day; that is not a meeting.
        let signals = CallSignals(running: [.zoom])
        XCTAssertNil(MeetingDetection.call(in: signals))
    }

    func testAnAppHoldingTheMicrophoneIsInACall() {
        let signals = CallSignals(running: [.slack], micUsers: [.slack])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.app, .slack)
    }

    /// The reported bug: Slack is open all day, Chrome is in a Meet call, and
    /// "somebody is using the mic" was blamed on Slack. The call is Chrome's.
    func testAnotherAppsMicrophoneIsNotThisAppsCall() {
        let signals = CallSignals(running: [.slack, .chrome], micUsers: [.chrome])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.app, .chrome)
    }

    /// The reported bug: a Meet call in a background tab has no window of its
    /// own — the window's title is whichever tab is in front — so the microphone
    /// is the only thing left that can see it. It is believed, but slowly: a
    /// voice message holds the mic too, for seconds rather than minutes.
    func testABrowserHoldingTheMicrophoneIsACallItJustTakesLonger() {
        let signals = CallSignals(running: [.chrome], micUsers: [.chrome])
        let call = MeetingDetection.call(in: signals)
        XCTAssertEqual(call?.app, .chrome)
        XCTAssertEqual(call?.kind, .browserMicrophone)
        XCTAssertGreaterThan(
            DetectedEvidence.Kind.browserMicrophone.sightingsToInvite,
            DetectedEvidence.Kind.window.sightingsToInvite * 4
        )
    }

    /// A browser's microphone must never end a recording: our own recording
    /// holds the mic too, and a lull is not a hang-up.
    func testABrowserMicrophoneCannotArmTheAutomaticFinish() {
        XCTAssertFalse(DetectedEvidence.Kind.browserMicrophone.armsAutoFinish)
        XCTAssertFalse(DetectedEvidence.Kind.window.armsAutoFinish)
        XCTAssertTrue(DetectedEvidence.Kind.helper.armsAutoFinish)
    }

    /// A title still outranks the microphone: it names the call, and it is
    /// believed in two ticks rather than twelve.
    func testABrowserWindowTitleOutranksItsMicrophone() {
        let signals = CallSignals(running: [.chrome], micUsers: [.chrome], titles: [.chrome: "Meet – abc"])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.kind, .window)
    }

    func testBrowserNeedsItsWindowTitle() {
        let signals = CallSignals(running: [.chrome], titles: [.chrome: "Meet – abc-defg-hij"])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.app, .chrome)
    }

    func testAHelperBackedCallIsAlsoJustACall() {
        // `helperBacked` is a narrowing of `inCall`, not a separate way in: the
        // helper still has to confirm the call before it can arm anything.
        let signals = CallSignals(running: [.zoom], helperBacked: [.zoom])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.app, .zoom)
    }

    func testAConfirmedCallOutranksAMicrophoneGuess() {
        let signals = CallSignals(running: [.slack, .chrome], micUsers: [.slack], titles: [.chrome: "Meet – abc-defg-hij"])
        XCTAssertEqual(MeetingDetection.call(in: signals)?.app, .chrome)
    }

    // MARK: - Window titles

    func testTitlesThatNameALiveCall() {
        XCTAssertTrue(MeetingDetection.namesActiveCall("Zoom Meeting"))
        XCTAssertTrue(MeetingDetection.namesActiveCall("Meet – abc-defg-hij"))
        XCTAssertTrue(MeetingDetection.namesActiveCall("Meeting in Product — Microsoft Teams"))
        XCTAssertTrue(MeetingDetection.namesActiveCall("Standup | meet.google.com"))
    }

    func testTitlesThatDoNot() {
        // The bare app windows: open all day, and not a call.
        XCTAssertFalse(MeetingDetection.namesActiveCall("Chat | Microsoft Teams"))
        XCTAssertFalse(MeetingDetection.namesActiveCall("Zoom Workplace"))
        XCTAssertFalse(MeetingDetection.namesActiveCall("Webex"))
        // Documents that merely talk about meetings.
        XCTAssertFalse(MeetingDetection.namesActiveCall("Meeting notes — Notion"))
        XCTAssertFalse(MeetingDetection.namesActiveCall("Huddle notes — Notion"))
        XCTAssertFalse(MeetingDetection.namesActiveCall("Huddle"))
        XCTAssertFalse(MeetingDetection.namesActiveCall("Inbox (12)"))
    }

    // MARK: - The state machine

    func testOneSightingIsNotEnoughToAsk() {
        var state = MeetingDetectionState()
        XCTAssertNil(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false))
    }

    func testTwoSightingsInvite() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        XCTAssertEqual(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false), .invite(.zoom))
    }

    func testTheSameCallOnlyInvitesOnce() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        XCTAssertNil(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false))
    }

    func testAnAnsweredCallNeverAsksAgain() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        state.markHandled()
        XCTAssertNil(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false))
        XCTAssertNil(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false))
    }

    func testAFlickeringCallDoesNotClearOnOneMiss() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: true)
        XCTAssertNil(state.advance(evidence: nil, isRecording: true))
        XCTAssertNil(state.advance(evidence: nil, isRecording: true))
    }

    func testATitleOnlyCallNeverEndsTheRecording() {
        // Chrome showed a Meet title all through the meeting, then stopped —
        // because the user changed tab, not because the call was over.
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .chrome, kind: .window), isRecording: true)
        _ = state.advance(evidence: nil, isRecording: true)
        _ = state.advance(evidence: nil, isRecording: true)
        XCTAssertNil(state.advance(evidence: nil, isRecording: true))
    }

    func testAHelperBackedCallEndsTheRecording() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: true)
        _ = state.advance(evidence: nil, isRecording: true)
        _ = state.advance(evidence: nil, isRecording: true)
        XCTAssertEqual(state.advance(evidence: nil, isRecording: true), .callEnded(.zoom))
    }

    func testAMicOnlyCallNeverEndsTheRecording() {
        // Our own recording holds the same microphone, so its disappearance is
        // not evidence of anything — and a wrong auto-finish cuts a live
        // meeting short.
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .slack, kind: .window), isRecording: true)
        _ = state.advance(evidence: nil, isRecording: true)
        _ = state.advance(evidence: nil, isRecording: true)
        XCTAssertNil(state.advance(evidence: nil, isRecording: true))
    }

    func testACallThatEndsWithoutARecordingJustClears() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        _ = state.advance(evidence: nil, isRecording: false)
        _ = state.advance(evidence: nil, isRecording: false)
        XCTAssertEqual(state.advance(evidence: nil, isRecording: false), .withdraw)
    }

    func testRecordingWithdrawsAnUnansweredInvitation() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        XCTAssertEqual(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: true), .withdraw)
    }

    func testStoppingMidCallDoesNotReAsk() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: true)
        // User ends the recording while the call carries on.
        XCTAssertNil(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false))
        XCTAssertNil(state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false))
    }

    func testSwitchingAppsIsANewCall() {
        var state = MeetingDetectionState()
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        _ = state.advance(evidence: DetectedEvidence(app: .zoom, kind: .helper), isRecording: false)
        state.markHandled()
        _ = state.advance(evidence: DetectedEvidence(app: .chrome, kind: .helper), isRecording: false)
        XCTAssertEqual(state.advance(evidence: DetectedEvidence(app: .chrome, kind: .helper), isRecording: false), .invite(.chrome))
    }

    // MARK: - Prompt copy

    func testTheCardNamesTheApp() {
        let prompt = AutoEndPrompt(secondsRemaining: 30, reason: .callEnded(app: "Zoom"))
        XCTAssertEqual(prompt.title, "Zoom call ended")
        XCTAssertEqual(prompt.detail, "Wrapping up and summarising in 0:30")
    }
}
