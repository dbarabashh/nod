import XCTest
@testable import Nod

/// The watchdog is the only thing in Nod that stops a recording nobody asked it
/// to stop, so its arithmetic is pinned rather than trusted.
final class AutoEndWatchdogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tick(
        _ watchdog: inout AutoEndWatchdog,
        at date: Date? = nil,
        prompt: AutoEndPrompt? = nil,
        lastSpeechAt: Date? = nil,
        startedAt: Date? = nil,
        hidIdle: TimeInterval = 0
    ) -> AutoEndWatchdog.Decision {
        watchdog.tick(
            now: date ?? now,
            prompt: prompt,
            lastSpeechAt: lastSpeechAt,
            recordingStartedAt: startedAt,
            hidIdleSeconds: hidIdle
        )
    }

    func testQuietStretchShorterThanTheThresholdDoesNothing() {
        var watchdog = AutoEndWatchdog()
        XCTAssertEqual(tick(&watchdog, startedAt: now.addingTimeInterval(-599)), .idle)
    }

    func testTenMinutesOfSilenceRaisesTheCountdown() {
        var watchdog = AutoEndWatchdog()
        guard case let .raise(prompt, _, away) = tick(&watchdog, startedAt: now.addingTimeInterval(-600))
        else { return XCTFail("expected the prompt to be raised") }
        XCTAssertEqual(prompt.secondsRemaining, 120)
        XCTAssertEqual(prompt.reason, .silence)
        XCTAssertFalse(away)
    }

    /// A user idle at the keyboard is a strong "walked away" hint, so the wait
    /// drops from ten minutes to three.
    func testAnIdleUserIsPromptedAfterThreeMinutes() {
        var watchdog = AutoEndWatchdog()
        let started = now.addingTimeInterval(-180)
        XCTAssertEqual(tick(&watchdog, startedAt: started), .idle)
        guard case let .raise(_, _, away) = tick(
            &watchdog,
            startedAt: started,
            hidIdle: AutoEndWatchdog.hidIdleAwaySeconds
        ) else { return XCTFail("expected the prompt to be raised") }
        XCTAssertTrue(away)
    }

    func testTheCountdownRunsOnWallClockAndEndsTheMeeting() {
        var watchdog = AutoEndWatchdog()
        _ = tick(&watchdog, startedAt: now.addingTimeInterval(-600))
        let prompt = AutoEndPrompt(secondsRemaining: 120)

        XCTAssertEqual(tick(&watchdog, at: now.addingTimeInterval(10), prompt: prompt), .countdown(110))
        XCTAssertEqual(tick(&watchdog, at: now.addingTimeInterval(120), prompt: prompt), .end)
    }

    /// Repeating the same second must not republish it — the prompt is
    /// `@Published`, and a redundant write redraws the panel every second.
    func testASecondThatHasNotChangedIsNotRepublished() {
        var watchdog = AutoEndWatchdog()
        _ = tick(&watchdog, startedAt: now.addingTimeInterval(-600))
        let prompt = AutoEndPrompt(secondsRemaining: 110)
        XCTAssertEqual(tick(&watchdog, at: now.addingTimeInterval(10), prompt: prompt), .idle)
    }

    func testSpeechDuringTheCountdownDismissesIt() {
        var watchdog = AutoEndWatchdog()
        _ = tick(&watchdog, lastSpeechAt: nil, startedAt: now.addingTimeInterval(-600))
        let decision = tick(
            &watchdog,
            at: now.addingTimeInterval(10),
            prompt: AutoEndPrompt(secondsRemaining: 120),
            lastSpeechAt: now.addingTimeInterval(5)
        )
        XCTAssertEqual(decision, .dismiss)
    }

    func testKeepingTheRecordingBacksOffTheThresholdUpToTheCap() {
        var watchdog = AutoEndWatchdog()
        XCTAssertEqual(watchdog.kept(reason: .silence, now: now), 2)
        XCTAssertEqual(watchdog.kept(reason: .silence, now: now), 4)
        XCTAssertEqual(watchdog.kept(reason: .silence, now: now), 8)
        XCTAssertEqual(watchdog.kept(reason: .silence, now: now), 8)
    }

    /// Conferencing-app detection flaps: a window that disappears, comes back and
    /// goes again would otherwise re-raise the countdown for the rest of the call.
    func testACallEndCountdownIsOfferedOnlyOncePerRecording() {
        var watchdog = AutoEndWatchdog()
        XCTAssertNotNil(watchdog.callEnded(app: "Zoom", now: now, lastSpeechAt: nil))
        watchdog.kept(reason: .callEnded(app: "Zoom"), now: now)
        XCTAssertNil(watchdog.callEnded(app: "Zoom", now: now, lastSpeechAt: nil))
    }

    func testANewRecordingStartsFromACleanSlate() {
        var watchdog = AutoEndWatchdog()
        watchdog.kept(reason: .callEnded(app: "Zoom"), now: now)
        watchdog.reset()
        XCTAssertEqual(watchdog.kept(reason: .silence, now: now), 2)
        XCTAssertNotNil(watchdog.callEnded(app: "Zoom", now: now, lastSpeechAt: nil))
    }

    // MARK: - Trailing silence

    func testTrailingSilenceIsTrimmedToTheLastSpeechPlusItsTail() {
        let started = now.addingTimeInterval(-3600)
        let trimmed = AutoEndWatchdog.trimmedEndDate(
            startedAt: started,
            lastSpeechAt: now.addingTimeInterval(-600),
            now: now
        )
        XCTAssertEqual(trimmed, now.addingTimeInterval(-570))
    }

    func testStoppingRightAfterTalkingKeepsTheRealEndTime() {
        let trimmed = AutoEndWatchdog.trimmedEndDate(
            startedAt: now.addingTimeInterval(-600),
            lastSpeechAt: now.addingTimeInterval(-2),
            now: now
        )
        XCTAssertEqual(trimmed, now)
    }

    func testAMeetingWithNoSpeechEndsWhenTheUserStopped() {
        let trimmed = AutoEndWatchdog.trimmedEndDate(
            startedAt: now.addingTimeInterval(-600),
            lastSpeechAt: nil,
            now: now
        )
        XCTAssertEqual(trimmed, now)
    }
}
