import AVFoundation
import Foundation
import os

/// Resamples captured meeting audio to the 16 kHz mono Float32 every live caption engine reads.
/// Keeps one `AVAudioConverter` per source format; owned by a single engine, so not Sendable.
final nonisolated class MeetingLiveAudioConverter {
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        // Fixed Float32 PCM format with positive sample rate and channels is valid by construction.
        // swiftlint:disable:next force_unwrapping
    )!

    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Persistent converter reused across calls; a buffer already in the target format passes through.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format.sampleRate == self.targetFormat.sampleRate,
           format.channelCount == self.targetFormat.channelCount,
           format.commonFormat == self.targetFormat.commonFormat
        {
            return buffer
        }
        if self.converter == nil || self.converterSourceFormat != format {
            self.converterSourceFormat = format
            self.converter = AVAudioConverter(from: format, to: self.targetFormat)
        }
        guard let converter = self.converter else { return nil }

        let ratio = self.targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return nil }

        let provided = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let wasProvided = provided.withLock { state -> Bool in
                if state { return true }
                state = true
                return false
            }
            if wasProvided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return output
    }

    /// The converted buffer's samples, for engines that stream plain Float arrays; empty when the
    /// buffer cannot be converted.
    func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converted = self.convert(buffer), let channel = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}
