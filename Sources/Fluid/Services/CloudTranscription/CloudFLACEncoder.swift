import AVFoundation
import Foundation

nonisolated struct CloudEncodedAudio: Sendable {
    let data: Data
    let format: String
    let mimeType: String
    let fileName: String
    let encodeDuration: TimeInterval

    /// FLAC halves the upload of 16 kHz speech without losing a bit; WAV stays the fallback
    /// because every OpenRouter provider accepts it.
    static func best(samples: [Float]) throws -> CloudEncodedAudio {
        do {
            return try CloudFLACEncoder.encode(samples: samples)
        } catch CloudTranscriptionError.invalidAudio {
            throw CloudTranscriptionError.invalidAudio
        } catch {
            return try self.wav(samples: samples)
        }
    }

    /// WAV for endpoints whose documented input formats do not include FLAC, such as the
    /// chat endpoint's `input_audio`, which lists WAV and MP3.
    static func wav(samples: [Float]) throws -> CloudEncodedAudio {
        let started = ProcessInfo.processInfo.systemUptime
        let wav = try CloudWAVEncoder.encode(samples: samples)
        return CloudEncodedAudio(
            data: wav,
            format: "wav",
            mimeType: "audio/wav",
            fileName: "recording.wav",
            encodeDuration: ProcessInfo.processInfo.systemUptime - started
        )
    }
}

nonisolated enum CloudFLACEncoder {
    static func encode(samples: [Float]) throws -> CloudEncodedAudio {
        guard samples.allSatisfy(\.isFinite) else { throw CloudTranscriptionError.invalidAudio }
        let started = ProcessInfo.processInfo.systemUptime
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fluidvoice-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        // The encoder records the depth of its input, so 16-bit integers are what keep the file at 16 bits.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.int16ChannelData?[0] {
            for (index, sample) in samples.enumerated() {
                let clipped = min(1, max(-1, sample))
                channel[index] = Int16(clipped < 0 ? clipped * 32_768 : clipped * 32_767)
            }
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatFLAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                ],
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: url)
        return CloudEncodedAudio(
            data: data,
            format: "flac",
            mimeType: "audio/flac",
            fileName: "recording.flac",
            encodeDuration: ProcessInfo.processInfo.systemUptime - started
        )
    }
}
