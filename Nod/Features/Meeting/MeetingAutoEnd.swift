import Foundation

/// The forgot-to-stop watchdog: when to raise the countdown, how fast it runs,
/// and when a recording ends on its own.
///
/// A value type holding only the timing state, deliberately: every decision it
/// reaches is returned rather than acted on, so the `@Published` prompt and the
/// call to `endMeeting()` stay in `MeetingSession` where SwiftUI can see them.
/// Nothing that can stop a recording should be reachable from two places.
struct AutoEndWatchdog {
    /// What this second's tick concluded. `.idle` is the answer almost every
    /// time — a recording runs for an hour without any of the rest firing.
    enum Decision: Equatable {
        case idle
        /// Someone spoke — the meeting is live after all.
        case dismiss
        case countdown(Int)
        case raise(AutoEndPrompt, silence: Int, away: Bool)
        case end
    }

    /// Silence needed to prompt when the user seems present (base) vs when
    /// they're idle at the keyboard/mouse — a strong "walked away" hint. A
    /// locked screen also stops delivering HID events, so idle subsumes lock;
    /// system sleep suspends the timer, so that silence accrues for free on wake.
    private static let baseSilenceSeconds: TimeInterval = 600
    private static let awaySilenceSeconds: TimeInterval = 180
    private static let maxSilenceSeconds: TimeInterval = 2400
    static let hidIdleAwaySeconds: TimeInterval = 300
    private static let maxSilenceBackoff: Double = 8
    private static let countdownSeconds = 120
    /// Shorter than the silence countdown because the evidence is better: the
    /// call is demonstrably over, and the two minutes a silent stretch earns
    /// would just be two minutes of an empty room in the transcript.
    private static let callEndedCountdownSeconds = 30

    /// Silence is measured from the latest of the store's last speech, this
    /// (a resume or a "keep recording" tap), and the recording's start.
    private var inactivityResetAt: Date?
    /// While the prompt is up: its wall-clock auto-end time, and the speech
    /// marker captured when it was raised — any change to it dismisses it.
    private var promptDeadline: Date?
    private var speechAtPromptRaise: Date?
    /// Doubles on each "keep recording" so repeat prompts get progressively
    /// rarer.
    private var silenceBackoff: Double = 1
    /// Set when the user keeps a recording the *call* was said to have ended.
    /// Detection can flap — a conferencing window that reappears and goes again
    /// would otherwise re-raise the countdown every couple of minutes for the
    /// rest of the meeting.
    private var callEndDeclined = false

    mutating func reset() {
        inactivityResetAt = nil
        silenceBackoff = 1
        callEndDeclined = false
        clearPrompt()
    }

    mutating func clearPrompt() {
        promptDeadline = nil
        speechAtPromptRaise = nil
    }

    /// Measure silence from now rather than from the last pre-pause speech, so
    /// resuming doesn't instantly trip the prompt.
    mutating func noteActivity(at date: Date) {
        inactivityResetAt = date
    }

    mutating func tick(
        now: Date,
        prompt: AutoEndPrompt?,
        lastSpeechAt: Date?,
        recordingStartedAt: Date?,
        hidIdleSeconds: @autoclosure () -> TimeInterval
    ) -> Decision {
        if let prompt {
            return countdown(prompt, now: now, lastSpeechAt: lastSpeechAt)
        }
        // Pairwise rather than through an array literal: this runs every second
        // for the length of every recording, and the array was the only
        // allocation on the path.
        let lastActivity = Self.latest(lastSpeechAt, inactivityResetAt, recordingStartedAt) ?? now
        let silence = now.timeIntervalSince(lastActivity)
        let away = hidIdleSeconds() >= Self.hidIdleAwaySeconds
        let base = away ? Self.awaySilenceSeconds : Self.baseSilenceSeconds
        guard silence >= min(base * silenceBackoff, Self.maxSilenceSeconds) else { return .idle }

        promptDeadline = now.addingTimeInterval(TimeInterval(Self.countdownSeconds))
        speechAtPromptRaise = lastSpeechAt
        return .raise(
            AutoEndPrompt(secondsRemaining: Self.countdownSeconds),
            silence: Int(silence),
            away: away
        )
    }

    private static func latest(_ first: Date?, _ second: Date?, _ third: Date?) -> Date? {
        var newest = first
        if let second { newest = newest.map { max($0, second) } ?? second }
        if let third { newest = newest.map { max($0, third) } ?? third }
        return newest
    }

    private mutating func countdown(
        _ prompt: AutoEndPrompt,
        now: Date,
        lastSpeechAt: Date?
    ) -> Decision {
        // Any new confirmed speech since the prompt was raised means the meeting
        // is still live — dismiss, whichever reason raised it. Comparing the
        // whole timestamp (not onset-vs-raise) catches a chunk that finalizes
        // during the countdown even though its speech started just before the
        // prompt, so a continuous talker can't be auto-ended mid-sentence. That
        // looseness also lets a chunk from *during* the call cancel a
        // `.callEnded` countdown, which is the trade taken deliberately: it costs
        // a recording that runs to the silence watchdog instead, where an
        // onset-vs-raise comparison would cost a meeting cut off mid-sentence.
        if lastSpeechAt != speechAtPromptRaise {
            clearPrompt()
            return .dismiss
        }
        // Wall-clock deadline, not a tick count, so main-thread jitter can't
        // stretch "2:00" past two real minutes.
        let remaining = (promptDeadline ?? now).timeIntervalSince(now)
        guard remaining > 0 else {
            clearPrompt()
            return .end
        }
        let seconds = Int(remaining.rounded(.up))
        return prompt.secondsRemaining == seconds ? .idle : .countdown(seconds)
    }

    /// The call this recording was following has ended, per `MeetingDetector`.
    ///
    /// Raises the same countdown the silence watchdog uses rather than ending
    /// outright, and the countdown dies the moment anyone speaks: a call whose
    /// process is gone is still only evidence that the *call* ended, not that
    /// the conversation did. Thirty seconds with a keep button is the difference
    /// between "Nod wrapped up after the call" and "Nod cut me off".
    ///
    /// Returns nil when the user already declined one for this recording.
    mutating func callEnded(app: String, now: Date, lastSpeechAt: Date?) -> AutoEndPrompt? {
        guard !callEndDeclined else { return nil }
        promptDeadline = now.addingTimeInterval(TimeInterval(Self.callEndedCountdownSeconds))
        speechAtPromptRaise = lastSpeechAt
        return AutoEndPrompt(
            secondsRemaining: Self.callEndedCountdownSeconds,
            reason: .callEnded(app: app)
        )
    }

    /// The user dismissed the prompt. Backs off the silence threshold (doubling,
    /// capped) so we don't nag on the next quiet stretch, and returns the new
    /// factor for the log.
    @discardableResult
    mutating func kept(reason: AutoEndPrompt.Reason?, now: Date) -> Double {
        if case .callEnded = reason {
            // They've told us the conversation outlived the call; rejoining and
            // leaving again must not raise this a second time for this recording.
            callEndDeclined = true
        }
        clearPrompt()
        inactivityResetAt = now
        silenceBackoff = min(silenceBackoff * 2, Self.maxSilenceBackoff)
        return silenceBackoff
    }

    /// Tail kept after the last detected speech when trimming trailing silence —
    /// covers Whisper latency plus the final in-flight VAD segment.
    private static let trailingSilenceTailSeconds: TimeInterval = 30

    /// End time clamped so a forgot-to-stop tail of dead air can't inflate the
    /// meeting's duration: `lastSpeech + tail`, bounded to `[startedAt, now]`.
    /// Falls back to `now` when there was no speech; a normal stop right after
    /// talking also lands on `now` because `lastSpeech + tail` exceeds it.
    static func trimmedEndDate(startedAt: Date, lastSpeechAt: Date?, now: Date = Date()) -> Date {
        guard let lastSpeechAt else { return now }
        return max(startedAt, min(now, lastSpeechAt.addingTimeInterval(trailingSilenceTailSeconds)))
    }
}
