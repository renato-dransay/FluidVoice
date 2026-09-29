import AVFoundation
import Foundation

/// Configuration and credentials are frozen when the provider is created for an operation.
final class CloudTranscriptionProvider: TranscriptionProvider {
    let configuration: CloudTranscriptionConfiguration
    private let apiKey: String
    private let client: OpenRouterTranscriptionClient
    private let engine: CloudTranscriptionEngine

    init(configuration: CloudTranscriptionConfiguration, apiKey: String, cacheDirectory: URL? = nil, persistChunks: Bool = true, client: OpenRouterTranscriptionClient = .init()) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.client = client
        let directory = cacheDirectory ?? ForkIdentity.applicationSupportURL()?.appendingPathComponent("CloudTranscription", isDirectory: true)
        self.engine = CloudTranscriptionEngine(client: client, cacheDirectory: persistChunks ? directory : nil)
    }

    var name: String { "OpenRouter" }
    var isAvailable: Bool { true }
    var isReady: Bool {
        !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? self.configuration.validate(wordTimings: false)) != nil
    }
    var supportsWordTimings: Bool {
        if self.configuration.audioDictation != nil { return false }
        return CloudTranscriptionModel.catalog.first(where: { $0.id == self.configuration.modelID })?.supportsWordTimings == true
    }
    var prefersNativeFileTranscription: Bool { true }
    var shouldClearCacheAfterCancellation: Bool { false }
    func modelsExistOnDisk() -> Bool { self.isReady }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        try self.configuration.validate(wordTimings: false)
        if let instructions = self.configuration.audioDictation {
            let available = try await self.client.validateAudioDictation(apiKey: self.apiKey)
            guard available.contains(where: { $0.id == instructions.modelID }) else { throw CloudTranscriptionError.unsupportedModel }
            return
        }
        let available = try await self.client.validate(apiKey: self.apiKey)
        guard available.contains(where: { $0.id == self.configuration.modelID }) else { throw CloudTranscriptionError.unsupportedModel }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let result = try await self.engine.transcribe(samples: samples, configuration: self.configuration, apiKey: self.apiKey, wordTimings: false)
        try Task.checkCancellation()
        return ASRTranscriptionResult(text: result.text, cloudDictationOutput: result.dictationOutput)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw CloudTranscriptionError.liveTranscriptionUnavailable
    }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let result = try await self.engine.transcribe(samples: samples, configuration: self.configuration, apiKey: self.apiKey, wordTimings: true)
        try Task.checkCancellation()
        return (ASRTranscriptionResult(text: result.text), (result.words ?? []).map { ASRWordTiming(text: $0.word, start: $0.start, end: $0.end) })
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        let samples = try await CloudAudioFileDecoder.readSamples(at: fileURL)
        return try await self.transcribe(samples)
    }

    func transcribeFileWithWordTimings(at fileURL: URL) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        try self.configuration.validate(wordTimings: true)
        let samples = try await CloudAudioFileDecoder.readSamples(at: fileURL)
        return try await self.transcribeWithWordTimings(samples)
    }

    func clearCache() async throws { try await self.engine.clearCache() }
}

nonisolated enum CloudAudioFileDecoder {
    /// AVAssetReader handles both imported audio and video without copying their original container into the upload.
    static func readSamples(at url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CloudTranscriptionError.invalidAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw CloudTranscriptionError.invalidAudio }
        reader.add(output)
        guard reader.startReading() else { throw CloudTranscriptionError.invalidAudio }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw CloudTranscriptionError.invalidAudio }
            let length = CMBlockBufferGetDataLength(block)
            guard length % MemoryLayout<Float>.size == 0 else { throw CloudTranscriptionError.invalidAudio }
            if length == 0 { continue }
            let count = length / MemoryLayout<Float>.size
            var decoded = [Float](repeating: 0, count: count)
            let status = decoded.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
            }
            guard status == kCMBlockBufferNoErr else { throw CloudTranscriptionError.invalidAudio }
            samples.append(contentsOf: decoded)
        }
        guard reader.status == .completed else { throw CloudTranscriptionError.invalidAudio }
        return samples
    }
}
