import XCTest
@testable import Nod

final class MeetingDetectionTests: XCTestCase {
    // MARK: - Which app is in a call

    func testNativeAppWithACallWindowIsTheCall() {
        let signals = CallSignals(running: [.zoom, .chrome], inCall: [.zoom])
        XCTAssertEqual(MeetingDetection.call(in: signals), .zoom)
    }

    func testRunningAloneIsNotACall() {
        // Zoom sits in the menu bar all day; that is not a meeting.
        let signals = CallSignals(running: [.zoom])
        XCTAssertNil(MeetingDetection.call(in: signals))
    }

    func testAnAppHoldingTheMicrophoneIsInACall() {
        let signals = CallSignals(running: [.slack], micUsers: [.slack])
        XCTAssertEqual(MeetingDetection.call(in: signals), .slack)
    }

    func testAnotherAppsMicrophoneIsNotThisAppsCall() {
        // The reported bug: Slack is open all day, Chrome is in a Meet call, and
        // "somebody is using the mic" was blamed on Slack.
        let signals = CallSignals(running: [.slack, .chrome], micUsers: [.chrome])
        XCTAssertNil(MeetingDetection.call(in: signals))
    }

    func testMicrophoneNeverConfirmsABrowserOnItsOwn() {
        // A browser holding the mic is as likely to be a voice message.
        let signals = CallSignals(running: [.chrome], micUsers: [.chrome])
        XCTAssertNil(MeetingDetection.call(in: signals))
    }

    func testBrowserNeedsItsWindowTitle() {
        let signals = CallSignals(running: [.chrome], inCall: [.chrome])
        XCTAssertEqual(MeetingDetection.call(in: signals), .chrome)
    }

    func testAConfirmedCallOutranksAMicrophoneGuess() {
        let signals = CallSignals(running: [.slack, .chrome], inCall: [.chrome], micUsers: [.slack])
        XCTAssertEqual(MeetingDetection.call(in: signals), .chrome)
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
        XCTAssertNil(state.advance(call: .zoom, isStrong: true, isRecording: false))
    }

    func testTwoSightingsInvite() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        XCTAssertEqual(state.advance(call: .zoom, isStrong: true, isRecording: false), .invite(.zoom))
    }

    func testTheSameCallOnlyInvitesOnce() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        XCTAssertNil(state.advance(call: .zoom, isStrong: true, isRecording: false))
    }

    func testAnAnsweredCallNeverAsksAgain() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        state.markHandled()
        XCTAssertNil(state.advance(call: .zoom, isStrong: true, isRecording: false))
        XCTAssertNil(state.advance(call: .zoom, isStrong: true, isRecording: false))
    }

    func testAFlickeringCallDoesNotClearOnOneMiss() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: true)
        XCTAssertNil(state.advance(call: nil, isStrong: false, isRecording: true))
        XCTAssertNil(state.advance(call: nil, isStrong: false, isRecording: true))
    }

    func testAConfirmedCallEndsTheRecording() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: true)
        _ = state.advance(call: nil, isStrong: false, isRecording: true)
        _ = state.advance(call: nil, isStrong: false, isRecording: true)
        XCTAssertEqual(state.advance(call: nil, isStrong: false, isRecording: true), .callEnded(.zoom))
    }

    func testAMicOnlyCallNeverEndsTheRecording() {
        // Our own recording holds the same microphone, so its disappearance is
        // not evidence of anything — and a wrong auto-finish cuts a live
        // meeting short.
        var state = MeetingDetectionState()
        _ = state.advance(call: .slack, isStrong: false, isRecording: true)
        _ = state.advance(call: nil, isStrong: false, isRecording: true)
        _ = state.advance(call: nil, isStrong: false, isRecording: true)
        XCTAssertNil(state.advance(call: nil, isStrong: false, isRecording: true))
    }

    func testACallThatEndsWithoutARecordingJustClears() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        _ = state.advance(call: nil, isStrong: false, isRecording: false)
        _ = state.advance(call: nil, isStrong: false, isRecording: false)
        XCTAssertEqual(state.advance(call: nil, isStrong: false, isRecording: false), .withdraw)
    }

    func testRecordingWithdrawsAnUnansweredInvitation() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        XCTAssertEqual(state.advance(call: .zoom, isStrong: true, isRecording: true), .withdraw)
    }

    func testStoppingMidCallDoesNotReAsk() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: true)
        // User ends the recording while the call carries on.
        XCTAssertNil(state.advance(call: .zoom, isStrong: true, isRecording: false))
        XCTAssertNil(state.advance(call: .zoom, isStrong: true, isRecording: false))
    }

    func testSwitchingAppsIsANewCall() {
        var state = MeetingDetectionState()
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        _ = state.advance(call: .zoom, isStrong: true, isRecording: false)
        state.markHandled()
        _ = state.advance(call: .chrome, isStrong: true, isRecording: false)
        XCTAssertEqual(state.advance(call: .chrome, isStrong: true, isRecording: false), .invite(.chrome))
    }

    // MARK: - Prompt copy

    func testACallEndedPromptSurvivesSomeoneStillTalking() {
        XCTAssertFalse(AutoEndPrompt.Reason.callEnded(app: "Zoom").dismissesOnSpeech)
        XCTAssertTrue(AutoEndPrompt.Reason.silence.dismissesOnSpeech)
    }

    func testTheCardNamesTheApp() {
        let prompt = AutoEndPrompt(secondsRemaining: 30, reason: .callEnded(app: "Zoom"))
        XCTAssertEqual(prompt.title, "Zoom call ended")
        XCTAssertEqual(prompt.detail, "Wrapping up and summarising in 0:30")
    }
}
