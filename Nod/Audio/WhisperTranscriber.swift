import AVFoundation
import Foundation
import os

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
    var onFinal: ((TranscribedChunk) -> Void)?
    var onFailure: ((String, TranscriptSource) -> Void)?
    /// Called per-segment to determine which language code to send to Whisper.
    /// Default is English; TranscriptStore overrides this to read from the
    /// LanguagePreference so the user's toggle takes effect on the next segment.
    var languageProvider: () -> String = { "en" }

    private let client: OpenRouterClient
    private let queue: DispatchQueue
    private var keepRecognizing = false

    /// Buffers admitted to `queue` but not yet processed. The old `queue.sync`
    /// gave natural backpressure (a stalled queue blocked the audio callback);
    /// with `queue.async` we bound the backlog by dropping instead, so a
    /// stalled VAD (thermal throttling, onnxruntime hiccup) can't grow the
    /// queue without limit during a long meeting. 256 buffers ≈ 5–20 s of
    /// audio (~1 MB) — never reached in normal operation.
    private let pendingBuffers = OSAllocatedUnfairLock(initialState: 0)
    /// Touched only on the producing audio-callback thread.
    private var droppedBuffers = 0
    private static let maxPendingBuffers = 256

    private let vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var chunkCounter: Int = 0

    /// Speaker diarization runs on the system-audio (`.them`) stream only — the
    /// mic is always the local user, one speaker. We spool every VAD utterance
    /// and, at meeting end, run pyannote offline diarization over the whole
    /// spool (see SherpaSpeakerDiarization) — far more robust on many-speaker
    /// calls than per-utterance embedding clustering. nil for `.me` and if the
    /// models fail to load.
    private let diarizer: SherpaSpeakerDiarization?
    /// Concatenated 16 kHz mono speech (VAD utterances only, no silence) for the
    /// end-of-meeting diarization pass. `segmentRanges[i]` is the span of the
    /// i-th emitted `.them` segment within `spool`; `TranscribedChunk.segmentIndex`
    /// carries `i` so TranscriptStore can map the diarizer's speakers back.
    /// Touched only on `queue`.
    private var spool: [Float] = []
    private var segmentRanges: [SegmentRange] = []
    /// Cap the spool so a marathon meeting can't grow memory without bound:
    /// 16 kHz × 40 min of speech ≈ 38.4M floats (~150 MB). Beyond this, later
    /// segments are left unlabelled (carry-forward fills them).
    private static let maxSpoolSamples = 16_000 * 60 * 40

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
        if source == .them {
            diarizer = WhisperTranscriber.makeDiarizer()
            if diarizer == nil {
                Log.stt.error("[\(source.label)] diarization models unavailable — speaker labels disabled")
            }
        } else {
            diarizer = nil
        }
    }

    private static func makeDiarizer() -> SherpaSpeakerDiarization? {
        guard let segmentation = Bundle.main.url(forResource: "speaker_segmentation", withExtension: "onnx")?.path,
              let embedding = Bundle.main.url(forResource: "speaker_embedding", withExtension: "onnx")?.path
        else { return nil }
        return SherpaSpeakerDiarization(segmentationModel: segmentation, embeddingModel: embedding)
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
            // Drop the previous meeting's diarization spool.
            self.spool.removeAll(keepingCapacity: false)
            self.segmentRanges.removeAll(keepingCapacity: false)
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

    /// `copying: false` is for callers that hand over a freshly allocated
    /// buffer they never touch again (the system-audio path — its mono buffer
    /// is built per-callback by SampleBufferConverter). The default copies,
    /// which the engine-owned mic tap buffer requires: the engine reuses it
    /// once the callback returns, so it can't cross into the async block.
    func append(_ buffer: AVAudioPCMBuffer, copying: Bool = true) {
        guard buffer.frameLength > 0 else { return }
        let admitted = pendingBuffers.withLock { count -> Bool in
            guard count < Self.maxPendingBuffers else { return false }
            count += 1
            return true
        }
        guard admitted else {
            // Sampled 1-in-50 after the first — a sustained stall would
            // otherwise flood the log at buffer rate.
            droppedBuffers += 1
            if droppedBuffers == 1 || droppedBuffers % 50 == 0 {
                Log.stt.error("[\(source.label)] processing backlog — dropped \(droppedBuffers) buffers")
            }
            return
        }
        let owned: AVAudioPCMBuffer
        if copying {
            guard let copy = Self.copyBuffer(buffer) else {
                pendingBuffers.withLock { $0 -= 1 }
                return
            }
            owned = copy
        } else {
            owned = buffer
        }
        // Everything heavy (resample, VAD inference, WAV encode) runs on the
        // serial queue instead of blocking the audio thread, which the old
        // `queue.sync` did. The queue is serial, so segment order and
        // prompt-tail chaining are unchanged.
        queue.async {
            defer { self.pendingBuffers.withLock { $0 -= 1 } }
            guard self.keepRecognizing, let vad = self.vad, let normalized = self.normalize(owned) else { return }
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
            sendToWhisper(wav: wav, reason: reason, segmentIndex: spoolForDiarization(samples))
        }
    }

    /// Append a `.them` utterance to the diarization spool and return its index,
    /// or nil for `.me`, when diarization is unavailable, or once the spool cap
    /// is hit (those utterances inherit a neighbour's speaker at mapping time).
    /// Must be on `queue`.
    private func spoolForDiarization(_ samples: [Float]) -> Int? {
        guard diarizer != nil, spool.count + samples.count <= Self.maxSpoolSamples else { return nil }
        let start = spool.count
        spool.append(contentsOf: samples)
        segmentRanges.append(SegmentRange(start: start, count: samples.count))
        return segmentRanges.count - 1
    }

    /// Run pyannote offline diarization over the whole spool and map each
    /// emitted segment to a speaker. Returns labels indexed by `segmentIndex`
    /// (renumbered by first appearance), or nil if diarization is unavailable.
    /// Snapshots the spool on `queue`, then diarizes off the main actor.
    func diarizeSpeakers() async -> [Int]? {
        guard let diarizer else { return nil }
        let snapshot: ([Float], [SegmentRange]) = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: (self.spool, self.segmentRanges)) }
        }
        let (audio, ranges) = snapshot
        guard !audio.isEmpty, !ranges.isEmpty else { return nil }
        let audioSeconds = Double(audio.count) / 16_000
        let started = Date()
        Log.stt.info("diarization: processing \(ranges.count) segments (\(String(format: "%.0f", audioSeconds))s audio)…")
        let diarized = diarizer.process(audio)
        Log.stt.info("diarization: done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(diarized.count) ranges")
        return SpeakerMapping.assign(segmentRanges: ranges, diarization: diarized, sampleRate: diarizer.sampleRate)
    }

    // MARK: - Whisper

    /// Must be called on `queue`.
    private func sendToWhisper(wav: Data, reason: String, segmentIndex: Int?) {
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
                self.onFinal?(TranscribedChunk(text: trimmed, source: src, segmentIndex: segmentIndex))
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
