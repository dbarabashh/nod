import Foundation

/// Retains the speech a VAD actually emitted so the whole stream can be
/// clustered into speakers once the session ends.
///
/// Silence is never kept: it carries no speaker information and dominates a
/// call's wall-clock duration, and every retained sample costs both memory and
/// clustering time (which grows faster than linearly with segment count).
/// Samples are held as `Int16` — half the footprint of the `Float32` the
/// diarizer wants — and expanded once, for the single `Process` call.
/// `@unchecked Sendable`: ownership is transferred, never shared — the
/// transcriber hands the buffer off and drops its reference in the same step,
/// so the clustering pass is the only thing touching it afterwards.
final class DiarizationBuffer: @unchecked Sendable {
    /// Where one VAD segment sits in the concatenated speech timeline. Each
    /// segment is exactly one transcript chunk, so resolving a speaker per span
    /// resolves it per transcript line without any wall-clock arithmetic.
    struct Span: Equatable {
        let id: UUID
        let startSample: Int
        let endSample: Int
    }

    /// Ceiling on retained speech. Clustering cost grows faster than linearly
    /// with segment count (measured: 20x realtime at one minute, 12x at an
    /// hour), and every retained sample is resident memory — an hour of speech
    /// already peaks around 650 MB. Past the cap the buffer stops growing:
    /// earlier lines keep their speakers, later ones simply get none. A partial
    /// answer beats an unbounded one.
    static let maxRetainedSeconds: TimeInterval = 5400

    /// A sentence Whisper reported inside one span, in the same concatenated
    /// timeline. Only recorded when a chunk came back with more than one.
    struct Sentence: Equatable {
        let startSample: Int
        let endSample: Int
    }

    /// Sentences shorter than this never vote on whether a span holds two
    /// voices. A span boundary rarely lines up exactly with a sentence boundary,
    /// so the first or last fraction of a second of a chunk routinely lands in
    /// the neighbouring speaker's turn. Counting those as disagreement would
    /// strip good labels off ordinary single-speaker lines.
    static let minimumVotingSeconds: TimeInterval = 0.6

    private let sampleRate: Int
    private let maxSamples: Int
    private var samples: [Int16] = []
    private var spans: [Span] = []
    private var sentences: [UUID: [Sentence]] = [:]
    private var loggedOverflow = false

    init(sampleRate: Int = 16_000, maxRetainedSeconds: TimeInterval = DiarizationBuffer.maxRetainedSeconds) {
        self.sampleRate = sampleRate
        maxSamples = Int(maxRetainedSeconds * TimeInterval(sampleRate))
    }

    var isEmpty: Bool {
        spans.isEmpty
    }

    var retainedSeconds: TimeInterval {
        TimeInterval(samples.count) / TimeInterval(sampleRate)
    }

    var spanCount: Int {
        spans.count
    }

    func record(_ segment: [Float]) -> UUID? {
        guard !segment.isEmpty else { return nil }
        guard samples.count + segment.count <= maxSamples else {
            if !loggedOverflow {
                loggedOverflow = true
                let minutes = Int(Double(maxSamples) / Double(sampleRate) / 60)
                Log.stt.info("diarization: retained \(minutes) min of speech — later lines go unlabelled")
            }
            return nil
        }
        let id = UUID()
        let start = samples.count
        samples.append(contentsOf: segment.map { value in
            let clamped = min(max(value, -1), 1)
            return Int16(clamped * 32_767)
        })
        spans.append(Span(id: id, startSample: start, endSample: samples.count))
        return id
    }

    /// Records where Whisper's own sentence boundaries fell inside an already-
    /// recorded span, in seconds from the start of that span.
    ///
    /// Deferred rather than passed to `record`, because a span is retained the
    /// moment the VAD emits it and the sentence boundaries only come back with
    /// the transcription seconds later. One VAD segment is one *acoustic* run of
    /// speech, not one speaker's turn: two people answering each other without a
    /// gap land in a single chunk, and greatest-overlap then hands the whole line
    /// to whoever occupied more of it. These boundaries are what makes that case
    /// visible.
    func annotate(_ id: UUID, sentences ranges: [Range<TimeInterval>]) {
        guard ranges.count > 1, let span = spans.first(where: { $0.id == id }) else { return }
        let recorded = ranges.compactMap { range -> Sentence? in
            let start = span.startSample + Int(range.lowerBound * TimeInterval(sampleRate))
            let end = span.startSample + Int(range.upperBound * TimeInterval(sampleRate))
            let clampedStart = min(max(start, span.startSample), span.endSample)
            let clampedEnd = min(max(end, clampedStart), span.endSample)
            guard clampedEnd > clampedStart else { return nil }
            return Sentence(startSample: clampedStart, endSample: clampedEnd)
        }
        guard recorded.count > 1 else { return }
        sentences[id] = recorded
    }

    #if DEBUG
        /// Writes what the diarizer is about to receive — the concatenated
        /// speech and the span boundaries inside it — so a change can be
        /// replayed against a real meeting offline.
        ///
        /// The whole buffer, not the raw stream: the diarizer never sees silence
        /// and never sees wall-clock time, so a fixture built from the recorded
        /// stream would be measuring a pipeline we do not run. See
        /// `docs/build-setup.md`.
        func dumpFixture(label: String) -> URL? {
            let dump = DebugAudioDump(label: label)
            let floats = samples.map { Float($0) / 32_767 }
            floats.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                dump.append(base, count: buffer.count)
            }
            guard let audio = dump.finish() else { return nil }

            let manifest = audio.deletingPathExtension().appendingPathExtension("spans.json")
            let rate = sampleRate
            let payload = spans.map { span in
                [
                    "id": span.id.uuidString,
                    "start": String(format: "%.3f", Double(span.startSample) / Double(rate)),
                    "end": String(format: "%.3f", Double(span.endSample) / Double(rate))
                ]
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: ["sampleRate": rate, "spans": payload],
                options: [.prettyPrinted, .sortedKeys]
            ) else { return audio }
            try? data.write(to: manifest)
            Log.stt.info("diarization: fixture written — \(spans.count) span(s) beside \(audio.lastPathComponent)")
            return audio
        }
    #endif

    /// Cluster the retained speech and hand back one speaker per recorded span.
    /// Spans the diarizer could not attribute are absent from the result rather
    /// than guessed at.
    func resolveSpeakers(using diarizer: SpeakerDiarizer, speakerCount: Int) async -> [UUID: Int] {
        guard !spans.isEmpty else { return [:] }
        #if DEBUG
            if DebugAudioDump.isEnabled { _ = dumpFixture(label: "diarization") }
        #endif
        let samples = samples.map { Float($0) / 32_767 }
        let turns = await SpeakerAssignment.normalized(diarizer.diarize(samples, speakerCount: speakerCount))
        guard !turns.isEmpty else { return [:] }
        return speakers(in: turns)
    }

    /// Maps an already-clustered timeline back onto the recorded spans.
    func speakers(in turns: [DiarizedTurn]) -> [UUID: Int] {
        Self.speakers(for: spans, sentences: sentences, in: turns, sampleRate: sampleRate)
    }

    static func speakers(
        for spans: [Span],
        sentences: [UUID: [Sentence]] = [:],
        in turns: [DiarizedTurn],
        sampleRate: Int
    ) -> [UUID: Int] {
        var resolved: [UUID: Int] = [:]
        var mixed = 0
        for span in spans {
            guard let voice = speaker(of: span, sentences: sentences[span.id], in: turns, sampleRate: sampleRate) else {
                if sentences[span.id] != nil { mixed += 1 }
                continue
            }
            resolved[span.id] = voice
        }
        if mixed > 0 {
            Log.stt.info("diarization: \(mixed) chunk(s) hold more than one voice — left unattributed")
        }
        return resolved
    }

    /// One speaker for a span, or nil when the diarizer either could not
    /// attribute it or attributed its sentences to different people.
    ///
    /// Whichever voice occupied more of a two-speaker chunk is not the answer —
    /// it is a coin flip that reads as certainty, and the recap then quotes one
    /// person saying the other's words. Unattributed is the honest result: the
    /// line still shows, it just carries no name.
    private static func speaker(
        of span: Span,
        sentences: [Sentence]?,
        in turns: [DiarizedTurn],
        sampleRate: Int
    ) -> Int? {
        func voice(from startSample: Int, to endSample: Int) -> Int? {
            SpeakerAssignment.speaker(
                from: TimeInterval(startSample) / TimeInterval(sampleRate),
                to: TimeInterval(endSample) / TimeInterval(sampleRate),
                in: turns
            )
        }
        guard let sentences else { return voice(from: span.startSample, to: span.endSample) }

        let minimumSamples = Int(minimumVotingSeconds * TimeInterval(sampleRate))
        let voters = sentences.filter { $0.endSample - $0.startSample >= minimumSamples }
        // Every sentence too short to vote — a chunk of clipped interjections.
        // Nothing to compare, so fall back to reading the span whole.
        guard !voters.isEmpty else { return voice(from: span.startSample, to: span.endSample) }

        let voices = Set(voters.compactMap { voice(from: $0.startSample, to: $0.endSample) })
        return voices.count == 1 ? voices.first : nil
    }
}
