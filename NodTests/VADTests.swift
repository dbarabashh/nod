import AVFoundation
import XCTest
@testable import Nod

final class VADTests: XCTestCase {
    func testMeUsesStrictPeakGateAndNoRMSGate() {
        let vad = VAD(source: .me)
        XCTAssertEqual(vad.peakGate, 0.05)
        XCTAssertEqual(vad.rmsGate, 0)
    }

    func testThemUsesLowerPeakGateAndRMSGate() {
        let vad = VAD(source: .them)
        XCTAssertEqual(vad.peakGate, 0.015)
        XCTAssertEqual(vad.rmsGate, 0.005)
    }

    func testMeGatesQuietMicAsSilent() {
        let vad = VAD(source: .me)
        XCTAssertTrue(vad.isSilent(peak: 0.04, rms: 0.04))
        XCTAssertFalse(vad.isSilent(peak: 0.06, rms: 0.0))
    }

    func testMeIgnoresRMSEntirely() {
        let vad = VAD(source: .me)
        XCTAssertFalse(vad.isSilent(peak: 0.05, rms: 0))
    }

    func testThemPassesQuietButSustainedSpeech() {
        let vad = VAD(source: .them)
        XCTAssertFalse(vad.isSilent(peak: 0.02, rms: 0.006))
    }

    func testThemGatesIsolatedSpikeWithLowRMS() {
        let vad = VAD(source: .them)
        XCTAssertTrue(vad.isSilent(peak: 0.5, rms: 0.001))
    }

    func testThemGatesLowPeakEvenWithEnergy() {
        let vad = VAD(source: .them)
        XCTAssertTrue(vad.isSilent(peak: 0.01, rms: 0.01))
    }

    func testPeakAndRMSOfSilenceIsZero() {
        let buffer = makeBuffer([Float](repeating: 0, count: 1000))
        let (peak, rms) = VAD.peakAndRMS([buffer])
        XCTAssertEqual(peak, 0)
        XCTAssertEqual(rms, 0)
    }

    func testPeakAndRMSOfConstantSignal() {
        let buffer = makeBuffer([Float](repeating: 0.5, count: 1000))
        let (peak, rms) = VAD.peakAndRMS([buffer])
        XCTAssertEqual(peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(rms, 0.5, accuracy: 1e-6)
    }

    func testPeakTracksAbsoluteMaximum() {
        let buffer = makeBuffer([0.1, -0.8, 0.3, -0.2])
        let (peak, _) = VAD.peakAndRMS([buffer])
        XCTAssertEqual(peak, 0.8, accuracy: 1e-6)
    }

    func testRMSUsesActualSampleCountAcrossBuffers() {
        let loud = makeBuffer([1.0, 1.0])
        let quiet = makeBuffer([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        let (_, rms) = VAD.peakAndRMS([loud, quiet])
        XCTAssertEqual(rms, (2.0 / 8.0).squareRoot(), accuracy: 1e-6)
    }

    func testEmptyBufferListIsSilent() {
        let (peak, rms) = VAD.peakAndRMS([])
        XCTAssertEqual(peak, 0)
        XCTAssertEqual(rms, 0)
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() {
            buffer.floatChannelData![0][i] = s
        }
        return buffer
    }
}
