import Foundation
import SpeakerKit

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
    /// Cluster ids are whatever clustering happened to leave behind — a
    /// five-speaker result can come back as `[0, 1, 2, 3, 8]` — so the raw
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
    /// Turns can still intersect after overlapped speech is dropped, so a chunk
    /// can legitimately match several speakers. Greatest overlap wins; ties go
    /// to the earlier turn.
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

/// Offline (whole-recording) speaker diarization over Argmax SpeakerKit —
/// pyannote on Core ML / the Neural Engine. Runs on the `them` stream only: the
/// `me` stream is already a single known speaker.
///
/// Models are pulled from Hugging Face on first use and cached on disk, so the
/// first diarized meeting after a fresh install needs the network; every later
/// one is fully offline. No audio leaves the device either way.
final class SpeakerDiarizer {
    private let speakerKit: SpeakerKit

    /// Distance threshold used when the speaker count is unknown. Nil hands the
    /// decision to SpeakerKit; the override is a field escape hatch:
    /// `defaults write com.example.nod diarization.threshold 0.55`.
    static var clusteringThresholdOverride: Float? {
        (UserDefaults.standard.object(forKey: "diarization.threshold") as? Double).map(Float.init)
    }

    /// Where the Core ML models are cached. Explicit because the SDK otherwise
    /// defaults to `~/Documents/huggingface`, and Nod is not sandboxed — the
    /// models would land in the user's own Documents folder.
    private static var modelCacheDirectory: String? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Nod/models", isDirectory: true)
        .path
    }

    /// `loadModels` compiles the Core ML models and makes them resident. The
    /// finalize path leaves it off (they load lazily on the first `diarize`);
    /// the prewarm turns it on, because that compile is the slow half and the
    /// point of prewarming is to keep it out of the clustering budget.
    static func make(loadModels: Bool = false) async -> SpeakerDiarizer? {
        do {
            // SpeakerKit logs to stdout; ours goes through `Log`, and `print` is
            // banned, so keep the SDK quiet.
            let config = PyannoteConfig(
                downloadBase: Self.modelCacheDirectory,
                download: true,
                load: loadModels,
                verbose: false
            )
            return try await SpeakerDiarizer(speakerKit: SpeakerKit(config))
        } catch {
            Log.audio.error("diarizer init failed: \(error.localizedDescription)")
            return nil
        }
    }

    private init(speakerKit: SpeakerKit) {
        self.speakerKit = speakerKit
    }

    /// `samples` is the whole retained speech as 16 kHz mono Float32 in [-1, 1].
    /// `speakerCount > 0` pins the number of clusters — markedly more accurate
    /// than distance-thresholded clustering, so pass it whenever the roster
    /// knows how many people are on the call.
    func diarize(_ samples: [Float], speakerCount: Int = 0) async -> [DiarizedTurn] {
        guard !samples.isEmpty else { return [] }
        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: speakerCount > 0 ? speakerCount : nil,
            clusterDistanceThreshold: Self.clusteringThresholdOverride
        )
        do {
            let result = try await speakerKit.diarize(audioArray: samples, options: options)
            return result.segments.compactMap { segment in
                // `.multiple` marks overlapped speech: two people at once has no
                // single right answer, so the span stays unlabelled rather than
                // being attributed to whichever id sorts first.
                guard let speaker = segment.speaker.speakerId else { return nil }
                return DiarizedTurn(
                    start: TimeInterval(segment.startTime),
                    end: TimeInterval(segment.endTime),
                    speaker: speaker
                )
            }
        } catch {
            Log.audio.error("diarization failed: \(error.localizedDescription)")
            return []
        }
    }
}
