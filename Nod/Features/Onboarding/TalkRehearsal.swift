import AppKit
import SwiftUI

/// The held key, tried once before the notch exists to answer it. The window
/// owns this for the length of the step: the key goes down, the microphone
/// opens; the key comes up, the clip is transcribed, and Nod says hello back
/// by name, aloud, at once. The hello is written, not generated, and its
/// audio is fetched while the person is still reading the screen, so the
/// only wait after they let go is hearing what they said. Typing does the
/// same without the microphone, for a quiet office or a denied mic.
@MainActor
final class TalkRehearsal: ObservableObject {
    /// What Nod heard, in the person's words, and what it said back.
    struct Answer: Equatable {
        let heard: String
        let reply: String
    }

    enum Phase: Equatable {
        case waiting
        case listening
        case transcribing
        case answered(Answer)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .waiting
    /// Nod is mid-sentence. The step waits for it: moving on while the
    /// voice is still talking would leave the words behind on a screen
    /// that is gone.
    @Published private(set) var isSpeaking = false
    /// Only the talk step listens. The hotkey is global and the window has
    /// other steps; a hold on the welcome step must not open a microphone.
    private(set) var isArmed = false

    let combo: HotkeyManager.Combo
    private let recorder: HeldQuestionRecorder
    private let permissions: PermissionManager
    private let llmClient: LLMProxyClient
    private let voice: SpokenAnswer
    private let telemetry: OnboardingTelemetry
    private let language: LanguagePreference
    /// Settled when the step arms, so the line fetched ahead is the line said.
    private var hello = ""
    private var holdLimit: Task<Void, Never>?
    private var heldSince: Date?
    /// Bumped by `disarm`, so a transcription or hello still in flight when
    /// the step is left lands nowhere — nothing is said over the next card.
    private var generation = 0

    /// A tap is not a hold. Whisper turns a fraction of a second of room
    /// noise into a word in some language — "はい。" was one — so anything
    /// shorter than this never leaves the Mac.
    private static let minimumHold: TimeInterval = 0.8
    /// Below this peak the clip is the room, not a voice, and the same
    /// applies: a silent clip comes back as an invented word.
    private static let quietPeak: Float = 0.02

    init(
        combo: HotkeyManager.Combo,
        audioCapture: AudioCaptureService,
        permissions: PermissionManager,
        llmClient: LLMProxyClient,
        telemetry: OnboardingTelemetry,
        language: LanguagePreference
    ) {
        self.combo = combo
        recorder = HeldQuestionRecorder(audioCapture: audioCapture)
        self.permissions = permissions
        self.llmClient = llmClient
        voice = SpokenAnswer(llmClient: llmClient)
        self.telemetry = telemetry
        self.language = language
        voice.onSpeaking = { [weak self] words in
            Task { @MainActor [weak self] in self?.isSpeaking = words != nil }
        }
    }

    /// The step is on screen: the key is listened for, and the hello — by
    /// `firstName` when there is one — is fetched before it is needed.
    func arm(firstName: String?) {
        isArmed = true
        let key = combo.displayString
        hello = if let firstName {
            "Hi \(firstName), nice to meet you. Hold \(key) whenever you need me, from any app."
        } else {
            "Hi, nice to meet you. Hold \(key) whenever you need me, from any app."
        }
        voice.prepare(hello, asking: "hello", language: language.current)
    }

    func beginHold() {
        guard isArmed, !isBusy else { return }
        voice.stop()
        permissions.refresh()
        switch permissions.microphone {
        case .authorized:
            break
        case .denied:
            phase = .failed("Mic is off in System Settings")
            return
        case .notDetermined:
            phase = .failed("Allow the microphone, then hold again")
            let generation = generation
            telemetry.permissionRequested(.microphone)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await permissions.requestMicrophone()
                telemetry.permissionResolved(.microphone, granted: granted)
                // The person may have typed meanwhile; the dialog's answer
                // must not paint over a hello that already landed.
                guard generation == self.generation, case .failed = phase else { return }
                phase = .failed(granted ? "Mic allowed — hold again" : "Mic is off in System Settings")
            }
            return
        }
        do {
            try recorder.start()
        } catch {
            Log.audio.error("talk step: could not open the microphone — \(error)")
            phase = .failed("Couldn't open the mic")
            return
        }
        phase = .listening
        heldSince = Date()
        Self.haptic(.levelChange)
        holdLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HeldQuestionRecorder.maxSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endHold()
        }
    }

    func endHold() {
        guard phase == .listening else { return }
        holdLimit?.cancel()
        holdLimit = nil
        let held = heldSince.map { Date().timeIntervalSince($0) } ?? 0
        heldSince = nil
        phase = .transcribing
        Self.haptic(.generic)
        let generation = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wav = await recorder.stop()
            guard generation == self.generation else { return }
            guard let wav, held >= Self.minimumHold else {
                phase = .failed("Keep the keys held while you speak, then let go")
                return
            }
            guard Self.peak(of: wav) >= Self.quietPeak else {
                phase = .failed("I didn't hear anything — say something while you hold")
                return
            }
            do {
                let heard = try await llmClient.dictate(audio: wav)
                guard generation == self.generation else { return }
                let words = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else {
                    phase = .failed("Didn't catch that")
                    return
                }
                Self.haptic(.alignment)
                answer(words, spoken: true)
            } catch {
                guard generation == self.generation else { return }
                Log.llm.error("talk step: transcription failed — \(error.localizedDescription)")
                phase = .failed("Couldn't hear that")
            }
        }
    }

    /// The typed way in: the same read-back, without the microphone or the
    /// voice — a person who typed rather than spoke did so for a reason.
    func submit(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isArmed, !isBusy, !words.isEmpty else { return }
        voice.stop()
        answer(words, spoken: false)
    }

    private var isBusy: Bool {
        switch phase {
        case .listening, .transcribing: true
        case .waiting, .answered, .failed: false
        }
    }

    private func answer(_ words: String, spoken: Bool) {
        phase = .answered(Answer(heard: words, reply: hello))
        if spoken {
            voice.say(hello, asking: "hello", language: language.current)
        }
    }

    func disarm() {
        isArmed = false
        generation += 1
        holdLimit?.cancel()
        holdLimit = nil
        heldSince = nil
        voice.stop()
        if phase == .listening {
            Task { _ = await recorder.stop() }
            phase = .waiting
        }
    }

    /// A Force Touch trackpad taps back; anything else ignores this.
    private static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// The loudest sample of a 16-bit mono WAV, as a fraction of full scale.
    private static func peak(of wav: Data) -> Float {
        let header = 44
        guard wav.count > header + 1 else { return 0 }
        var loudest: Int16 = 0
        wav.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let first = header / MemoryLayout<Int16>.size
            for index in first ..< samples.count {
                let sample = samples[index].magnitude
                if sample > loudest.magnitude { loudest = Int16(clamping: sample) }
            }
        }
        return Float(loudest) / Float(Int16.max)
    }
}
