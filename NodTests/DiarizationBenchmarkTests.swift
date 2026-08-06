import AVFoundation
import XCTest
@testable import Nod

/// Replays the real diarizer over real meetings and prints what it got wrong.
///
/// It runs the pipeline as it actually runs: clustering over the concatenated
/// speech `DiarizationBuffer` retains, then `DiarizationBuffer.speakers(for:…)`
/// mapping turns back onto spans. Feeding it a recording of the raw stream
/// instead would measure a pipeline that does not exist — the diarizer never
/// sees silence and never sees wall-clock time.
///
/// It skips unless `NOD_DIARIZE_FIXTURES` names a directory, and that is not a
/// convenience: fixtures are recordings of real meetings with real people, so
/// they never go in the repository. CI never runs this; a person does, against
/// their own calls, on the machine those calls are already on.
///
/// It exists because the decision it informs cannot be read out of a benchmark
/// table. Published DER numbers come from AMI and DIHARD — close-talking
/// microphones in quiet rooms. Our input has already been through a conferencing
/// codec at a low bitrate, noise suppression and automatic gain control, all
/// three tuned to keep speech intelligible rather than to keep voices apart. A
/// pipeline can win on AMI and lose here.
///
/// See `docs/build-setup.md` for capturing a fixture and writing its truth.
final class DiarizationBenchmarkTests: XCTestCase {
    /// The knobs that exist today. `numberOfSpeakers` is the interesting one:
    /// the calendar can now supply it, and whether that beats a well-chosen
    /// threshold decides how much of this problem EventKit already solves.
    private static let thresholds: [Float?] = [nil, 0.45, 0.55, 0.65, 0.75]

    func testDiarizationAcrossFixtures() async throws {
        guard let root = fixtureDirectory() else {
            throw XCTSkip("Set NOD_DIARIZE_FIXTURES to a directory of fixtures.")
        }
        let fixtures = try Self.fixtures(in: root)
        guard !fixtures.isEmpty else {
            throw XCTSkip("No <name>.wav + <name>.spans.json + <name>.truth.json sets in \(root.path).")
        }
        guard let diarizer = await SpeakerDiarizer.make(loadModels: true) else {
            return XCTFail("Could not load the diarization models.")
        }

        for fixture in fixtures {
            let samples = try Self.samples(at: fixture.audio)
            let manifest = try Self.manifest(at: fixture.spans)
            let truth = try Self.truth(at: fixture.truth, spans: manifest.spans)
            let speakers = Set(truth.values).count

            print("\n── \(fixture.name) — \(Self.clock(Double(samples.count) / 16000)) of speech, "
                + "\(manifest.spans.count) line(s), \(speakers) speaker(s)")

            // Pinned first: it is what a meeting with a calendar entry actually
            // runs, so everything below is read against it.
            await run(
                "pinned to \(speakers)",
                diarizer: diarizer,
                samples: samples,
                speakerCount: speakers,
                manifest: manifest,
                truth: truth
            )

            for threshold in Self.thresholds {
                UserDefaults.standard.set(threshold.map { Double($0) }, forKey: "diarization.threshold")
                defer { UserDefaults.standard.removeObject(forKey: "diarization.threshold") }
                let label = threshold.map { String(format: "threshold %.2f", $0) } ?? "library default"
                await run(
                    label,
                    diarizer: diarizer,
                    samples: samples,
                    speakerCount: 0,
                    manifest: manifest,
                    truth: truth
                )
            }
        }
    }

    private func run(
        _ label: String,
        diarizer: SpeakerDiarizer,
        samples: [Float],
        speakerCount: Int,
        manifest: Manifest,
        truth: [UUID: String]
    ) async {
        let turns = await SpeakerAssignment.normalized(diarizer.diarize(samples, speakerCount: speakerCount))
        let hypothesis = DiarizationBuffer.speakers(
            for: manifest.spans,
            in: turns,
            sampleRate: manifest.sampleRate
        )
        let score = DiarizationScorer.score(hypothesis: hypothesis, truth: truth)
        print("   \(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(score.summary)")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let name: String
        let audio: URL
        let spans: URL
        let truth: URL
    }

    struct Manifest {
        let sampleRate: Int
        let spans: [DiarizationBuffer.Span]
    }

    private func fixtureDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["NOD_DIARIZE_FIXTURES"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func fixtures(in root: URL) throws -> [Fixture] {
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio in
                let base = audio.deletingPathExtension()
                let spans = base.appendingPathExtension("spans.json")
                let truth = base.appendingPathExtension("truth.json")
                let exists = FileManager.default.fileExists(atPath:)
                guard exists(spans.path), exists(truth.path) else { return nil }
                return Fixture(name: base.lastPathComponent, audio: audio, spans: spans, truth: truth)
            }
    }

    /// The span boundaries the app wrote alongside the audio — the same sample
    /// offsets the live pipeline resolved speakers against.
    private static func manifest(at url: URL) throws -> Manifest {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let id: String
                let start: String
                let end: String
            }

            let sampleRate: Int
            let spans: [Entry]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        let rate = Double(payload.sampleRate)
        let spans = payload.spans.compactMap { entry -> DiarizationBuffer.Span? in
            guard let id = UUID(uuidString: entry.id),
                  let start = Double(entry.start),
                  let end = Double(entry.end)
            else { return nil }
            return DiarizationBuffer.Span(
                id: id,
                startSample: Int(start * rate),
                endSample: Int(end * rate)
            )
        }
        return Manifest(sampleRate: payload.sampleRate, spans: spans)
    }

    /// Who said each line. Keyed by line number as it appears in the transcript
    /// — 1-based, matching the span order — because a person writing this is
    /// reading a transcript, not copying UUIDs. Lines left out are not scored.
    private static func truth(at url: URL, spans: [DiarizationBuffer.Span]) throws -> [UUID: String] {
        struct Payload: Decodable {
            let speakers: [String: String]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        var truth: [UUID: String] = [:]
        for (key, name) in payload.speakers {
            guard let line = Int(key), line >= 1, line <= spans.count else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            truth[spans[line - 1].id] = trimmed
        }
        return truth
    }

    /// The fixture as the diarizer receives it: 16 kHz mono Float32.
    private static func samples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
