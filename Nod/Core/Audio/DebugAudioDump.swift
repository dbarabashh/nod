#if DEBUG
    import AVFoundation
    import Foundation

    /// Writes a session's normalized 16 kHz mono stream to a WAV so diarization and
    /// VAD changes can be replayed offline against real meeting audio.
    ///
    /// DEBUG-only and off unless the `debug.audio.dump` default is set: shipping
    /// builds never write audio to durable storage, which `docs/policies/security.md`
    /// and the spoken consent line both state as an absolute.
    final class DebugAudioDump {
        static let defaultsKey = "debug.audio.dump"

        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }

        private let label: String
        private var samples: [Float] = []

        init(label: String) {
            self.label = label
        }

        func append(_ channel: UnsafePointer<Float>, count: Int) {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }

        @discardableResult
        func finish() -> URL? {
            defer { samples.removeAll() }
            guard !samples.isEmpty else { return nil }

            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
            guard let format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0]
            else {
                Log.audio.error("debug dump: could not build a 16 kHz buffer")
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            channel.update(from: samples, count: samples.count)

            guard let wav = WAVEncoder.encode16kHzMono([buffer]) else {
                Log.audio.error("debug dump: WAV encoding failed")
                return nil
            }

            do {
                let directory = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("Nod/debug-audio", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = directory.appendingPathComponent("\(stamp)-\(label).wav")
                try wav.write(to: url)
                let seconds = Double(buffer.frameLength) / 16_000
                Log.audio.info("debug dump: wrote \(String(format: "%.1f", seconds))s to \(url.path)")
                return url
            } catch {
                Log.audio.error("debug dump: write failed — \(error.localizedDescription)")
                return nil
            }
        }
    }
#endif
