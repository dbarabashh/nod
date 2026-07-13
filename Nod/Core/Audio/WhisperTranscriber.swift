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

    private let client: LLMProxyClient
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

    /// Rolling tail of this source's recently confirmed text, fed to Whisper as
    /// the decode prompt so each isolated chunk regains context (proper nouns,
    /// spelling). Touched only on `queue`. Capped well under Whisper's ~224-token
    /// prompt window so it can't crowd out the audio.
    ///
    /// The prompt also biases the *output language* — an English tail makes
    /// Whisper keep emitting English even when the speaker switches to another
    /// language (it effectively translates). That breaks the multilingual /
    /// code-switching property we rely on, so the tail is language-scoped: it
    /// carries `promptLanguage` and resets on a detected language switch. (An
    /// optional re-transcribe-without-prompt on that switch is gated behind
    /// `repromptOnLanguageSwitch`, default off — see below.)
    private var promptTail: String = ""
    private var promptLanguage: String?
    private static let maxPromptTailChars = 200

    /// On a detected language switch, re-transcribe the chunk with NO prompt so
    /// the prior-language tail can't bias Whisper into translating the new
    /// language back. Defaults OFF: an A/B on identical uk/ru/en surzhik clips
    /// showed that KEEPING the prompt fixes the topic-critical words — "суржик"
    /// only garbled to "сырчик"/"Уржиком" when the prompt was dropped — at the
    /// minor cost of occasionally pulling a genuinely Russian turn toward the
    /// Ukrainian tail. Flip on to restore the re-transcribe:
    /// `defaults write com.example.nod stt.repromptOnLanguageSwitch -bool YES`.
    private static var repromptOnLanguageSwitch: Bool {
        UserDefaults.standard.object(forKey: "stt.repromptOnLanguageSwitch") as? Bool ?? false
    }

    // In-flight transcription Tasks; flushPending awaits these so a Suggest-reply
    // sees all completed segments, in order, before it reads the context.
    private var inFlightFlushes: [UUID: Task<Void, Never>] = [:]

    /// A speech segment whose upload failed on a transient transport error and
    /// is parked for a later retry (NOD-29). Carries the WAV plus the prompt
    /// snapshot *as it was at the failed attempt* — replaying with the current,
    /// since-advanced tail would condition the decode on the wrong point in the
    /// conversation.
    private struct PendingSegment {
        let wav: Data
        let prompt: String
        let promptLanguage: String?
        let timestamp: Date
    }

    /// Bounded FIFO of segments awaiting a retry. Touched only on `queue`.
    /// Drained on a network `.satisfied` edge and after any successful upload.
    /// Bounded like `pendingBuffers`: a long outage past the cap drops the
    /// *oldest* audio (see `enqueueForRetryLocked`) rather than growing without
    /// limit. 64 segments ≈ up to ~16 min of speech held in RAM.
    private var retryQueue: [PendingSegment] = []
    private static let maxRetryQueue = 64
    private var droppedRetrySegments = 0

    /// Parked segments in flight right now. Bounds a drain so a reconnect after a
    /// long outage replays a rolling few segments at a time instead of firing all
    /// 64 at once — a burst that just trips the proxy's per-worker/429 limits and
    /// re-parks everything. Each replay tops the window back up as it lands.
    /// Touched only on `queue`.
    private var inFlightRetries = 0
    private static let maxConcurrentRetries = 4

    /// Bumped on every `start()`. A transcription Task captures the generation it
    /// began under and drops its result if the value has since changed, so a
    /// slow in-flight upload or a late queue drain can never leak a previous
    /// meeting's words into the next one. (Also fixes the latent case of a slow
    /// transcribe straddling an End → new-recording boundary.)
    private var generation = 0

    private struct AudioClockSpan {
        let startSample: Int
        let count: Int
        let startDate: Date

        var endSample: Int {
            startSample + count
        }
    }

    private var acceptedSampleCount = 0
    private var audioClockSpans: [AudioClockSpan] = []

    // Silero segmentation tuning (see sherpaOnnxSileroVadModelConfig):
    /// Cut a segment only after this much trailing silence. A/B knob (default
    /// 0.7s, was 1.0s): shorter closes a segment faster, which suits fast
    /// code-switched (surzhik) dialogue where natural pauses run under a second
    /// and a 1s gate glued separate utterances together. Don't push it too low —
    /// the meeting then fragments into one-word chunks, which cost extra Whisper
    /// calls and make Whisper hallucinate speaker-name prefixes on the tiny
    /// clips ("Emily King, PhD.: …"). Override:
    /// `defaults write com.example.nod vad.minSilence 1.0`.
    private static var minSilenceDuration: Float {
        if let override = UserDefaults.standard.object(forKey: "vad.minSilence") as? Double {
            return Float(override)
        }
        return 0.7
    }

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

    init(source: TranscriptSource, client: LLMProxyClient) {
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
            self.generation &+= 1
            self.keepRecognizing = true
            // Reset Silero state for a fresh stream (also drops any queued segments).
            self.vad?.reset()
            self.acceptedSampleCount = 0
            self.audioClockSpans.removeAll(keepingCapacity: false)
            self.promptTail = ""
            self.promptLanguage = nil
            if !self.retryQueue.isEmpty {
                Log.stt.error("[\(self.source.label)] discarding \(self.retryQueue.count) undelivered segment(s) from a previous session")
                self.retryQueue.removeAll(keepingCapacity: false)
            }
            self.droppedRetrySegments = 0
            // A retry Task from the previous session is generation-gated out
            // without decrementing, so reset the window to avoid drift.
            self.inFlightRetries = 0
        }
    }

    func stop() {
        queue.async {
            // Force out the in-progress utterance so the last words of a meeting
            // aren't dropped, then drain everything pending — both the VAD's
            // finished segments and any parked retries (the link may well be back
            // by End). keepRecognizing is cleared last so this final drain runs.
            self.vad?.flush()
            self.drainSegments(reason: "stop")
            self.resendQueuedLocked(reason: "stop")
            self.keepRecognizing = false
        }
        Log.stt.info("[\(source.label)] Whisper stopped")
    }

    /// Retry every parked segment now that connectivity is back. Called by
    /// `TranscriptStore` on a network `.satisfied` edge. A no-op unless a
    /// recording is active, so a reconnect between meetings can't replay stale
    /// audio into a finished one.
    func drainRetryQueue() {
        queue.async {
            guard self.keepRecognizing else { return }
            self.resendQueuedLocked(reason: "reconnect")
        }
    }

    /// `copying: false` is for callers that hand over a freshly allocated
    /// buffer they never touch again (the system-audio path — its mono buffer
    /// is built per-callback by SampleBufferConverter). The default copies,
    /// which the engine-owned mic tap buffer requires: the engine reuses it
    /// once the callback returns, so it can't cross into the async block.
    func append(_ buffer: AVAudioPCMBuffer, copying: Bool = true) {
        guard buffer.frameLength > 0 else { return }
        let receivedAt = Date()
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
            let frameCount = Int(normalized.frameLength)
            guard frameCount > 0 else { return }
            self.noteAcceptedAudio(frameCount: frameCount, receivedAt: receivedAt)
            vad.acceptWaveform(channel, count: frameCount)
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
        if !inFlight.isEmpty {
            // Bound the wait. With Layer 1 (`waitsForConnectivity`) a chunk upload
            // can sit in-flight for the whole resource timeout during an outage,
            // and the callers here are interactive (Suggest reply, live Ask) — they
            // must not block on it. Race the in-flight drain against a deadline and
            // take whichever lands first; a still-parked send finishes and emits in
            // the background. Awaiting a non-throwing Task ignores cancellation, so
            // the loser is abandoned rather than structurally awaited.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                @Sendable func finishOnce() {
                    let firstToFinish = resumed.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    if firstToFinish { cont.resume() }
                }
                Task {
                    for task in inFlight {
                        await task.value
                    }
                    finishOnce()
                }
                Task {
                    try? await Task.sleep(nanoseconds: Self.flushDeadlineNanos)
                    finishOnce()
                }
            }
        }
        await MainActor.run {}
    }

    /// How long `flushPending` waits for in-flight uploads before proceeding with
    /// whatever has landed. Comfortably covers a normal online transcribe (~1–3s)
    /// while capping the offline hang the connectivity-wait would otherwise cause.
    private static let flushDeadlineNanos: UInt64 = 5_000_000_000

    // MARK: - Segment draining

    /// Ship every completed speech segment the VAD has queued. Must be on `queue`.
    private func drainSegments(reason: String) {
        guard let vad else { return }
        while !vad.isEmpty() {
            let segment = vad.front()
            vad.pop()
            guard let segment,
                  let wav = WhisperTranscriber.encodeWAV(segment.samples)
            else { continue }
            sendToWhisper(
                wav: wav,
                reason: reason,
                timestamp: timestamp(forSampleIndex: segment.start),
                prompt: promptTail,
                promptLanguage: promptLanguage,
                retrying: false
            )
        }
    }

    private func noteAcceptedAudio(frameCount: Int, receivedAt: Date) {
        let startSample = acceptedSampleCount
        let duration = Double(frameCount) / Self.speechFormat.sampleRate
        audioClockSpans.append(AudioClockSpan(
            startSample: startSample,
            count: frameCount,
            startDate: receivedAt.addingTimeInterval(-duration)
        ))
        acceptedSampleCount += frameCount
    }

    private func timestamp(forSampleIndex sampleIndex: Int) -> Date {
        for span in audioClockSpans.reversed() {
            if sampleIndex >= span.startSample, sampleIndex < span.endSample {
                let offset = Double(sampleIndex - span.startSample) / Self.speechFormat.sampleRate
                return span.startDate.addingTimeInterval(offset)
            }
        }
        if let first = audioClockSpans.first {
            let offset = Double(sampleIndex - first.startSample) / Self.speechFormat.sampleRate
            return first.startDate.addingTimeInterval(offset)
        }
        return Date()
    }

    // MARK: - Whisper

    /// Must be called on `queue`. `prompt`/`promptLanguage` are the decode-time
    /// context: the live path passes the current rolling tail; a retry passes the
    /// snapshot captured when it first failed, so a late replay conditions on the
    /// right point in the conversation. `retrying` also suppresses advancing the
    /// live prompt tail — a deferred segment must not rewind it.
    private func sendToWhisper(
        wav: Data,
        reason: String,
        timestamp: Date,
        prompt: String,
        promptLanguage promptLang: String?,
        retrying: Bool
    ) {
        chunkCounter += 1
        let chunkID = chunkCounter
        Log.stt.info("[\(source.label)] chunk #\(chunkID) → Whisper (\(wav.count) bytes, \(reason))")

        let src = source
        let taskID = UUID()
        let capturedGeneration = generation
        let task = Task<Void, Never> {
            defer {
                self.queue.async { self.inFlightFlushes.removeValue(forKey: taskID) }
            }
            do {
                var result = try await self.client.transcribe(audio: wav, prompt: prompt)
                // If the speaker switched language, the (prior-language) prompt
                // biases the output back toward it — Whisper detects the new
                // language but emits the old one (translating). Re-transcribe the
                // same audio with no prompt so the text comes back in the language
                // actually spoken. One extra call, only at a language boundary.
                if Self.repromptOnLanguageSwitch,
                   !prompt.isEmpty,
                   let detected = result.language,
                   let promptLang,
                   detected.caseInsensitiveCompare(promptLang) != .orderedSame {
                    Log.stt.info(
                        "[\(src.label)] chunk #\(chunkID) language switch (tail=\(promptLang) chunk=\(detected)) — re-transcribing without prompt"
                    )
                    if let reprompted = try? await self.client.transcribe(audio: wav) {
                        result = reprompted
                    }
                }
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let kept: String?
                if trimmed.isEmpty {
                    Log.stt.info("[\(src.label)] chunk #\(chunkID) ← empty")
                    kept = nil
                } else if HallucinationFilter.isHallucination(
                    text: trimmed,
                    segments: result.segments,
                    promptContext: prompt
                ) {
                    // Don't log the dropped text itself — user transcript content
                    // must not land in `info` logs (CONVENTIONS.md § Logging).
                    Log.stt.info("[\(src.label)] chunk #\(chunkID) ← dropped (hallucination) chars=\(trimmed.count)")
                    kept = nil
                } else {
                    Log.stt.info("[\(src.label)] chunk #\(chunkID) ← \(trimmed)")
                    kept = trimmed
                }
                let detectedLanguage = result.language
                // Emission is resolved on `queue` (generation gate + prompt tail)
                // but fired after the hop, so `flushPending` still sees the append
                // before its await returns.
                let emission: TranscribedChunk? = await withCheckedContinuation { continuation in
                    self.queue.async {
                        guard self.generation == capturedGeneration else {
                            continuation.resume(returning: nil)
                            return
                        }
                        if retrying { self.inFlightRetries -= 1 }
                        if let kept, !retrying {
                            self.appendPromptTail(kept, language: detectedLanguage)
                        }
                        self.resendQueuedLocked(reason: retrying ? "retryDone" : "afterSuccess")
                        continuation.resume(
                            returning: kept.map { TranscribedChunk(text: $0, source: src, timestamp: timestamp) }
                        )
                    }
                }
                if let emission { self.onFinal?(emission) }
            } catch {
                // Transient failures park for retry rather than lose the audio;
                // permanent ones can't be retried, so they surface to the user.
                if Self.isRetriableTransport(error) {
                    Log.stt.error(
                        "[\(src.label)] chunk #\(chunkID) transient upload failure — queued for retry: \(error.localizedDescription)"
                    )
                    self.queue.async {
                        guard self.generation == capturedGeneration else { return }
                        // A failed retry frees its slot but does NOT top up: a
                        // still-down link would just re-fail. Re-parked, it waits
                        // for the next `.satisfied` edge or a live success.
                        if retrying { self.inFlightRetries -= 1 }
                        self.enqueueForRetryLocked(
                            wav: wav,
                            prompt: prompt,
                            promptLanguage: promptLang,
                            timestamp: timestamp,
                            chunkID: chunkID
                        )
                    }
                } else {
                    Log.stt.error("[\(src.label)] chunk #\(chunkID) Whisper failed: \(error.localizedDescription)")
                    self.onFailure?(error.localizedDescription, src)
                }
            }
        }
        inFlightFlushes[taskID] = task
    }

    // MARK: - Retry queue (NOD-29)

    /// True for transport failures worth parking: the client's own transient set
    /// (offline / connection-dropped / upstream 5xx / 429). Anything else — auth,
    /// entitlement, decode — is permanent and must not be retried.
    private static func isRetriableTransport(_ error: Error) -> Bool {
        guard let clientError = error as? LLMProxyClient.ClientError else { return false }
        return LLMProxyClient.isTransient(clientError)
    }

    /// Park a failed segment. Must be on `queue`. On overflow the *oldest* parked
    /// segment is evicted so the freshest speech — closest to reconnect and to
    /// the ongoing conversation — survives a long outage. Lossy by design past
    /// the cap; the loss-free fix is on-device STT (out of scope).
    private func enqueueForRetryLocked(
        wav: Data,
        prompt: String,
        promptLanguage: String?,
        timestamp: Date,
        chunkID: Int
    ) {
        if retryQueue.count >= Self.maxRetryQueue {
            retryQueue.removeFirst()
            droppedRetrySegments += 1
            if droppedRetrySegments == 1 || droppedRetrySegments % 20 == 0 {
                Log.stt.error("[\(source.label)] retry queue full — dropped \(droppedRetrySegments) oldest segment(s)")
            }
        }
        retryQueue.append(PendingSegment(wav: wav, prompt: prompt, promptLanguage: promptLanguage, timestamp: timestamp))
        Log.stt.info("[\(source.label)] chunk #\(chunkID) parked for retry (queued=\(retryQueue.count))")
    }

    /// Replay parked segments in capture order, up to `maxConcurrentRetries` in
    /// flight at once — the rest stay parked and are pulled in as each replay
    /// lands (see the success path). Must be on `queue`. A replay that fails again
    /// re-parks itself, so a still-flaky link just cycles back here on the next
    /// `.satisfied` edge or the next success — never a blind timer loop, never a
    /// reconnect stampede.
    private func resendQueuedLocked(reason: String) {
        var started = 0
        while inFlightRetries < Self.maxConcurrentRetries, !retryQueue.isEmpty {
            let item = retryQueue.removeFirst()
            inFlightRetries += 1
            started += 1
            sendToWhisper(
                wav: item.wav,
                reason: "retry",
                timestamp: item.timestamp,
                prompt: item.prompt,
                promptLanguage: item.promptLanguage,
                retrying: true
            )
        }
        if started > 0 {
            Log.stt.info(
                "[\(source.label)] draining \(started) parked segment(s) (\(reason), inFlight=\(inFlightRetries), remaining=\(retryQueue.count))"
            )
        }
    }

    /// Append kept text to the rolling prompt and trim to the tail window. On a
    /// detected language switch the tail is replaced (not appended), so the prior
    /// language can't keep biasing the new one. Must be on `queue`.
    private func appendPromptTail(_ text: String, language: String?) {
        if let language, let promptLanguage, language.caseInsensitiveCompare(promptLanguage) != .orderedSame {
            promptTail = String(text.suffix(Self.maxPromptTailChars))
            self.promptLanguage = language
            return
        }
        if promptLanguage == nil { promptLanguage = language }
        let combined = promptTail.isEmpty ? text : promptTail + " " + text
        promptTail = String(combined.suffix(Self.maxPromptTailChars))
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
