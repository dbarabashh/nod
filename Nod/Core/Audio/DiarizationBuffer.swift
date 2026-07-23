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

    private let sampleRate: Int
    private let maxSamples: Int
    private var samples: [Int16] = []
    private var spans: [Span] = []
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

    /// Cluster the retained speech and hand back one speaker per recorded span.
    /// Spans the diarizer could not attribute are absent from the result rather
    /// than guessed at.
    func resolveSpeakers(using diarizer: SpeakerDiarizer) -> [UUID: Int] {
        guard !spans.isEmpty else { return [:] }
        let turns = SpeakerAssignment.normalized(diarizer.diarize(samples.map { Float($0) / 32_767 }))
        guard !turns.isEmpty else { return [:] }
        return Self.speakers(for: spans, in: turns, sampleRate: sampleRate)
    }

    static func speakers(for spans: [Span], in turns: [DiarizedTurn], sampleRate: Int) -> [UUID: Int] {
        var resolved: [UUID: Int] = [:]
        for span in spans {
            let start = TimeInterval(span.startSample) / TimeInterval(sampleRate)
            let end = TimeInterval(span.endSample) / TimeInterval(sampleRate)
            if let speaker = SpeakerAssignment.speaker(from: start, to: end, in: turns) {
                resolved[span.id] = speaker
            }
        }
        return resolved
    }
}
