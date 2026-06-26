import AVFoundation
import Foundation

/// Encodes a sequence of mono Float32 PCM buffers into a 16-bit PCM WAV blob
/// suitable for posting to Whisper.
enum WAVEncoder {
    static func encode16kHzMono(_ buffers: [AVAudioPCMBuffer]) -> Data? {
        guard !buffers.isEmpty else { return nil }

        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = channels * bitsPerSample / 8
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)

        var totalFrames = 0
        for b in buffers {
            totalFrames += Int(b.frameLength)
        }
        let pcmByteCount = totalFrames * Int(blockAlign)

        var data = Data()
        data.reserveCapacity(44 + pcmByteCount)

        // RIFF header
        data.append(Data("RIFF".utf8))
        data.append(uint32LE(UInt32(36 + pcmByteCount)))
        data.append(Data("WAVE".utf8))

        // fmt chunk
        data.append(Data("fmt ".utf8))
        data.append(uint32LE(16))            // fmt chunk size
        data.append(uint16LE(1))             // PCM format
        data.append(uint16LE(channels))
        data.append(uint32LE(sampleRate))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))

        // data chunk
        data.append(Data("data".utf8))
        data.append(uint32LE(UInt32(pcmByteCount)))

        // Float32 → Int16 PCM
        var pcm = Data()
        pcm.reserveCapacity(pcmByteCount)
        for buffer in buffers {
            guard let channelData = buffer.floatChannelData?[0] else { continue }
            let count = Int(buffer.frameLength)
            for i in 0 ..< count {
                var sample = channelData[i]
                if sample > 1 { sample = 1 }
                if sample < -1 { sample = -1 }
                var int16 = Int16(sample * 32767.0).littleEndian
                withUnsafeBytes(of: &int16) { pcm.append(contentsOf: $0) }
            }
        }
        data.append(pcm)
        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
}
