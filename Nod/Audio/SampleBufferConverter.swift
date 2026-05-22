import Foundation
import AVFoundation
import CoreMedia

enum SampleBufferConverter {
    /// Converts a CMSampleBuffer (from SCStream audio output) into an AVAudioPCMBuffer
    /// that SFSpeechRecognizer can consume.
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    /// Downmixes stereo (or N-channel) audio to mono. SFSpeechRecognizer requires
    /// single-channel input.
    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.channelCount == 1 { return buffer }
        let inputFormat = buffer.format
        guard let monoFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
              let converter = AVAudioConverter(from: inputFormat, to: monoFormat),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity)
        else {
            return nil
        }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return nil }
        return output
    }
}
