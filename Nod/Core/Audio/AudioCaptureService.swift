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
    private var lastSystemFrameAt: Date?
    private var systemWatchdogTask: Task<Void, Never>?
    private var systemRestartInFlight = false
    private static let systemWatchdogIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let systemAudioStallSeconds: TimeInterval = 8
    /// Set from the mic tap on every hardware buffer (independent of mute — a
    /// muted mic still delivers frames). Drives the mic watchdog so a device
    /// that stops delivering (unplugged headset, HAL stall) is caught and the
    /// engine restarted, instead of the meeting going silently deaf.
    private var lastMicFrameAt: Date?
    private var micWatchdogTask: Task<Void, Never>?
    private var micRestartInFlight = false
    private static let micStallSeconds: TimeInterval = 8
    /// Core Audio listener for input-device topology changes (a device
    /// appearing/disappearing, or the system default switching). Lets us react
    /// to the active input vanishing mid-meeting faster than the watchdog's
    /// stall timeout, and to follow the system default when "System Default" is
    /// selected.
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerActive = false

    override init() {
        preferredInputUID = UserDefaults.standard.string(forKey: Self.preferredInputKey)
        super.init()
        outputHandler.onSampleCount = { [weak self] count in
            Task { @MainActor [weak self] in
                guard let self else { return }
                systemSamples += count
                lastSystemFrameAt = Date()
            }
        }
        outputHandler.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                lastError = message
                Log.audio.error("\(message)")
            }
        }
        // Forward every PCM buffer SCStream produces out to onSystemBuffer.
        // Without this, the [Them] recognizer never sees a single sample and
        // SFSpeech finalizes on silence every ~430ms (transient 1110 storm).
        outputHandler.onPCMBuffer = { [weak self] buffer in
            self?.onSystemBuffer?(buffer)
        }
        registerInputDeviceListener()
    }

    deinit {
        guard let block = deviceListenerBlock else { return }
        for selector in Self.monitoredDeviceSelectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
            )
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
        if captureMic {
            lastMicFrameAt = Date()
            await startMicrophone()
            startMicWatchdog()
        }
        if captureSystem {
            lastSystemFrameAt = Date()
            await startSystemAudio()
            startSystemWatchdog()
        }
    }

    func pause() {
        guard state == .capturing else { return }
        audioEngine?.pause()
        stopMicWatchdog()
        stopSystemWatchdog()
        let stream = scStream
        scStream = nil
        Task { try? await stream?.stopCapture() }
        inputLevel = 0
        state = .paused
    }

    func resume() async {
        guard state == .paused else { return }
        if captureMic {
            // Rebuild rather than just re-`start()` the paused engine: a device
            // may have been unplugged or the default changed while paused, and
            // only a fresh `startMicrophone` re-runs `applyInputDeviceSelection`.
            stopMicrophone()
            lastMicFrameAt = Date()
            await startMicrophone()
            startMicWatchdog()
        }
        if captureSystem {
            lastSystemFrameAt = Date()
            await startSystemAudio()
            startSystemWatchdog()
        }
        state = .capturing
    }

    func stop() async {
        guard state != .idle else { return }
        stopMicWatchdog()
        stopSystemWatchdog()
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

        // Bind the requested input device before the engine settles. The naive
        // "set CurrentDevice and hope" path silently no-ops (capture falls back
        // to the system default) whenever the AUHAL is already initialized — see
        // applyInputDeviceSelection.
        applyInputDeviceSelection(to: input)

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
                // Liveness for the watchdog — set before the mute branch so a
                // muted-but-delivering mic isn't mistaken for a stalled one.
                lastMicFrameAt = Date()
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

    /// Applies `preferredInputUID` to the engine's input node, verifying the
    /// device actually bound and surfacing an explicit `lastError` when the
    /// chosen mic can't be honored — instead of silently recording from whatever
    /// the system default happens to be (the old behavior, which made a user who
    /// once picked a Bluetooth headset unable to switch back to any other input).
    /// Must run before `engine.prepare()` so the change is picked up on init.
    private func applyInputDeviceSelection(to input: AVAudioInputNode) {
        guard let uid = preferredInputUID else {
            let defaultName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "<unknown>"
            Log.audio.info("using system default input device: \(defaultName)")
            return
        }

        guard let deviceID = AudioDeviceCatalog.deviceID(forUID: uid) else {
            Log.audio.error("preferred input UID=\(uid) not connected; using system default")
            lastError = "Selected microphone isn't available — using the system default."
            return
        }

        guard let unit = input.audioUnit else {
            Log.audio.error("input node exposes no audio unit; cannot select UID=\(uid)")
            lastError = "Couldn't select the microphone — using the system default."
            return
        }

        let status = setInputDevice(deviceID, on: unit)
        let actual = currentInputDevice(of: unit)
        guard status == noErr, actual == deviceID else {
            let actualName = actual.flatMap(AudioDeviceCatalog.name(forDeviceID:)) ?? "the default microphone"
            Log.audio.error(
                "input override to UID=\(uid) (id=\(deviceID)) failed: OSStatus=\(status), unit reports id=\(actual.map(String.init) ?? "?") (\(actualName))"
            )
            lastError = "Couldn't switch to the selected microphone — still using \(actualName)."
            return
        }

        Log.audio.info("input device overridden to UID=\(uid) (id=\(deviceID))")
    }

    /// Rebinds the AUHAL to `deviceID`. Uninitializes first because
    /// `kAudioOutputUnitProperty_CurrentDevice` returns `kAudioUnitErr_Initialized`
    /// on an already-initialized unit; `engine.prepare()` re-initializes after.
    private func setInputDevice(_ deviceID: AudioDeviceID, on unit: AudioUnit) -> OSStatus {
        AudioUnitUninitialize(unit)
        var id = deviceID
        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// The device the AUHAL is actually bound to — a `noErr` set doesn't
    /// guarantee the HAL honored it, so callers verify against what they asked for.
    private func currentInputDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            &size
        )
        return status == noErr ? id : nil
    }

    // MARK: - Microphone recovery (watchdog + device listener)

    private func startMicWatchdog() {
        micWatchdogTask?.cancel()
        micWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.systemWatchdogIntervalNanoseconds)
                await self?.restartMicrophoneIfStalled()
            }
        }
    }

    private func stopMicWatchdog() {
        micWatchdogTask?.cancel()
        micWatchdogTask = nil
    }

    private func restartMicrophoneIfStalled() async {
        // No `audioEngine != nil` guard: a start that threw leaves the engine nil
        // while state stays `.capturing`, and that's exactly the case the
        // watchdog must retry rather than treat as healthy.
        guard state == .capturing, captureMic, !micRestartInFlight else { return }
        let elapsed = Date().timeIntervalSince(lastMicFrameAt ?? .distantPast)
        guard elapsed >= Self.micStallSeconds else { return }
        await restartMicrophone(reason: "no mic buffers for \(String(format: "%.1f", elapsed))s")
    }

    /// Tears down and rebuilds the mic engine, which re-runs
    /// `applyInputDeviceSelection` — so a vanished preferred device recovers to
    /// the system default (surfacing `lastError`), and a changed default is
    /// picked up. Guarded by `micRestartInFlight` so the watchdog and the device
    /// listener can't restart concurrently.
    private func restartMicrophone(reason: String) async {
        guard state == .capturing, captureMic, !micRestartInFlight else { return }
        micRestartInFlight = true
        Log.audio.error("restarting microphone — \(reason)")
        stopMicrophone()
        guard state == .capturing, captureMic else {
            micRestartInFlight = false
            return
        }
        lastMicFrameAt = Date()
        await startMicrophone()
        micRestartInFlight = false
    }

    /// Selectors that can move capture off the device it is bound to: the
    /// device set (plug / unplug) and which one is the system default.
    private static let monitoredDeviceSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice
    ]

    private func registerInputDeviceListener() {
        guard !deviceListenerActive else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                await self?.handleInputDeviceChange()
            }
        }
        for selector in Self.monitoredDeviceSelectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
            )
            if status != noErr {
                Log.audio.error("failed to register device listener (selector=\(selector), OSStatus=\(status))")
            }
        }
        deviceListenerBlock = block
        deviceListenerActive = true
    }

    /// Compares the device the engine is bound to against the one it *should* be
    /// on and restarts only when they diverge — so unrelated device toggles don't
    /// churn a running capture. The target is the preferred device when present,
    /// otherwise the system default (which is also the fallback when a preferred
    /// device is unplugged); if neither can be resolved we leave capture alone
    /// rather than restart toward an unknown device.
    private func handleInputDeviceChange() async {
        guard state == .capturing, captureMic, !micRestartInFlight else { return }
        guard let unit = audioEngine?.inputNode.audioUnit else {
            await restartMicrophone(reason: "input device changed while engine down")
            return
        }
        let preferred = preferredInputUID.flatMap(AudioDeviceCatalog.deviceID(forUID:))
        guard let intended = preferred ?? AudioDeviceCatalog.currentDefaultInputDeviceID() else { return }
        if intended != currentInputDevice(of: unit) {
            await restartMicrophone(reason: "active input device changed")
        }
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
            lastSystemFrameAt = Date()
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

    private func startSystemWatchdog() {
        systemWatchdogTask?.cancel()
        systemWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.systemWatchdogIntervalNanoseconds)
                await self?.restartSystemAudioIfStalled()
            }
        }
    }

    private func stopSystemWatchdog() {
        systemWatchdogTask?.cancel()
        systemWatchdogTask = nil
    }

    private func restartSystemAudioIfStalled() async {
        guard state == .capturing, captureSystem, scStream != nil, !systemRestartInFlight else { return }
        let elapsed = Date().timeIntervalSince(lastSystemFrameAt ?? .distantPast)
        guard elapsed >= Self.systemAudioStallSeconds else { return }

        systemRestartInFlight = true
        Log.audio.error("system audio stalled — no buffers for \(String(format: "%.1f", elapsed))s; restarting SCStream")
        lastError = "System audio capture stalled; restarting…"

        let stream = scStream
        scStream = nil
        try? await stream?.stopCapture()

        guard state == .capturing, captureSystem else {
            systemRestartInFlight = false
            return
        }
        lastSystemFrameAt = Date()
        await startSystemAudio()
        if scStream != nil {
            lastError = nil
            Log.audio.info("system audio restarted after stall")
        }
        systemRestartInFlight = false
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
