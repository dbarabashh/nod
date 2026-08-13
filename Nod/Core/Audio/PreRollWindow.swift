import Foundation

/// A rolling window over the audio already handed to the VAD, so a segment can
/// be sent with the moment *before* its onset attached.
///
/// Silero only calls a frame speech once its probability crosses the threshold,
/// a window or two after the word began — so the segment it returns starts
/// mid-attack and the decoder has to guess the consonant it never heard ("там на
/// проді все ок" came back as "там напродів совок"). Re-attaching the audio just
/// before the onset gives the word its beginning back.
///
/// Two sizes, and conflating them is what broke this type's first version:
///
/// - `leadInSamples` is how much gets prepended.
/// - `retainedSamples` is how far back the window can still *reach*, which has
///   to be far larger. A segment is drained only once the speech has **ended**,
///   plus the silence that closes it, so by then its onset is a whole utterance
///   behind the write head. Retain only the lead-in and every onset has already
///   rolled out: `leadIn` returns nothing for every segment longer than the
///   lead-in itself, and the padding silently never happens.
struct PreRollWindow {
    /// Absolute index of `samples.first` in the stream fed to the VAD — the same
    /// clock a segment's `start` is expressed in.
    private(set) var start = 0
    private(set) var samples: [Float] = []

    let retainedSamples: Int
    let leadInSamples: Int

    init(retaining retainedSamples: Int, leadIn leadInSamples: Int) {
        self.retainedSamples = max(0, retainedSamples)
        self.leadInSamples = max(0, min(leadInSamples, retainedSamples))
    }

    /// Feed the same samples, in the same order, as the VAD is given. A skipped
    /// or reordered buffer misaligns the window against the sample clock.
    mutating func append(_ incoming: UnsafeBufferPointer<Float>, startingAt startSample: Int) {
        if samples.isEmpty { start = startSample }
        samples.append(contentsOf: incoming)
        let excess = samples.count - retainedSamples
        guard excess > 0 else { return }
        samples.removeFirst(excess)
        start += excess
    }

    /// The samples immediately before `sampleIndex`, at most `leadInSamples` of
    /// them. Empty at the opening of a stream, and for an onset older than the
    /// window still holds — a segment that long loses nothing measurable by
    /// going unpadded.
    func leadIn(before sampleIndex: Int) -> [Float] {
        let offset = sampleIndex - start
        guard offset > 0, offset <= samples.count else { return [] }
        return Array(samples[..<offset].suffix(leadInSamples))
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        start = 0
    }
}
