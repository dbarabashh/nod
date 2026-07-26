import AppKit

/// The app's sound effects, and the rule they obey.
///
/// **Nod stays silent while it records**, with one named exception below.
/// System-audio capture already excludes our own process
/// (`excludesCurrentProcessAudio`), but the *microphone* does not: on speakers,
/// anything Nod plays is heard by everyone on the call and comes back in
/// through our own mic as something for Whisper to make sense of.
///
/// The rule lives here rather than at each call site, and `play(recording:)`
/// makes stating the recording state a condition of playing anything at all —
/// a new caller cannot quietly forget it, because it will not compile.
@MainActor
enum UISound: String {
    /// A call started and the card is asking whether to record it. Quiet and
    /// short by design: it fires while people are greeting each other, and a
    /// chime out of the speakers at that moment is everyone's business.
    case meetingDetected = "meeting-detected"
    /// The recap is written. The one cue allowed to be pleasant — the
    /// recording is over and the user has usually walked away from it.
    case summaryReady = "summary-ready"
    /// Nod is about to end a recording on its own and the user has seconds to
    /// stop it.
    case actionRequired = "action-required"

    static let defaultsKey = "app.sounds.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The exception to the silence rule, and the reason for it.
    ///
    /// `actionRequired` exists *because* nobody is watching the screen: the
    /// countdown it announces ends the recording by itself. Suppressing it
    /// during a recording would suppress it exactly when it is needed, and the
    /// alternative failure — a meeting that ends without the user, or one that
    /// runs on into an empty room — is worse than a quiet cue in the mic
    /// stream, which lands in a stretch that has been silent for minutes and
    /// is trimmed off the end of the recording anyway.
    var interruptsRecording: Bool {
        self == .actionRequired
    }

    func play(recording isRecording: Bool) {
        guard !isRecording || interruptsRecording, Self.isEnabled, let sound = loaded() else { return }
        // Restart rather than overlap: two copies of one short cue read as a
        // glitch, and a busy hour can raise a second card.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Cached: `NSSound` re-reads and re-decodes the file on every
    /// construction, and a cue built at the moment it is needed arrives late.
    private func loaded() -> NSSound? {
        if let cached = Self.cache[self] { return cached }
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false)
        else {
            Log.ui.error("sound \(rawValue) missing from the bundle")
            return nil
        }
        Self.cache[self] = sound
        return sound
    }

    private static var cache: [UISound: NSSound] = [:]
}
