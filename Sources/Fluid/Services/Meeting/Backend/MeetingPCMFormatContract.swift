import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The format identity shared by capture writers and PCM sinks. Channel topology is validated
/// but intentionally excluded from identity: the sink canonicalizes planar input into interleaved
/// CAF, so an interleaved/planar transition with the same semantic layout is one capture epoch.
nonisolated struct MeetingPCMFormatContract: Equatable, Sendable {
    nonisolated enum SemanticLayout: Equatable, Sendable {
        case mono
        case stereo
        case explicit(Data)
    }

    let sampleRate: Double
    let channelCount: Int
    let layout: SemanticLayout

    var description: String {
        let layoutDescription: String
        switch self.layout {
        case .mono: layoutDescription = "mono"
        case .stereo: layoutDescription = "stereo"
        case let .explicit(bytes): layoutDescription = "explicit(\(bytes.count) bytes)"
        }
        return "lpcm-f32 rate=\(self.sampleRate) channels=\(self.channelCount) layout=\(layoutDescription)"
    }

    init(audioFormat: AVAudioFormat) throws {
        try self.init(asbd: audioFormat.streamDescription.pointee, layoutData: Self.layoutData(audioFormat.channelLayout))
    }

    init(formatDescription: CMFormatDescription) throws {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw MeetingPCMFormatContractError.unsupported("missing LPCM stream description")
        }
        try self.init(asbd: asbd, layoutData: Self.layoutData(formatDescription))
    }

    init(asbd: AudioStreamBasicDescription, layoutData: Data?) throws {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBitsPerChannel == 32,
              asbd.mFramesPerPacket == 1,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0
        else { throw MeetingPCMFormatContractError.unsupported("native Float32 LPCM required") }

        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if isNonInterleaved {
            guard asbd.mBytesPerFrame == 4, asbd.mBytesPerPacket == 4 else {
                throw MeetingPCMFormatContractError.unsupported("invalid planar Float32 byte layout")
            }
        } else {
            let expectedBytes = UInt64(asbd.mChannelsPerFrame) * 4
            guard UInt64(asbd.mBytesPerFrame) == expectedBytes,
                  UInt64(asbd.mBytesPerPacket) == expectedBytes
            else {
                throw MeetingPCMFormatContractError.unsupported("invalid interleaved Float32 byte layout")
            }
        }

        self.sampleRate = asbd.mSampleRate
        self.channelCount = Int(asbd.mChannelsPerFrame)
        self.layout = Self.semanticLayout(channelCount: self.channelCount, layoutData: layoutData)
    }

    private static func semanticLayout(channelCount: Int, layoutData: Data?) -> SemanticLayout {
        let tag = layoutData.flatMap { data -> UInt32? in
            guard data.count >= MemoryLayout<UInt32>.size else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        if channelCount == 1,
           tag == nil || tag == kAudioChannelLayoutTag_Mono ||
           tag == (kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        {
            return .mono
        }
        if channelCount == 2,
           tag == nil || tag == kAudioChannelLayoutTag_Stereo
        {
            return .stereo
        }
        if let layoutData { return .explicit(layoutData) }
        // CoreAudio can expose a built-in microphone array as layout-less multichannel LPCM.
        // Treat those channels as discrete-in-order so the capture description and the safe
        // AVAudioFormat fallback below share one stable contract.
        let discreteLayout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
        )
        return .explicit(Self.layoutData(discreteLayout) ?? Data())
    }

    static func layoutData(_ layout: AVAudioChannelLayout?) -> Data? {
        guard let layout else { return nil }
        let tag = layout.layout.pointee.mChannelLayoutTag
        let count = layout.layout.pointee.mNumberChannelDescriptions
        let headerSize = MemoryLayout<UInt32>.size * 3
        let size = tag != kAudioChannelLayoutTag_UseChannelDescriptions
            ? headerSize
            : headerSize + Int(count) * MemoryLayout<AudioChannelDescription>.stride
        return Data(bytes: layout.layout, count: size)
    }

    static func layoutData(_ desc: CMFormatDescription) -> Data? {
        var size = 0
        guard let ptr = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: &size), size > 0 else { return nil }
        return Data(bytes: ptr, count: size)
    }
}

/// Builds an AVAudioFormat without trusting the imported CM initializer's nonoptional type.
/// On macOS 27 it can return a null object for layout-less three-channel LPCM.
nonisolated enum MeetingPCMFormatResolver {
    static func resolve(_ description: CMFormatDescription) throws -> AVAudioFormat {
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              streamDescription.pointee.mChannelsPerFrame > 0
        else {
            throw MeetingPCMFormatContractError.unsupported("missing LPCM stream description")
        }

        let describedFormat: AVAudioFormat? = AVAudioFormat(cmAudioFormatDescription: description)
        if let describedFormat { return describedFormat }

        let channels = streamDescription.pointee.mChannelsPerFrame
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels
        ),
            let discreteFormat = AVAudioFormat(
                streamDescription: streamDescription,
                channelLayout: layout
            )
        else {
            throw MeetingPCMFormatContractError.unsupported(
                "cannot construct audio format for \(channels) layout-less channels"
            )
        }
        return discreteFormat
    }
}

nonisolated enum MeetingPCMFormatContractError: LocalizedError, Equatable, Sendable {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(reason): return "Unsupported PCM format: \(reason)."
        }
    }
}

/// Outcome of normalizing one capture buffer against `MeetingPCMFormatContract`.
nonisolated enum MeetingPCMFormatNormalizationOutcome {
    /// The buffer already satisfies the contract; forward the original untouched.
    case passthrough
    /// A converted native Float32 copy carrying the original presentation timestamp and frame count.
    case converted(CMSampleBuffer)
    /// No conversion is possible for this source format; the caller forwards the original as before.
    case unsupported(String)
}

/// Converts capture buffers that fail `MeetingPCMFormatContract` (for example Int16 Bluetooth HFP
/// microphones delivered through ScreenCaptureKit) into native Float32 LPCM at the same sample rate
/// and channel count. Buffers that already satisfy the contract pass through without copying.
/// One converter is cached per source format description.
nonisolated final class MeetingPCMFormatNormalizer: @unchecked Sendable {
    private enum Disposition {
        case passthrough
        case convert(AVAudioConverter, AVAudioFormat)
        case unsupported(String)
    }

    private let lock = NSLock()
    private let logSource: String
    private var cachedDescription: CMFormatDescription?
    private var cachedDisposition: Disposition = .passthrough
    private var conversionFailureLogged = false

    init(logSource: String) {
        self.logSource = logSource
    }

    /// Returns the buffer to forward: the converted copy when conversion applies, else the original.
    func normalized(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        if case let .converted(converted) = self.normalize(sampleBuffer) { return converted }
        return sampleBuffer
    }

    func normalize(_ sampleBuffer: CMSampleBuffer) -> MeetingPCMFormatNormalizationOutcome {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return .unsupported("missing LPCM stream description")
        }
        return self.lock.withLock {
            let disposition: Disposition
            if let cachedDescription = self.cachedDescription, CMFormatDescriptionEqual(cachedDescription, otherFormatDescription: description) {
                disposition = self.cachedDisposition
            } else {
                disposition = self.classify(description)
                self.cachedDescription = description
                self.cachedDisposition = disposition
                self.conversionFailureLogged = false
            }
            switch disposition {
            case .passthrough:
                return .passthrough
            case let .unsupported(reason):
                return .unsupported(reason)
            case let .convert(converter, outputFormat):
                do {
                    return try .converted(Self.convert(sampleBuffer, converter: converter, outputFormat: outputFormat))
                } catch {
                    if !self.conversionFailureLogged {
                        self.conversionFailureLogged = true
                        DebugLogger.shared.warning(
                            "Microphone capture buffer conversion failed; forwarding the source format unchanged: \(error.localizedDescription)",
                            source: self.logSource
                        )
                    }
                    return .unsupported(error.localizedDescription)
                }
            }
        }
    }

    private func classify(_ description: CMFormatDescription) -> Disposition {
        let summary = Self.describe(description)
        do {
            _ = try MeetingPCMFormatContract(formatDescription: description)
            DebugLogger.shared.info("Microphone capture format accepted natively: \(summary)", source: self.logSource)
            return .passthrough
        } catch {
            let reason = error.localizedDescription
            guard let sourceFormat = try? MeetingPCMFormatResolver.resolve(description),
                  let outputFormat = Self.makeOutputFormat(for: sourceFormat),
                  (try? MeetingPCMFormatContract(audioFormat: outputFormat)) != nil,
                  let converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
            else {
                DebugLogger.shared.warning(
                    "Microphone capture format cannot be converted to native Float32 (\(reason)); forwarding unchanged: \(summary)",
                    source: self.logSource
                )
                return .unsupported(reason)
            }
            DebugLogger.shared.info(
                "Microphone capture format converted to native Float32 (\(reason)): \(summary)",
                source: self.logSource
            )
            return .convert(converter, outputFormat)
        }
    }

    private static func makeOutputFormat(for sourceFormat: AVAudioFormat) -> AVAudioFormat? {
        if sourceFormat.channelCount > 2, let layout = sourceFormat.channelLayout {
            return AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channelLayout: layout)
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: true
        )
    }

    private static func convert(
        _ sampleBuffer: CMSampleBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> CMSampleBuffer {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw MeetingPCMFormatContractError.unsupported("cannot allocate conversion buffers") }
        input.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: input.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw MeetingPCMFormatContractError.unsupported("cannot read source PCM (\(copyStatus))")
        }

        try converter.convert(to: output, from: input)
        guard Int(output.frameLength) == frameCount else {
            throw MeetingPCMFormatContractError.unsupported("converter changed the frame count")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(outputFormat.sampleRate.rounded())),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )
        var created: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: outputFormat.formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &created
        )
        guard createStatus == noErr, let created else {
            throw MeetingPCMFormatContractError.unsupported("cannot create converted sample buffer (\(createStatus))")
        }
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            created,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: output.audioBufferList
        )
        guard dataStatus == noErr else {
            throw MeetingPCMFormatContractError.unsupported("cannot attach converted PCM (\(dataStatus))")
        }
        return created
    }

    /// Summarizes the stream description without any device or window identity.
    static func describe(_ description: CMFormatDescription) -> String {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return "no stream description"
        }
        let formatID = asbd.mFormatID.fourCharCodeString
        let flags = asbd.mFormatFlags
        var flagNames: [String] = []
        if flags & kAudioFormatFlagIsFloat != 0 { flagNames.append("float") }
        if flags & kAudioFormatFlagIsSignedInteger != 0 { flagNames.append("signedInt") }
        if flags & kAudioFormatFlagIsBigEndian != 0 { flagNames.append("bigEndian") }
        if flags & kAudioFormatFlagIsPacked != 0 { flagNames.append("packed") }
        if flags & kAudioFormatFlagIsNonInterleaved != 0 { flagNames.append("nonInterleaved") }
        if flags & kAudioFormatFlagIsAlignedHigh != 0 { flagNames.append("alignedHigh") }
        return "formatID=\(formatID) flags=0x\(String(flags, radix: 16))[\(flagNames.joined(separator: ","))] "
            + "bits=\(asbd.mBitsPerChannel) rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) "
            + "framesPerPacket=\(asbd.mFramesPerPacket) bytesPerFrame=\(asbd.mBytesPerFrame) bytesPerPacket=\(asbd.mBytesPerPacket)"
    }
}

private extension UInt32 {
    var fourCharCodeString: String {
        let bytes = [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(self) }
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
}
