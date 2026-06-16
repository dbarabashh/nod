import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

enum CaptureState: Equatable {
    case idle
    case capturing
    case paused
}

@MainActor
final class AudioCaptureService: NSObject, ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var micEnabled: Bool = true
    @Published private(set) var micSamples: Int = 0
    @Published private(set) var systemSamples: Int = 0
    /// Smoothed mic peak (0…1) for the panel's recording level meter. Updated
    /// from the audio tap (~10×/sec); zeroed on pause/stop/mute so the meter
    /// can't show stale activity once capture isn't flowing.
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var lastError: String?
    @Published var preferredInputUID: String? {
        didSet {
            if let preferredInputUID {
                UserDefaults.standard.set(preferredInputUID, forKey: Self.preferredInputKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredInputKey)
            }
        }
    }

    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?

    private static let preferredInputKey = "audio.input.deviceUID"
    /// Lock-protected mirror of `micEnabled` for the audio-tap thread — the
    /// `@MainActor` property can't be read off-actor without a data race.
    /// Same one-frame tolerance on toggle as before; only the unsynchronized
    /// access is gone.
    private let micGate = OSAllocatedUnfairLock(initialState: true)
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    /// Which streams the active session uses — set on `start`, reused by
    /// `resume` so a paused-then-resumed voice note doesn't silently start
    /// pulling system audio (or vice-versa).
    private var captureMic = true
    private var captureSystem = true
    private let outputHandler = SystemAudioOutputHandler()
    private let outputQueue = DispatchQueue(label: "nod.system-audio", qos: .userInteractive)

    override init() {
        preferredInputUID = UserDefaults.standard.string(forKey: Self.preferredInputKey)
        super.init()
        outputHandler.onSampleCount = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.systemSamples += count
            }
        }
        outputHandler.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lastError = message
            }
        }
        // Forward every PCM buffer SCStream produces out to onSystemBuffer.
        // Without this, the [Them] recognizer never sees a single sample and
        // SFSpeech finalizes on silence every ~430ms (transient 1110 storm).
        outputHandler.onPCMBuffer = { [weak self] buffer in
            self?.onSystemBuffer?(buffer)
        }
    }

    func start(captureMic: Bool = true, captureSystem: Bool = true) async {
        guard state == .idle else { return }
        lastError = nil
        micSamples = 0
        systemSamples = 0
        self.captureMic = captureMic
        self.captureSystem = captureSystem
        state = .capturing

        Log.audio.info("starting capture (mic=\(captureMic) system=\(captureSystem))")
        if captureMic { await startMicrophone() }
        if captureSystem { await startSystemAudio() }
    }

    func pause() {
        guard state == .capturing else { return }
        audioEngine?.pause()
        Task { try? await scStream?.stopCapture() }
        inputLevel = 0
        state = .paused
    }

    func resume() async {
        guard state == .paused else { return }
        if captureMic {
            do {
                try audioEngine?.start()
            } catch {
                lastError = "Resume mic failed: \(error.localizedDescription)"
            }
        }
        if captureSystem { await startSystemAudio() }
        state = .capturing
    }

    func stop() async {
        guard state != .idle else { return }
        stopMicrophone()
        await stopSystemAudio()
        inputLevel = 0
        state = .idle
    }

    func setMicMuted(_ muted: Bool) {
        micEnabled = !muted
        micGate.withLock { $0 = !muted }
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophone() async {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Override the input device BEFORE reading the format or starting the engine.
        // Otherwise AVAudioEngine binds to whatever system default was at engine init.
        if let uid = preferredInputUID, let deviceID = AudioDeviceCatalog.deviceID(forUID: uid) {
            if let unit = input.audioUnit {
                var id = deviceID
                let status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status == noErr {
                    Log.audio.info("input device overridden to UID=\(uid) (id=\(deviceID))")
                } else {
                    Log.audio.error("failed to override input device (OSStatus=\(status))")
                }
            }
        } else {
            let defaultName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "<unknown>"
            Log.audio.info("using system default input device: \(defaultName)")
        }

        // Settle the engine after any device-change side effects above so the
        // input node's reported format matches reality.
        engine.prepare()

        let advertisedFormat = input.outputFormat(forBus: 0)
        Log.audio.info("input node advertised: sampleRate=\(advertisedFormat.sampleRate) ch=\(advertisedFormat.channelCount)")

        var tapCallCounter = 0
        // Pass `format: nil` so the tap uses whatever the bus actually delivers.
        // Passing an explicit format that disagrees with the hardware (which can
        // happen right after AudioUnitSetProperty changes the device) causes the
        // tap to silently never fire its callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let count = Int(buffer.frameLength)

            // Compute peak amplitude for diagnostics — confirms mic is hearing sound.
            var peak: Float = 0
            if let channelData = buffer.floatChannelData?[0] {
                for i in 0 ..< count {
                    let s = abs(channelData[i])
                    if s > peak { peak = s }
                }
            }
            tapCallCounter += 1
            if tapCallCounter == 1 {
                let f = buffer.format
                Log.audio.info("first mic buffer — actual format: sampleRate=\(f.sampleRate) ch=\(f.channelCount) frames=\(count)")
            }
            if tapCallCounter % 50 == 0 {
                Log.audio.info("mic tap #\(tapCallCounter) — frames=\(count) peak=\(String(format: "%.4f", peak))")
            }

            // Mute gates the buffer at the source — previously `micEnabled`
            // only gated the UI level meter, so a muted mic still
            // forwarded frames into Whisper and showed up as ME entries.
            // `micGate` mirrors the @MainActor flag behind a lock: no
            // MainActor hop (which would defer the gate past this buffer)
            // and no unsynchronized cross-thread read.
            let enabledNow = micGate.withLock { $0 }
            if enabledNow {
                // Forward synchronously while the buffer is still valid.
                onMicBuffer?(buffer)
            } else if tapCallCounter % 50 == 0 {
                // Periodic confirmation the mute gate is active (sampled
                // 1-in-50 because every-buffer logging would flood at
                // ~10/sec). Pairs with the existing "mic tap #N" line so
                // a log scrub shows BOTH that hardware is still
                // delivering frames AND that we're correctly dropping
                // them at the gate.
                Log.audio.info("mic muted — buffer dropped at gate (peak=\(String(format: "%.4f", peak)))")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if micEnabled {
                    micSamples += count
                    // Decaying peak hold — rises instantly to a loud frame,
                    // eases back down so the meter doesn't strobe between buffers.
                    inputLevel = max(peak, inputLevel * 0.8)
                } else {
                    inputLevel = 0
                }
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            Log.audio.info("microphone engine.start() OK")
        } catch {
            lastError = "Microphone capture failed: \(error.localizedDescription)"
            Log.audio.error("microphone failed: \(error.localizedDescription)")
        }
    }

    private func stopMicrophone() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                lastError = "No display available for system audio capture"
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // SCStream requires a video output configuration even when only audio is consumed.
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: outputHandler)
            try stream.addStreamOutput(outputHandler, type: .audio, sampleHandlerQueue: outputQueue)
            // SCStream always captures video too. Subscribe to drain its queue
            // (the handler ignores `.screen` frames). Without this, frames pile up
            // and the system logs "stream output NOT found. Dropping frame".
            try stream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            scStream = stream
            Log.audio.info("system audio started (SCStream)")
        } catch {
            lastError = "System audio capture failed: \(error.localizedDescription)"
            Log.audio.error("system audio failed: \(error.localizedDescription)")
        }
    }

    private func stopSystemAudio() async {
        if let stream = scStream {
            try? await stream.stopCapture()
        }
        scStream = nil
    }
}

private final class SystemAudioOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSampleCount: ((Int) -> Void)?
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var deliveryCounter = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        onSampleCount?(count)

        guard let pcm = SampleBufferConverter.makePCMBuffer(from: sampleBuffer),
              let mono = SampleBufferConverter.downmixToMono(pcm) else { return }

        // Peak diagnostic — match the mic tap log so we can compare signal levels.
        deliveryCounter += 1
        if deliveryCounter % 50 == 0 {
            var peak: Float = 0
            if let channel = mono.floatChannelData?[0] {
                for i in 0 ..< Int(mono.frameLength) {
                    let s = abs(channel[i])
                    if s > peak { peak = s }
                }
            }
            Log.audio.info("sys tap #\(deliveryCounter) — frames=\(mono.frameLength) peak=\(String(format: "%.4f", peak))")
        }

        onPCMBuffer?(mono)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("System audio stream stopped: \(error.localizedDescription)")
    }
}
