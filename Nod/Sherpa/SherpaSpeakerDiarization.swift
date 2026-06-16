import Foundation

// Offline speaker diarization over sherpa-onnx's pyannote-segmentation +
// speaker-embedding pipeline. Unlike per-utterance embedding clustering, the
// pyannote segmentation model resolves speaker-homogeneous regions (including
// overlap) before embedding, so clustering is far more robust on many-speaker
// calls captured through one mixed system-audio stream. Runs once at meeting
// end on the spooled speech. C symbols come from the vendored
// sherpa-onnx.xcframework via the bridging header.

/// One speaker-labelled time range (seconds) from the diarizer.
struct DiarizedRange {
    let start: Float
    let end: Float
    let speaker: Int
}

/// Sample span of one spooled utterance, used to map diarization output back to
/// our Whisper segments. `start`/`count` are indices into the spooled audio.
struct SegmentRange {
    let start: Int
    let count: Int
}

/// Wraps `SherpaOnnxOfflineSpeakerDiarization`. `@unchecked Sendable` so the
/// heavy `process` call can run off the main actor; the opaque handle is only
/// touched from a single diarization call at meeting end.
final class SherpaSpeakerDiarization: @unchecked Sendable {
    private let sd: OpaquePointer

    /// Threshold for the built-in FastClustering (number of speakers unknown →
    /// threshold mode). Tuned per pyannote-3.0 + CAM++ embeddings; lower merges
    /// more speakers, higher splits more.
    static let defaultClusteringThreshold: Float = 0.5

    init?(
        segmentationModel: String,
        embeddingModel: String,
        clusteringThreshold: Float = SherpaSpeakerDiarization.defaultClusteringThreshold
    ) {
        // Diarization runs once at meeting end over the whole spool — give it
        // several threads so a long (10-minute) meeting finishes in seconds, not
        // minutes. Capped to leave cores for the rest of the app.
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = toCPointer(segmentationModel)
        config.segmentation.num_threads = threads
        config.segmentation.provider = toCPointer("cpu")
        config.embedding.model = toCPointer(embeddingModel)
        config.embedding.num_threads = threads
        config.embedding.provider = toCPointer("cpu")
        // num_clusters <= 0 → cluster by threshold (we don't know the count).
        config.clustering.num_clusters = -1
        config.clustering.threshold = clusteringThreshold
        config.min_duration_on = 0.3
        config.min_duration_off = 0.5

        guard let sd = withUnsafePointer(to: &config, {
            SherpaOnnxCreateOfflineSpeakerDiarization($0)
        }) else { return nil }
        self.sd = sd
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(sd)
    }

    var sampleRate: Int {
        Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(sd))
    }

    /// Diarize 16 kHz mono Float32 audio into speaker-labelled ranges, sorted by
    /// start time. Empty if the model produced nothing.
    func process(_ samples: [Float]) -> [DiarizedRange] {
        guard !samples.isEmpty else { return [] }
        guard let result = samples.withUnsafeBufferPointer({ buf in
            SherpaOnnxOfflineSpeakerDiarizationProcess(sd, buf.baseAddress, Int32(buf.count))
        }) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0,
              let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
        else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }

        return (0 ..< count).map { i in
            let seg = segments[i]
            return DiarizedRange(start: seg.start, end: seg.end, speaker: Int(seg.speaker))
        }
    }
}

enum SpeakerMapping {
    /// Assign each spooled utterance the diarizer speaker covering most of its
    /// span, then renumber by first appearance so "Them 1" is the first speaker
    /// heard. Returns one label per `segmentRanges` entry (index == segment
    /// index); utterances with no overlapping diarized range inherit the
    /// previous speaker.
    static func assign(segmentRanges: [SegmentRange], diarization: [DiarizedRange], sampleRate: Int) -> [Int] {
        guard !segmentRanges.isEmpty, sampleRate > 0 else { return [] }
        var labels = [Int](repeating: -1, count: segmentRanges.count)
        for (i, seg) in segmentRanges.enumerated() {
            let segStart = Float(seg.start) / Float(sampleRate)
            let segEnd = Float(seg.start + seg.count) / Float(sampleRate)
            var best = -1
            var bestOverlap: Float = 0
            for range in diarization {
                let overlap = min(segEnd, range.end) - max(segStart, range.start)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best = range.speaker
                }
            }
            labels[i] = best
        }
        // Carry the last known speaker onto utterances the diarizer didn't cover.
        var last = 0
        for i in labels.indices {
            if labels[i] < 0 { labels[i] = last } else { last = labels[i] }
        }
        return renumberByFirstAppearance(labels)
    }

    private static func renumberByFirstAppearance(_ labels: [Int]) -> [Int] {
        var order: [Int: Int] = [:]
        var next = 0
        return labels.map { label in
            if let mapped = order[label] { return mapped }
            order[label] = next
            defer { next += 1 }
            return next
        }
    }
}
