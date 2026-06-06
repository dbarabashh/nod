import AVFoundation
import Foundation
import RealTimeCutVADLibrary

/// Streams audio buffers through Silero VAD (RealTimeCutVADLibrary), which runs
/// entirely on-device: it detects whole speech segments — start at speech
/// onset, end after a natural pause — denoises them (WebRTC APM), and hands back
/// a ready 16 kHz WAV per utterance. Each segment is POSTed to Whisper via
/// OpenRouter and emitted as one TranscriptEntry.
///
/// Cutting on real speech boundaries (not a fixed timer) is the whole point:
/// the previous timer cut sliced words across chunks, and each garbled boundary
/// propagated into the recap, entities, and search index.
final class WhisperTranscriber: NSObject, VADDelegate, @unchecked Sendable {
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

    private var vad: VADWrapper
    private var chunkCounter: Int = 0

    // In-flight transcription Tasks; flushPending awaits these so a Suggest-reply
    // sees all completed segments, in order, before it reads the context.
    private var inFlightFlushes: [UUID: Task<Void, Never>] = [:]

    /// Denoised 16 kHz mono float PCM of the utterance currently being spoken,
    /// accumulated from the VAD's streaming callback. This is the source for
    /// every chunk we send — the library's per-segment WAV is ignored so the
    /// max-length valve can split a long utterance mid-stream and the
    /// end-of-meeting tail can be flushed when no trailing pause ever arrives.
    /// Cleared after each flush.
    private var pendingSegment: [Float] = []

    /// Safety valve for continuous audio that never pauses (media playback, a
    /// non-stop talker): the VAD only closes a segment after ~1.8s of silence,
    /// so without this a playing video would accumulate one ever-growing chunk
    /// and the live transcript would stay empty until the meeting ends. Flush
    /// the in-progress utterance at this length and keep going. Stays within
    /// Whisper's ~30s window.
    private static let maxSegmentFrames = 16_000 * 15 // 15 s

    /// Tail of the most recent transcription, fed back to Whisper as the
    /// `prompt` for the next chunk. When a long utterance is force-cut at the
    /// max length, the boundary word would otherwise be sliced and mistranscribed
    /// in both halves; priming Whisper with the preceding words lets it recover
    /// the boundary and keeps terminology consistent across chunks.
    private var promptTail: String = ""
    /// Whisper only conditions on the last ~224 tokens of the prompt, so keep
    /// the tail short — recent context, not the whole meeting.
    private static let promptTailMaxChars = 200

    // Canonical Whisper input format. The VAD wants mono 16 kHz; we normalize to
    // it here so any device sample rate (incl. 44.1 kHz, which the library can't
    // resample itself) is handled before the audio reaches Silero.
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
        vad = VADWrapper()
        super.init()
        configureVAD()
    }

    private func configureVAD() {
        vad.setSileroModel(.v5)
        vad.setSamplerate(.SAMPLERATE_16)
        vad.delegate = self
    }

    func start() async {
        Log.stt.info("[\(source.label)] Whisper start() — Silero VAD")
        queue.async {
            self.keepRecognizing = true
            self.pendingSegment.removeAll(keepingCapacity: true)
            self.promptTail = ""
            // Fresh VAD instance so Silero's internal state starts clean for the
            // new meeting (the library has no reset).
            self.vad = VADWrapper()
            self.configureVAD()
        }
    }

    func stop() {
        queue.async {
            self.keepRecognizing = false
            // The VAD only emits a segment after a trailing pause; if the meeting
            // ends mid-utterance, flush the buffered words ourselves so the last
            // sentence isn't dropped.
            self.flushSegment(reason: "stop")
        }
        Log.stt.info("[\(source.label)] Whisper stopped")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard self.keepRecognizing, let normalized = self.normalize(buffer) else { return }
            guard let channel = normalized.floatChannelData?[0] else { return }
            // Synchronous: the VAD invokes our delegate callbacks inline on this
            // queue as it detects a segment start / continuation / end.
            self.vad.processAudioData(withBuffer: channel, count: UInt(normalized.frameLength))
        }
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
        // Yield to main so any onFinal hops are visible before the caller reads
        // fullContext.
        await MainActor.run {}
    }

    // MARK: - VADDelegate (invoked inline on `queue` from processAudioData)

    func voiceStarted() {
        pendingSegment.removeAll(keepingCapacity: true)
        // A 15s segment is ~240k floats; reserve once so the growth doesn't
        // realloc repeatedly on the audio queue (capacity survives removeAll).
        pendingSegment.reserveCapacity(Self.maxSegmentFrames)
    }

    func voiceEnded(withWavData wavData: Data) {
        // Build the chunk from our accumulated PCM, not the library's wavData —
        // so the max-length valve can split a long segment mid-stream without
        // the eventual voiceEnded re-sending the whole thing as a duplicate.
        flushSegment(reason: "vad")
    }

    func voiceDidContinue(withPCMFloat pcmFloatData: Data) {
        pcmFloatData.withUnsafeBytes { raw in
            pendingSegment.append(contentsOf: raw.bindMemory(to: Float.self))
        }
        if pendingSegment.count >= Self.maxSegmentFrames {
            flushSegment(reason: "max")
        }
    }

    /// Encode the buffered utterance PCM to a WAV and ship it. Must be on `queue`.
    private func flushSegment(reason: String) {
        defer { pendingSegment.removeAll(keepingCapacity: true) }
        guard let wav = WhisperTranscriber.encodeWAV(pendingSegment) else { return }
        sendToWhisper(wav: wav, reason: reason)
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
                // Feed this chunk's tail to the next one so a word split at the
                // cut is bridged rather than garbled.
                self.queue.async { self.promptTail = String(trimmed.suffix(Self.promptTailMaxChars)) }
                self.onFinal?(trimmed, src)
            } catch {
                Log.stt.error("[\(src.label)] chunk #\(chunkID) Whisper failed: \(error.localizedDescription)")
                self.onFailure?(error.localizedDescription, src)
            }
        }
        inFlightFlushes[taskID] = task
    }

    /// Wrap raw 16 kHz mono float PCM into a 16-bit WAV via the shared encoder.
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
