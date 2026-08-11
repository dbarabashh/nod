import Foundation

/// Enforces the segment ceiling the VAD only advises. sherpa's
/// `max_speech_duration` is documented as a nudge — past it the detector
/// "temporarily uses a higher threshold to encourage a split" — so a speaker who
/// never pauses keeps growing one segment (measured in production: p90 17s,
/// p99 27s, max 97.7s). Whisper decodes in 30s windows and conditions on the
/// prompt in the first one only, so an oversized segment loses the prompt for
/// its tail and freezes the live transcript until the speaker finally pauses.
enum SpeechSegmentSplit {
    static let maxSamples = 25 * 16_000
    /// How far back from the ceiling to hunt for the quietest cut point.
    static let searchSamples = 5 * 16_000
    static let windowSamples = 1_600

    /// Cut at the quietest window in the band before each ceiling rather than
    /// blindly at the boundary — a mid-word cut is what the VAD design exists to
    /// avoid, and by this point the VAD has already failed to find a pause.
    /// Segments within the ceiling pass through whole.
    static func pieces(
        of samples: [Float],
        maxSamples: Int = maxSamples,
        searchSamples: Int = searchSamples,
        windowSamples: Int = windowSamples
    ) -> [ArraySlice<Float>] {
        guard maxSamples > 0, samples.count > maxSamples else { return [samples[...]] }

        var pieces: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > maxSamples {
            let ceiling = start + maxSamples
            let searchStart = max(start + 1, ceiling - searchSamples)
            let cut = quietestCut(in: samples, from: searchStart, to: ceiling, windowSamples: windowSamples)
            pieces.append(samples[start ..< cut])
            start = cut
        }
        pieces.append(samples[start...])
        return pieces
    }

    private static func quietestCut(in samples: [Float], from: Int, to: Int, windowSamples: Int) -> Int {
        guard to - from > windowSamples else { return to }

        var bestCut = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var windowStart = from
        while windowStart + windowSamples <= to {
            var energy: Float = 0
            for offset in windowStart ..< windowStart + windowSamples {
                energy += abs(samples[offset])
            }
            // `<=` so a tie resolves to the latest window: with no real pause
            // anywhere in the band (steady speech, music) this cuts at the
            // ceiling instead of the band's start, which would shorten every
            // piece by the whole search width and cost extra Whisper calls.
            if energy <= bestEnergy {
                bestEnergy = energy
                bestCut = windowStart + windowSamples / 2
            }
            windowStart += windowSamples
        }
        return bestCut
    }
}
