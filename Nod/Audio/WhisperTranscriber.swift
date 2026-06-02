import AVFoundation
import Foundation

/// Streams audio buffers, groups them into ~chunkSeconds-long WAVs, and POSTs
/// each chunk to Whisper via OpenRouter. Each successful chunk's text is
/// emitted as a single TranscriptEntry (no live partials — Whisper is batch).
final class WhisperTranscriber: @unchecked Sendable {
    let source: TranscriptSource
    var onFinal: ((String, TranscriptSource) -> Void)?
    var onFailure: ((String, TranscriptSource) -> Void)?
    /// Called per-chunk to determine which language code to send to Whisper.
    /// Default is English; TranscriptStore overrides this to read from the
    /// LanguagePreference so the user's toggle takes effect immediately
    /// (next chunk).
    var languageProvider: () -> String = { "en" }

    private let client: OpenRouterClient
    private let queue: DispatchQueue
    private var keepRecognizing = false

    private var chunkBuffers: [AVAudioPCMBuffer] = []
    private var chunkFrames: AVAudioFrameCount = 0
    private let chunkTargetFrames: AVAudioFrameCount = 16_000 * 5 // 5 s
    private let vad: VAD
    private var chunkCounter: Int = 0

    // In-flight regular-flush Tasks; flushPending awaits these so on-demand
    // results don't land before older chunks (queue-guarded).
    private var inFlightFlushes: [UUID: Task<Void, Never>] = [:]

    // Canonical SFSpeech/Whisper input format. AVAudioConverter caches identical
    // to SpeechTranscriber so we don't pay init cost on the audio thread.
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
        vad = VAD(source: source)
        queue = DispatchQueue(label: "nod.whisper.\(source.rawValue)", qos: .userInteractive)
    }

    func start() async {
        Log.stt.info("[\(source.label)] Whisper start()")
        queue.async {
            self.keepRecognizing = true
            self.chunkBuffers.removeAll(keepingCapacity: true)
            self.chunkFrames = 0
        }
    }

    func stop() {
        queue.async {
            self.keepRecognizing = false
            // Flush whatever's pending so the last words of a meeting aren't dropped.
            if self.chunkFrames > 0 {
                self.flushChunk(reason: "stop")
            }
        }
        Log.stt.info("[\(source.label)] Whisper stopped")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard self.keepRecognizing else { return }
            guard let normalized = self.normalize(buffer) else { return }
            self.chunkBuffers.append(normalized)
            self.chunkFrames += normalized.frameLength
            if self.chunkFrames >= self.chunkTargetFrames {
                self.flushChunk(reason: "full")
            }
        }
    }

    /// Awaitable flush for low-latency callers. Returns text or nil. Does
    /// not fire `onFinal` — caller appends directly to avoid racing the
    /// `DispatchQueue.main.async` hop that `handleFinal` uses.
    func flushPending() async -> String? {
        struct Pending {
            let buffers: [AVAudioPCMBuffer]
            let frames: AVAudioFrameCount
            let chunkID: Int
            let peak: Float
            let rms: Float
        }

        // Drain any in-flight regular flushes first so their older audio
        // lands in `entries` before ours — preserves order and prevents the
        // LLM from seeing stale context.
        let inFlight: [Task<Void, Never>] = await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: Array(self.inFlightFlushes.values))
            }
        }
        for task in inFlight {
            await task.value
        }
        // Yield to main so handleFinal's DispatchQueue.main.async closures
        // are visible in `entries` before the caller reads `fullContext`.
        await MainActor.run {}

        let pending: Pending? = await withCheckedContinuation { cont in
            queue.async {
                guard !self.chunkBuffers.isEmpty else {
                    cont.resume(returning: nil)
                    return
                }
                let buffers = self.chunkBuffers
                let frames = self.chunkFrames
                self.chunkBuffers.removeAll(keepingCapacity: true)
                self.chunkFrames = 0
                self.chunkCounter += 1
                let id = self.chunkCounter

                let (p, r) = VAD.peakAndRMS(buffers)
                cont.resume(returning: Pending(buffers: buffers, frames: frames, chunkID: id, peak: p, rms: r))
            }
        }

        guard let pending else {
            Log.stt.info("[\(source.label)] flushPending — buffer empty, nothing to send")
            return nil
        }

        if vad.isSilent(peak: pending.peak, rms: pending.rms) {
            Log.stt.info(
                "[\(source.label)] flushPending chunk #\(pending.chunkID) skipped — silent (peak=\(String(format: "%.4f", pending.peak)) rms=\(String(format: "%.4f", pending.rms)))"
            )
            return nil
        }

        let durationSec = Double(pending.frames) / 16_000.0
        Log.stt.info(
            "[\(source.label)] chunk #\(pending.chunkID) → Whisper (\(String(format: "%.1f", durationSec))s, peak=\(String(format: "%.3f", pending.peak)), rms=\(String(format: "%.3f", pending.rms)), on-demand)"
        )

        guard let wav = WAVEncoder.encode16kHzMono(pending.buffers) else {
            Log.stt.error("[\(source.label)] chunk #\(pending.chunkID) WAV encode failed")
            return nil
        }

        let language = languageProvider()
        do {
            let text = try await client.transcribe(audio: wav, fileName: "chunk-\(pending.chunkID).wav", language: language)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Log.stt.info("[\(source.label)] chunk #\(pending.chunkID) ← empty")
                return nil
            }
            Log.stt.info("[\(source.label)] chunk #\(pending.chunkID) ← \(trimmed)")
            return trimmed
        } catch {
            Log.stt.error("[\(source.label)] chunk #\(pending.chunkID) Whisper failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Must be called on `queue`.
    private func flushChunk(reason: String) {
        guard !chunkBuffers.isEmpty else { return }
        let buffers = chunkBuffers
        let frames = chunkFrames
        chunkBuffers.removeAll(keepingCapacity: true)
        chunkFrames = 0
        chunkCounter += 1
        let chunkID = chunkCounter

        let (peak, rms) = VAD.peakAndRMS(buffers)
        if vad.isSilent(peak: peak, rms: rms) {
            Log.stt.info(
                "[\(source.label)] chunk #\(chunkID) skipped — silent (peak=\(String(format: "%.4f", peak)) rms=\(String(format: "%.4f", rms)))"
            )
            return
        }

        let durationSec = Double(frames) / 16_000.0
        Log.stt.info(
            "[\(source.label)] chunk #\(chunkID) → Whisper (\(String(format: "%.1f", durationSec))s, peak=\(String(format: "%.3f", peak)), rms=\(String(format: "%.3f", rms)), \(reason))"
        )

        guard let wav = WAVEncoder.encode16kHzMono(buffers) else {
            Log.stt.error("[\(source.label)] chunk #\(chunkID) WAV encode failed")
            return
        }

        let src = source
        let weakSelf = self
        let language = languageProvider()
        let taskID = UUID()
        let task = Task<Void, Never> {
            defer {
                weakSelf.queue.async {
                    weakSelf.inFlightFlushes.removeValue(forKey: taskID)
                }
            }
            do {
                let text = try await weakSelf.client.transcribe(audio: wav, fileName: "chunk-\(chunkID).wav", language: language)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Log.stt.info("[\(src.label)] chunk #\(chunkID) ← empty")
                    return
                }
                Log.stt.info("[\(src.label)] chunk #\(chunkID) ← \(trimmed)")
                weakSelf.onFinal?(trimmed, src)
            } catch {
                Log.stt.error("[\(src.label)] chunk #\(chunkID) Whisper failed: \(error.localizedDescription)")
                weakSelf.onFailure?(error.localizedDescription, src)
            }
        }
        inFlightFlushes[taskID] = task
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
