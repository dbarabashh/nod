import Foundation

// Minimal Swift wrapper over sherpa-onnx's C VAD API (Silero v5), extracted
// from the upstream `SherpaOnnx.swift` example — only the voice-activity-
// detection surface we use. The C symbols come from the vendored
// `sherpa-onnx.xcframework` via the bridging header. sherpa-onnx ships a
// universal (arm64 + x86_64) static lib with onnxruntime bundled, so this
// keeps the app universal — unlike the previous arm64-only VAD library.

func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
    let cs = (s as NSString).utf8String
    return UnsafePointer<Int8>(cs)
}

func sherpaOnnxSileroVadModelConfig(
    model: String = "",
    threshold: Float = 0.5,
    minSilenceDuration: Float = 0.25,
    minSpeechDuration: Float = 0.5,
    windowSize: Int = 512,
    maxSpeechDuration: Float = 5.0
) -> SherpaOnnxSileroVadModelConfig {
    SherpaOnnxSileroVadModelConfig(
        model: toCPointer(model),
        threshold: threshold,
        min_silence_duration: minSilenceDuration,
        min_speech_duration: minSpeechDuration,
        window_size: Int32(windowSize),
        max_speech_duration: maxSpeechDuration
    )
}

func sherpaOnnxTenVadModelConfig(
    model: String = "",
    threshold: Float = 0.5,
    minSilenceDuration: Float = 0.25,
    minSpeechDuration: Float = 0.5,
    windowSize: Int = 256,
    maxSpeechDuration: Float = 5.0
) -> SherpaOnnxTenVadModelConfig {
    SherpaOnnxTenVadModelConfig(
        model: toCPointer(model),
        threshold: threshold,
        min_silence_duration: minSilenceDuration,
        min_speech_duration: minSpeechDuration,
        window_size: Int32(windowSize),
        max_speech_duration: maxSpeechDuration
    )
}

func sherpaOnnxVadModelConfig(
    sileroVad: SherpaOnnxSileroVadModelConfig = sherpaOnnxSileroVadModelConfig(),
    sampleRate: Int32 = 16000,
    numThreads: Int = 1,
    provider: String = "cpu",
    debug: Int = 0,
    tenVad: SherpaOnnxTenVadModelConfig = sherpaOnnxTenVadModelConfig()
) -> SherpaOnnxVadModelConfig {
    SherpaOnnxVadModelConfig(
        silero_vad: sileroVad,
        sample_rate: sampleRate,
        num_threads: Int32(numThreads),
        provider: toCPointer(provider),
        debug: Int32(debug),
        ten_vad: tenVad
    )
}

/// One completed speech segment from the VAD. `samples` is 16 kHz mono Float32.
final class SherpaOnnxSpeechSegmentWrapper {
    private let p: UnsafePointer<SherpaOnnxSpeechSegment>

    init(p: UnsafePointer<SherpaOnnxSpeechSegment>) {
        self.p = p
    }

    deinit {
        SherpaOnnxDestroySpeechSegment(p)
    }

    var n: Int {
        Int(p.pointee.n)
    }

    var start: Int {
        Int(p.pointee.start)
    }

    lazy var samples: [Float] = Array(UnsafeBufferPointer(start: p.pointee.samples, count: n))
}

/// Streaming voice-activity detector. Feed audio via `acceptWaveform`, then
/// drain completed segments with `isEmpty`/`front`/`pop`. Segmentation
/// (pause-cut + max-length cap) is configured in `SherpaOnnxVadModelConfig`.
final class SherpaOnnxVoiceActivityDetectorWrapper {
    private let vad: OpaquePointer

    init?(config: UnsafePointer<SherpaOnnxVadModelConfig>, bufferSizeInSeconds: Float) {
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(config, bufferSizeInSeconds) else {
            return nil
        }
        self.vad = vad
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
    }

    /// Pointer + count so the caller can pass an audio buffer's channel data
    /// directly, without copying it into a Swift `[Float]` on every buffer.
    func acceptWaveform(_ samples: UnsafePointer<Float>, count: Int) {
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, Int32(count))
    }

    func isEmpty() -> Bool {
        SherpaOnnxVoiceActivityDetectorEmpty(vad) == 1
    }

    func isSpeechDetected() -> Bool {
        SherpaOnnxVoiceActivityDetectorDetected(vad) == 1
    }

    func pop() {
        SherpaOnnxVoiceActivityDetectorPop(vad)
    }

    func clear() {
        SherpaOnnxVoiceActivityDetectorClear(vad)
    }

    func front() -> SherpaOnnxSpeechSegmentWrapper? {
        guard let p = SherpaOnnxVoiceActivityDetectorFront(vad) else { return nil }
        return SherpaOnnxSpeechSegmentWrapper(p: p)
    }

    func reset() {
        SherpaOnnxVoiceActivityDetectorReset(vad)
    }

    /// Force the in-progress segment to be emitted (end-of-meeting tail).
    func flush() {
        SherpaOnnxVoiceActivityDetectorFlush(vad)
    }
}
