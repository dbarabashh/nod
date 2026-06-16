import Foundation

// Swift wrapper over sherpa-onnx's C speaker-embedding API, plus a pure-Swift
// clusterer that turns those embeddings into speaker labels. The C symbols come
// from the same vendored sherpa-onnx.xcframework that already provides the VAD
// (see SherpaVAD.swift) — the diarization code is statically linked, only the
// embedding model is an extra resource.
//
// The extractor maps one VAD speech segment (16 kHz mono Float32, already what
// the VAD hands back) to a fixed-length voiceprint vector. SpeakerClusterer
// groups those vectors: greedily during the meeting for live "Them N" labels,
// and globally once at the end to fix early mislabels before the summary runs.

func sherpaSpeakerEmbeddingExtractorConfig(
    model: String,
    numThreads: Int = 1,
    provider: String = "cpu",
    debug: Int = 0
) -> SherpaOnnxSpeakerEmbeddingExtractorConfig {
    SherpaOnnxSpeakerEmbeddingExtractorConfig(
        model: toCPointer(model),
        num_threads: Int32(numThreads),
        debug: Int32(debug),
        provider: toCPointer(provider)
    )
}

/// Computes a speaker-embedding vector from a VAD speech segment. One instance
/// is reused across segments; each `compute` creates and destroys its own
/// stream, so it's safe to call serially per segment on the transcriber queue.
final class SherpaSpeakerEmbeddingExtractor {
    private let extractor: OpaquePointer
    let dim: Int

    init?(model: String) {
        var config = sherpaSpeakerEmbeddingExtractorConfig(model: model)
        guard let extractor = withUnsafePointer(to: &config, {
            SherpaOnnxCreateSpeakerEmbeddingExtractor($0)
        }) else { return nil }
        self.extractor = extractor
        dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor)
    }

    /// 16 kHz mono Float32 samples → raw embedding vector (`dim` elements), or
    /// nil if the clip was too short for the model to produce one.
    func compute(samples: [Float], sampleRate: Int32 = 16_000) -> [Float]? {
        guard !samples.isEmpty,
              let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor)
        else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)

        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) == 1,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream)
        else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        return Array(UnsafeBufferPointer(start: v, count: dim))
    }
}

/// Speaker clustering over voiceprint embeddings using cosine similarity.
///
/// `assign` is the live path: each new segment greedily matches the nearest
/// known speaker (folding into its running mean) or opens a new one. `cluster`
/// is the offline path: it re-derives globally consistent labels from every
/// embedding once the meeting ends — greedy online assignment drifts (the same
/// person can spawn a second label after a long gap, or two quiet speakers
/// merge), and a global pass over the full set corrects that before the summary
/// reads the transcript.
final class SpeakerClusterer {
    /// Cosine similarity at/above which two segments are the same speaker.
    /// CAM++ embeddings put same-speaker pairs above this and different speakers
    /// below. Set below the textbook 0.5: meeting audio captured through system
    /// playback (codec loss) and short utterances push same-speaker pairs down,
    /// so too high a bar over-splits one person into several "speakers".
    static let defaultThreshold: Float = 0.40

    private let threshold: Float
    private var centroids: [[Float]] = []
    private var counts: [Int] = []

    init(threshold: Float = SpeakerClusterer.defaultThreshold) {
        self.threshold = threshold
    }

    var speakerCount: Int {
        centroids.count
    }

    /// Drop all learned speakers — call when a new meeting starts so voices
    /// don't carry over from the previous one.
    func reset() {
        centroids.removeAll()
        counts.removeAll()
    }

    /// Nearest speaker by cosine similarity, updating that speaker's running
    /// mean; opens a new speaker when nothing clears the threshold. Returns the
    /// speaker index.
    func assign(_ embedding: [Float]) -> Int {
        let v = Self.normalized(embedding)
        var best = -1
        var bestSim: Float = -1
        for (i, c) in centroids.enumerated() {
            let sim = Self.dot(v, c)
            if sim > bestSim { bestSim = sim; best = i }
        }
        if best >= 0, bestSim >= threshold {
            let n = counts[best]
            var merged = centroids[best]
            for k in merged.indices {
                merged[k] = (merged[k] * Float(n) + v[k]) / Float(n + 1)
            }
            centroids[best] = Self.normalized(merged)
            counts[best] = n + 1
            return best
        }
        centroids.append(v)
        counts.append(1)
        return centroids.count - 1
    }

    /// Average-linkage agglomerative clustering over all embeddings. Returns one
    /// label per input (index-aligned), numbered by first appearance so "Them 1"
    /// is the first speaker heard. Merges the two closest clusters until no pair
    /// clears `threshold`.
    static func cluster(_ embeddings: [[Float]], threshold: Float = SpeakerClusterer.defaultThreshold) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        let vs = embeddings.map { normalized($0) }
        var clusters: [[Int]] = (0 ..< n).map { [$0] }

        while clusters.count > 1 {
            var bestI = -1, bestJ = -1
            var bestSim = threshold
            for i in 0 ..< clusters.count {
                for j in (i + 1) ..< clusters.count {
                    let sim = averageLinkage(clusters[i], clusters[j], vs)
                    if sim >= bestSim { bestSim = sim; bestI = i; bestJ = j }
                }
            }
            guard bestI >= 0 else { break }
            clusters[bestI].append(contentsOf: clusters[bestJ])
            clusters.remove(at: bestJ)
        }

        var labels = [Int](repeating: 0, count: n)
        for (label, members) in clusters.enumerated() {
            for idx in members {
                labels[idx] = label
            }
        }
        return Self.renumberByFirstAppearance(labels)
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

    private static func averageLinkage(_ a: [Int], _ b: [Int], _ vs: [[Float]]) -> Float {
        var sum: Float = 0
        for i in a {
            for j in b {
                sum += dot(vs[i], vs[j])
            }
        }
        return sum / Float(a.count * b.count)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v {
            norm += x * x
        }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0 ..< min(a.count, b.count) {
            s += a[i] * b[i]
        }
        return s
    }
}
