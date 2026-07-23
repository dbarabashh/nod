import Foundation

/// One diarized turn: a contiguous stretch of speech attributed to one cluster.
/// `speaker` is a cluster index local to a single `diarize` call, not a stable
/// identity across meetings.
struct DiarizedTurn: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

/// Whether diarization also runs for `media` sessions. Off by default: podcasts
/// and videos carry intro music and soundtracks, which the segmentation model
/// turns into phantom speakers. Meetings are unaffected — they are always
/// diarized when `SessionKind.supportsDiarization` allows it.
enum DiarizationDefaults {
    static let mediaKey = "diarization.media.enabled"
    static let mediaDefaultValue = false

    static var includesMedia: Bool {
        UserDefaults.standard.object(forKey: mediaKey) as? Bool ?? mediaDefaultValue
    }
}

/// Maps raw diarization output onto transcript chunks.
enum SpeakerAssignment {
    /// Relabels cluster ids into a dense `1...N` in order of first appearance.
    /// sherpa-onnx returns whatever indices clustering happened to leave behind
    /// — a five-speaker result can come back as `[0, 1, 2, 3, 8]` — so the raw
    /// values must never reach the UI or the recap prompt.
    static func normalized(_ turns: [DiarizedTurn]) -> [DiarizedTurn] {
        var labels: [Int: Int] = [:]
        return turns.sorted { $0.start < $1.start }.map { turn in
            let label = labels[turn.speaker] ?? labels.count + 1
            labels[turn.speaker] = label
            return DiarizedTurn(start: turn.start, end: turn.end, speaker: label)
        }
    }

    /// The speaker of the turn covering most of `start ..< end`.
    ///
    /// Overlapping speech is not flagged by the C API — it surfaces as turns
    /// whose time ranges intersect — so a chunk can legitimately match several
    /// speakers. Greatest overlap wins; ties go to the earlier turn.
    static func speaker(from start: TimeInterval, to end: TimeInterval, in turns: [DiarizedTurn]) -> Int? {
        guard end > start else { return nil }

        var best: (speaker: Int, overlap: TimeInterval)?
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            guard overlap > 0 else { continue }
            if let current = best, current.overlap >= overlap { continue }
            best = (turn.speaker, overlap)
        }
        return best?.speaker
    }
}

/// Offline (whole-recording) speaker diarization over sherpa-onnx's C API:
/// pyannote segmentation-3.0 for turn boundaries, a speaker-embedding model per
/// turn, then agglomerative clustering. Runs on the `them` stream only — the
/// `me` stream is already a single known speaker.
final class SpeakerDiarizer {
    enum Failure: Error {
        case modelsMissing
        case initializationFailed
    }

    struct Configuration {
        /// Known number of speakers. When > 0 the distance threshold is ignored
        /// entirely, and clustering is markedly more accurate — set it whenever
        /// the participant count is known.
        var speakerCount: Int = 0
        /// Distance threshold used when the speaker count is unknown — higher
        /// merges more eagerly.
        ///
        /// The optimum moves with recording length, because a longer recording
        /// spreads each voice's embeddings wider and needs a more permissive
        /// threshold to keep one person in one cluster. Measured: a 9.5-minute
        /// four-speaker reference needed 0.8 (0.5 gave nine clusters), while a
        /// 100-second three-speaker meeting collapsed to two at 0.7. Hence the
        /// compromise default, overridable while we gather more real audio:
        /// `defaults write com.example.nod diarization.threshold 0.55`.
        var clusteringThreshold: Float = Self.defaultClusteringThreshold
        var minDurationOn: Float = 0.3
        var minDurationOff: Float = 0.5
        var threadCount: Int = 2

        static var defaultClusteringThreshold: Float {
            if let override = UserDefaults.standard.object(forKey: "diarization.threshold") as? Double {
                return Float(override)
            }
            return 0.6
        }
    }

    private let diarizer: OpaquePointer

    /// Builds a diarizer from the models shipped in the app bundle, or `nil`
    /// when they are absent — the feature degrades to source-based labels
    /// rather than failing the meeting.
    static func bundled(speakerCount: Int = 0) -> SpeakerDiarizer? {
        guard let segmentation = Bundle.main.url(forResource: "pyannote_segmentation", withExtension: "onnx"),
              let embedding = Bundle.main.url(forResource: "speaker_embedding", withExtension: "onnx")
        else {
            Log.audio.error("diarization models missing from the bundle")
            return nil
        }
        var configuration = Configuration()
        configuration.speakerCount = speakerCount
        do {
            return try SpeakerDiarizer(
                segmentationModelPath: segmentation.path,
                embeddingModelPath: embedding.path,
                configuration: configuration
            )
        } catch {
            Log.audio.error("diarizer init failed: \(error)")
            return nil
        }
    }

    init(
        segmentationModelPath: String,
        embeddingModelPath: String,
        configuration: Configuration = Configuration()
    ) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: segmentationModelPath),
              files.fileExists(atPath: embeddingModelPath)
        else {
            throw Failure.modelsMissing
        }

        let created = segmentationModelPath.withCString { segmentation in
            embeddingModelPath.withCString { embedding in
                "cpu".withCString { provider -> OpaquePointer? in
                    var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
                    config.segmentation.pyannote.model = segmentation
                    config.segmentation.num_threads = Int32(configuration.threadCount)
                    config.segmentation.provider = provider
                    config.embedding.model = embedding
                    config.embedding.num_threads = Int32(configuration.threadCount)
                    config.embedding.provider = provider
                    config.clustering.num_clusters = Int32(configuration.speakerCount)
                    config.clustering.threshold = configuration.clusteringThreshold
                    config.min_duration_on = configuration.minDurationOn
                    config.min_duration_off = configuration.minDurationOff
                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }

        guard let created else { throw Failure.initializationFailed }
        diarizer = created
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer)
    }

    /// `samples` is the whole recording as 16 kHz mono Float32 in [-1, 1].
    /// The C API takes one contiguous buffer — there is no incremental entry
    /// point — so the caller must hold the full stream until the meeting ends.
    func diarize(_ samples: [Float]) -> [DiarizedTurn] {
        guard !samples.isEmpty else { return [] }

        let result = samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, buffer.baseAddress, Int32(buffer.count))
        }
        guard let result else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0,
              let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
        else {
            return []
        }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }

        return (0 ..< count).map { index in
            let segment = segments[index]
            return DiarizedTurn(
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                speaker: Int(segment.speaker)
            )
        }
    }
}
