import Foundation
@testable import Nod

/// How well a diarization run matched what actually happened, measured where
/// the user meets it: one speaker per transcript line.
///
/// Lives in the test target, not the app: it is a measuring instrument, and the
/// shipped binary has no use for it.
///
/// Deliberately not frame-level DER. The pipeline never sees silence — the VAD
/// hands `DiarizationBuffer` speech only, and clustering runs on that
/// concatenated timeline — so the missed-speech and false-alarm halves of DER
/// measure a stage that is not there, while the half that matters gets diluted
/// into a single number. What ships is `[UUID: Int]`, one cluster per line, and
/// a wrong line is what puts somebody else's words under a colleague's name in a
/// summary that then gets shared.
///
/// Scoring here also makes the ground truth cheap, which is the difference
/// between a harness that gets used and one that does not: naming the speaker of
/// each transcript line is reading, where drawing turn boundaries on a waveform
/// is an afternoon.
struct DiarizationScore {
    /// Lines given to the wrong person, as a share of all labelled truth.
    /// The number to watch.
    let confusion: Double
    /// Lines the diarizer declined to attribute — spans it found no turn for, or
    /// that hold more than one voice. Honest, not free: an unlabelled line shows
    /// as `Them` rather than as a person.
    let unattributed: Double
    /// How many voices were found, minus how many there were. Positive is the
    /// phantom-speaker case that got diarization rolled back once; negative is
    /// two people merged into one.
    let speakerCountError: Int
    let referenceSpeakers: Int
    let hypothesisSpeakers: Int
    let lines: Int
    /// The mapping the score was computed under, for reading a failure back.
    let mapping: [Int: String]

    /// Lines that came out right. The one number worth quoting to somebody who
    /// did not read the rest.
    var accuracy: Double {
        1 - confusion - unattributed
    }

    var summary: String {
        String(
            format: "%.1f%% correct  (wrong %.1f%%, unattributed %.1f%%)  voices %d/%d over %d line(s)",
            accuracy * 100, confusion * 100, unattributed * 100,
            hypothesisSpeakers, referenceSpeakers, lines
        )
    }
}

enum DiarizationScorer {
    /// `truth` names the speaker of each line; `hypothesis` is what the pipeline
    /// returned. Lines absent from `truth` are not scored — a fixture may leave
    /// crosstalk unlabelled rather than inventing an answer for it.
    static func score(hypothesis: [UUID: Int], truth: [UUID: String]) -> DiarizationScore {
        let mapping = optimalMapping(hypothesis: hypothesis, truth: truth)
        let speakers = Set(truth.values)
        let clusters = Set(hypothesis.values)

        var wrong = 0
        var unattributed = 0
        for (line, speaker) in truth {
            switch hypothesis[line] {
            case nil: unattributed += 1
            case let cluster? where mapping[cluster] != speaker: wrong += 1
            default: break
            }
        }

        let total = max(truth.count, 1)
        return DiarizationScore(
            confusion: Double(wrong) / Double(total),
            unattributed: Double(unattributed) / Double(total),
            speakerCountError: clusters.count - speakers.count,
            referenceSpeakers: speakers.count,
            hypothesisSpeakers: clusters.count,
            lines: truth.count,
            mapping: mapping
        )
    }

    /// Which cluster is which person, chosen to flatter the run as much as the
    /// evidence allows.
    ///
    /// A cluster id is arbitrary — "Speaker 2" makes no claim about who that is —
    /// so scoring against raw ids would report a perfect run that happened to
    /// number people differently as a total failure. Pairs are taken in order of
    /// how many lines they share, each cluster and each person used once. Greedy
    /// rather than a full assignment search: with the handful of speakers a
    /// meeting has the two agree, and a scorer nobody can read is a scorer
    /// nobody trusts.
    static func optimalMapping(hypothesis: [UUID: Int], truth: [UUID: String]) -> [Int: String] {
        var shared: [Int: [String: Int]] = [:]
        for (line, speaker) in truth {
            guard let cluster = hypothesis[line] else { continue }
            shared[cluster, default: [:]][speaker, default: 0] += 1
        }

        let ranked = shared
            .flatMap { cluster, counts in counts.map { (cluster: cluster, speaker: $0.key, lines: $0.value) } }
            .sorted {
                $0.lines == $1.lines
                    ? ($0.cluster, $0.speaker) < ($1.cluster, $1.speaker)
                    : $0.lines > $1.lines
            }

        var mapping: [Int: String] = [:]
        var claimed = Set<String>()
        for pair in ranked {
            guard mapping[pair.cluster] == nil, !claimed.contains(pair.speaker) else { continue }
            mapping[pair.cluster] = pair.speaker
            claimed.insert(pair.speaker)
        }
        return mapping
    }
}
