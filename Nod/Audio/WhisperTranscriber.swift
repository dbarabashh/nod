import AVFoundation
import Foundation

/// Streams audio buffers through Silero VAD (sherpa-onnx), which runs entirely
/// on-device: it detects whole speech segments — start at speech onset, end
/// after a natural pause — and hands back 16 kHz mono PCM per utterance. Each
/// segment is POSTed to Whisper via OpenRouter and emitted as one
/// TranscriptEntry.
///
/// Cutting on real speech boundaries (not a fixed timer) is the whole point:
/// the previous timer cut sliced words across chunks, and each garbled boundary
/// propagated into the recap, entities, and search index. sherpa's VAD config
/// owns segmentation — `minSilenceDuration` is the pause that closes a segment,
/// `maxSpeechDuration` caps an unbroken monologue so the live transcript keeps
/// flowing and chunks stay within Whisper's window.
final class WhisperTranscriber: @unchecked Sendable {
    let source: TranscriptSource
    var onFinal: ((String, TranscriptSource) -> Void)?
    var onFailure: ((String, TranscriptSource) -> Void)?
    /// Called per-segment to determine which language code to send to Whisper.
    /// Default is English; TranscriptStore overrides this to read from the
    /// LanguagePreference so the user's toggle takes effect on the next segment.
    var languageProvider: () -> String = { "en" }

    private let client: OpenRouterClient
    private let queue: DispatchQueue
    private var keepRecognizing = false

    private let vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var chunkCounter: Int = 0

    // In-flight transcription Tasks; flushPending awaits these so a Suggest-reply
    // sees all completed segments, in order, before it reads the context.
    private var inFlightFlushes: [UUID: Task<Void, Never>] = [:]

    /// Tail of the most recent transcription, fed back to Whisper as the
    /// `prompt` for the next chunk — bridges a word split at a `maxSpeechDuration`
    /// cut and keeps terminology consistent across chunks.
    private var promptTail: String = ""
    private static let promptTailMaxChars = 200

    // Silero segmentation tuning (see sherpaOnnxSileroVadModelConfig):
    /// Cut a segment only after this much trailing silence. Set high enough to
    /// bridge mid-phrase pauses so a chunk is a whole utterance — too short and
    /// the meeting fragments into many one-word chunks, which cost extra Whisper
    /// calls and make Whisper hallucinate speaker-name prefixes on the tiny
    /// clips ("Emily King, PhD.: …").
    private static let minSilenceDuration: Float = 1.0
    /// Drop sub-this speech blips ("um", "so") so they never reach Whisper.
    private static let minSpeechDuration: Float = 0.4
    /// Cap an unbroken segment so a non-stop talker / media playback still
    /// streams and chunks stay inside Whisper's ~30s window.
    private static let maxSpeechDuration: Float = 15.0

    // Canonical Whisper/VAD input format: mono 16 kHz Float32. We normalize any
    // device sample rate (incl. 44.1 kHz) to this before the audio reaches the VAD.
    private static let speechFormat: AVAudioFormat = .init(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?

    init(source: TranscriptSource, client: OpenRouterClient) {
        self.source = source
        self.client = client
        queue = DispatchQueue(label: "nod.whisper.\(source.rawValue)", qos: .userInteractive)
        vad = WhisperTranscriber.makeVAD()
        if vad == nil {
            Log.stt.error("[\(source.label)] Silero VAD unavailable — model missing or failed to load")
        }
    }

    private static func makeVAD() -> SherpaOnnxVoiceActivityDetectorWrapper? {
        guard let modelPath = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx")?.path else {
            return nil
        }
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: modelPath,
                threshold: 0.5,
                minSilenceDuration: minSilenceDuration,
                minSpeechDuration: minSpeechDuration,
                windowSize: 512,
                maxSpeechDuration: maxSpeechDuration
            ),
            sampleRate: 16_000
        )
        return withUnsafePointer(to: &config) {
            SherpaOnnxVoiceActivityDetectorWrapper(config: $0, bufferSizeInSeconds: 30)
        }
    }

    func start() async {
        Log.stt.info("[\(source.label)] Whisper start() — Silero VAD (sherpa)")
        queue.async {
            self.keepRecognizing = true
            self.promptTail = ""
            // Reset Silero state for a fresh stream (also drops any queued segments).
            self.vad?.reset()
        }
    }

    func stop() {
        queue.async {
            self.keepRecognizing = false
            // Force out the in-progress utterance so the last words of a meeting
            // aren't dropped, then drain everything pending.
            self.vad?.flush()
            self.drainSegments(reason: "stop")
        }
        Log.stt.info("[\(source.label)] Whisper stopped")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Copy on the calling (real-time audio) thread — the engine reuses the
        // tap buffer once the callback returns, so it can't cross into the
        // async block. Everything heavy (resample, VAD inference, WAV encode)
        // then runs on the serial queue instead of blocking the RT thread,
        // which the old `queue.sync` did. The queue is serial, so segment
        // order and prompt-tail chaining are unchanged.
        guard let copy = Self.copyBuffer(buffer) else { return }
        queue.async {
            guard self.keepRecognizing, let vad = self.vad, let normalized = self.normalize(copy) else { return }
            guard let channel = normalized.floatChannelData?[0] else { return }
            vad.acceptWaveform(channel, count: Int(normalized.frameLength))
            self.drainSegments(reason: "vad")
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { return nil }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }

    /// Awaitable drain for low-latency callers (Suggest reply). The VAD owns
    /// segmentation, so there's no partial buffer to force out here; we just wait
    /// for in-flight transcriptions to land so the caller reads a complete,
    /// in-order context.
    func flushPending() async {
        let inFlight: [Task<Void, Never>] = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: Array(self.inFlightFlushes.values)) }
        }
        for task in inFlight {
            await task.value
        }
        await MainActor.run {}
    }

    // MARK: - Segment draining

    /// Ship every completed speech segment the VAD has queued. Must be on `queue`.
    private func drainSegments(reason: String) {
        guard let vad else { return }
        while !vad.isEmpty() {
            let segment = vad.front()
            vad.pop()
            guard let samples = segment?.samples, let wav = WhisperTranscriber.encodeWAV(samples) else { continue }
            sendToWhisper(wav: wav, reason: reason)
        }
    }

    // MARK: - Whisper

    /// Must be called on `queue`.
    private func sendToWhisper(wav: Data, reason: String) {
        chunkCounter += 1
        let chunkID = chunkCounter
        Log.stt.info("[\(source.label)] chunk #\(chunkID) → Whisper (\(wav.count) bytes, \(reason))")

        let src = source
        let language = languageProvider()
        let prompt = promptTail.isEmpty ? nil : promptTail
        let taskID = UUID()
        let task = Task<Void, Never> {
            defer {
                self.queue.async { self.inFlightFlushes.removeValue(forKey: taskID) }
            }
            do {
                let text = try await self.client.transcribe(audio: wav, language: language, prompt: prompt)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Log.stt.info("[\(src.label)] chunk #\(chunkID) ← empty")
                    return
                }
                Log.stt.info("[\(src.label)] chunk #\(chunkID) ← \(trimmed)")
                // Feed this chunk's tail to the next one so a word split at a
                // max-length cut is bridged rather than garbled.
                self.queue.async { self.promptTail = String(trimmed.suffix(Self.promptTailMaxChars)) }
                self.onFinal?(trimmed, src)
            } catch {
                Log.stt.error("[\(src.label)] chunk #\(chunkID) Whisper failed: \(error.localizedDescription)")
                self.onFailure?(error.localizedDescription, src)
            }
        }
        inFlightFlushes[taskID] = task
    }

    /// Wrap raw 16 kHz mono float PCM (a VAD segment) into a 16-bit WAV.
    private static func encodeWAV(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        return WAVEncoder.encode16kHzMono([buffer])
    }

    /// Convert any incoming buffer to 16 kHz mono Float32 non-interleaved.
    /// Must be on `queue`.
    private func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.speechFormat
        let inFormat = buffer.format

        if inFormat.sampleRate == target.sampleRate &&
            inFormat.channelCount == target.channelCount &&
            inFormat.commonFormat == target.commonFormat &&
            inFormat.isInterleaved == target.isInterleaved {
            return buffer
        }

        if cachedConverter == nil || cachedSourceFormat != inFormat {
            cachedConverter = AVAudioConverter(from: inFormat, to: target)
            cachedSourceFormat = inFormat
            Log.stt.info("[\(source.label)] converter built: \(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch → 16000Hz/1ch")
        }
        guard let converter = cachedConverter else { return nil }

        let ratio = target.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return nil }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return nil }
        return output
    }
}
