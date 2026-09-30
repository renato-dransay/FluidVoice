import AVFoundation

/// Synthesizes the short spoken clip used to check a model's word timings. The clip is generated
/// on this Mac when the check runs, so the app ships no recording and the check sends no user audio.
nonisolated enum CloudWordTimingCheckSpeech {
    static let phrase = "The quick brown fox jumps over the lazy dog near the quiet river bank."
    private static let timeout: TimeInterval = 20
    private static let sampleRate = 16_000.0

    /// Mono 16 kHz samples of the spoken phrase, matching what the transcription client uploads.
    static func samples() async throws -> [Float] {
        let collector = Collector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.start(continuation)
        }
    }

    /// Hands the converter one buffer, then reports that no more input is ready. The converter
    /// calls back synchronously inside `convert`, so the buffer never crosses threads.
    private final class PendingInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { self.buffer = nil }
            return self.buffer
        }
    }

    /// The synthesizer delivers buffers on its own queue, so all state is lock-protected.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let synthesizer = AVSpeechSynthesizer()
        private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CloudWordTimingCheckSpeech.sampleRate, channels: 1, interleaved: false)
        private var converter: AVAudioConverter?
        private var samples: [Float] = []
        private var continuation: CheckedContinuation<[Float], Error>?

        func start(_ continuation: CheckedContinuation<[Float], Error>) {
            self.lock.withLock { self.continuation = continuation }
            let utterance = AVSpeechUtterance(string: CloudWordTimingCheckSpeech.phrase)
            // A missing English voice falls back to the system voice, which still speaks the phrase.
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            self.synthesizer.write(utterance) { [weak self] buffer in self?.receive(buffer) }
            // The pending timeout is the only strong reference, so it keeps the synthesizer alive
            // while it speaks and releases it afterwards without a retain cycle.
            DispatchQueue.global().asyncAfter(deadline: .now() + CloudWordTimingCheckSpeech.timeout) {
                self.finish(failed: true)
            }
        }

        private func receive(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return self.finish(failed: true) }
            // The synthesizer marks the end of the utterance with an empty buffer.
            guard pcm.frameLength > 0 else { return self.finish(failed: false) }
            let converted: Bool = self.lock.withLock {
                guard self.continuation != nil, let target = self.target else { return false }
                if self.converter == nil { self.converter = AVAudioConverter(from: pcm.format, to: target) }
                let capacity = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 64
                guard let converter = self.converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return false }
                let input = PendingInput(pcm)
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    let next = input.take()
                    status.pointee = next == nil ? .noDataNow : .haveData
                    return next
                }
                guard error == nil, let channel = output.floatChannelData?[0] else { return false }
                self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                return true
            }
            if !converted { self.finish(failed: true) }
        }

        private func finish(failed: Bool) {
            let (continuation, samples) = self.lock.withLock {
                defer { self.continuation = nil }
                return (self.continuation, self.samples)
            }
            // Under a second of audio cannot hold the phrase, so treat it as a failed synthesis.
            if failed || Double(samples.count) < CloudWordTimingCheckSpeech.sampleRate {
                continuation?.resume(throwing: CloudTranscriptionError.wordTimingCheckSpeechUnavailable)
            } else {
                continuation?.resume(returning: samples)
            }
        }
    }
}
