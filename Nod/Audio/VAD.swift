import AVFoundation

/// Voice-activity gate applied to each chunk before it's sent to Whisper.
/// Whisper hallucinates ("Thanks for watching!") on near-silence, so chunks
/// below the gate are dropped at the source.
///
/// Gates are asymmetric per source. A silent mic reliably triggers
/// hallucinations, so [Me] keeps a strict peak gate. System audio (post-mix)
/// can be much quieter than the mic without being silent — low-volume meeting
/// playback, soft-spoken remote participants — so [Them] drops the peak gate
/// and adds an RMS check: the chunk must both peak above the noise floor AND
/// show sustained energy consistent with speech, not an isolated spike or hiss.
struct VAD {
    let peakGate: Float
    let rmsGate: Float

    init(source: TranscriptSource) {
        switch source {
        case .me:
            peakGate = 0.05
            rmsGate = 0
        case .them:
            peakGate = 0.015
            rmsGate = 0.005
        }
    }

    func isSilent(peak: Float, rms: Float) -> Bool {
        peak < peakGate || rms < rmsGate
    }

    /// Single-pass peak amplitude + RMS over a chunk's worth of buffers.
    /// RMS is computed against actual sample count, so very short tail
    /// buffers don't get an inflated reading.
    static func peakAndRMS(_ buffers: [AVAudioPCMBuffer]) -> (peak: Float, rms: Float) {
        var peak: Float = 0
        var sumSquares: Double = 0
        var count = 0
        for b in buffers {
            guard let ch = b.floatChannelData?[0] else { continue }
            let n = Int(b.frameLength)
            for i in 0 ..< n {
                let s = ch[i]
                let a = abs(s)
                if a > peak { peak = a }
                sumSquares += Double(s) * Double(s)
            }
            count += n
        }
        let rms: Float = count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
        return (peak, rms)
    }
}
