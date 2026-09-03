import AVFoundation
import Foundation

/// The microphone, for as long as a key is held: one clip, handed back as the
/// WAV Whisper expects the moment the key is let go.
///
/// Two ways in, one clip out. With no recording running it opens its own
/// engine on the default input. During a recording the meeting already owns
/// the microphone, so the clip is drawn off `AudioCaptureService`'s tap
/// instead — diverted, not copied, so the question never lands in the
/// transcript.
@MainActor
final class HeldQuestionRecorder {
    enum StartFailure: Error {
        case engine(String)
    }

    /// Long enough for any question; short enough that a key pinned under a
    /// book is not an hour of audio on its way to a provider.
    static let maxSeconds: Double = 60
    /// Under this the key was tapped, not held; there is nothing to hear.
    static let minSeconds: Double = 0.3

    private let audioCapture: AudioCaptureService
    private let queue = DispatchQueue(label: "nod.held-question", qos: .userInitiated)
    private var clip: Clip?
    private var engine: AVAudioEngine?
    private var isDiverting = false

    init(audioCapture: AudioCaptureService) {
        self.audioCapture = audioCapture
    }

    func start() throws {
        guard clip == nil else { return }
        let clip = Clip()
        let queue = queue
        let sink: (AVAudioPCMBuffer) -> Void = { buffer in
            guard let copy = Clip.copy(buffer) else { return }
            queue.async { clip.append(copy) }
        }
        if !audioCapture.isCapturingMicrophone {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            engine.prepare()
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in sink(buffer) }
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw StartFailure.engine(error.localizedDescription)
            }
            self.engine = engine
            Log.audio.info("held question: own engine started")
        } else {
            audioCapture.divertMicrophone(to: sink)
            isDiverting = true
            Log.audio.info("held question: diverting the meeting's microphone")
        }
        self.clip = clip
    }

    /// Closes the microphone at once, then hands back the clip so far as
    /// 16 kHz mono WAV — nil when nothing worth sending was heard. The
    /// encoding runs on the clip's own queue: a minute of audio is a million
    /// samples, not something the main thread should stand still for.
    func stop() async -> Data? {
        guard let clip else { return nil }
        self.clip = nil
        if isDiverting {
            audioCapture.divertMicrophone(to: nil)
            isDiverting = false
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        let wav = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: clip.wav()) }
        }
        Log.audio.info("held question: stopped, \(wav?.count ?? 0) bytes")
        return wav
    }

    /// The accumulating clip. Every member is touched on `queue` only, apart
    /// from `copy`, which runs on the tap thread and allocates one buffer.
    private final class Clip: @unchecked Sendable {
        private static let format: AVAudioFormat = {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
                fatalError("16 kHz mono Float32 is a format every macOS can describe")
            }
            return format
        }()

        private var buffers: [AVAudioPCMBuffer] = []
        private var frames = 0
        private var converter: AVAudioConverter?
        private var sourceFormat: AVAudioFormat?

        func append(_ buffer: AVAudioPCMBuffer) {
            guard frames < Int(HeldQuestionRecorder.maxSeconds * Self.format.sampleRate),
                  let normalized = normalize(buffer)
            else { return }
            buffers.append(normalized)
            frames += Int(normalized.frameLength)
        }

        func wav() -> Data? {
            guard Double(frames) >= HeldQuestionRecorder.minSeconds * Self.format.sampleRate else { return nil }
            return WAVEncoder.encode16kHzMono(buffers)
        }

        static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
            copy.frameLength = buffer.frameLength
            let channels = Int(buffer.format.channelCount)
            let count = Int(buffer.frameLength)
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for channel in 0 ..< channels {
                    dst[channel].update(from: src[channel], count: count)
                }
            } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
                for channel in 0 ..< channels {
                    dst[channel].update(from: src[channel], count: count)
                }
            } else {
                return nil
            }
            return copy
        }

        private func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            let target = Self.format
            let inFormat = buffer.format
            if inFormat.sampleRate == target.sampleRate,
               inFormat.channelCount == target.channelCount,
               inFormat.commonFormat == target.commonFormat,
               inFormat.isInterleaved == target.isInterleaved {
                return buffer
            }
            if converter == nil || sourceFormat != inFormat {
                converter = AVAudioConverter(from: inFormat, to: target)
                sourceFormat = inFormat
            }
            guard let converter else { return nil }
            let ratio = target.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0 else { return nil }
            return output
        }
    }
}
