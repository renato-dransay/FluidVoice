import CryptoKit
import Foundation

/// Serializes chunk/cache access inside one operation and never persists API credentials.
actor CloudTranscriptionEngine {
    private let client: any CloudTranscriptionClient
    private let cacheDirectory: URL?

    init(client: any CloudTranscriptionClient, cacheDirectory: URL?) {
        self.client = client
        self.cacheDirectory = cacheDirectory
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try configuration.validate(wordTimings: wordTimings)
        // A configuration only ever reaches its own provider's client, so a key never goes to another vendor.
        guard configuration.providerID == self.client.providerID else { throw CloudTranscriptionError.unsupportedModel }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudTranscriptionError.missingAPIKey }
        try Task.checkCancellation()
        if configuration.audioDictation != nil {
            // A single complete recording preserves style context and cannot resume partial AI output.
            return try await self.client.transcribe(samples: samples, configuration: configuration, apiKey: apiKey, wordTimings: wordTimings)
        }
        let maximumSamples = self.client.maximumRequestSeconds * CloudAudioChunker.sampleRate
        let chunks = CloudAudioChunker.chunks(samples: samples, wordTimings: wordTimings, maximumSamples: maximumSamples)
        let identity = try Self.audioIdentity(samples: samples, configuration: configuration, wordTimings: wordTimings, maximumSamples: maximumSamples)
        var texts: [String] = []
        var words: [CloudTranscriptionWord] = []
        var totalCost = 0.0
        var hasCompleteCost = true
        var totalProcessingDuration = 0.0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let cacheURL = self.cacheDirectory?.appendingPathComponent("\(identity)-\(index).json")
            let result: CloudTranscriptionResult
            if let cached = self.cachedResult(at: cacheURL, chunk: chunk, wordTimings: wordTimings) {
                result = cached
            } else {
                result = try await self.client.transcribe(
                    samples: Array(samples[chunk.start ..< chunk.end]), configuration: configuration, apiKey: apiKey, wordTimings: wordTimings
                )
                try Task.checkCancellation()
                try self.save(result, at: cacheURL)
            }
            if let cost = result.usage?.cost { totalCost += cost } else { hasCompleteCost = false }
            totalProcessingDuration += result.processingDuration
            if wordTimings {
                texts.append(result.text)
                let offset = Double(chunk.start) / 16_000
                let ownedStart = Double(chunk.ownedStart) / 16_000
                let ownedEnd = Double(chunk.ownedEnd) / 16_000
                words += (result.words ?? []).compactMap { word in
                    let midpoint = offset + (word.start + word.end) / 2
                    guard midpoint >= ownedStart, midpoint < ownedEnd else { return nil }
                    return CloudTranscriptionWord(word: word.word, start: offset + word.start, end: offset + word.end)
                }
            } else {
                texts.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try Task.checkCancellation()
        // Preserve provider formatting for a single timed request; only overlapping chunks need reassembly.
        let text = wordTimings && chunks.count > 1 ? Self.joinWords(words) : texts.filter { !$0.isEmpty }.joined(separator: " ")
        return CloudTranscriptionResult(
            text: text,
            words: wordTimings ? words : nil,
            usage: CloudTranscriptionUsage(seconds: Double(samples.count) / 16_000, cost: hasCompleteCost ? totalCost : nil),
            requestID: nil,
            processingDuration: totalProcessingDuration
        )
    }

    func clearCache() throws {
        if let cacheDirectory, FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private func cachedResult(at url: URL?, chunk: CloudAudioChunk, wordTimings: Bool) -> CloudTranscriptionResult? {
        guard let url, let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(CloudTranscriptionResult.self, from: data)
        else { return nil }
        if wordTimings {
            do { try result.validateTimings(duration: Double(chunk.end - chunk.start) / 16_000) } catch { return nil }
        }
        return result
    }

    private func save(_ result: CloudTranscriptionResult, at url: URL?) throws {
        guard let url else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(result)
        // Atomic creation with private permissions avoids a window exposing cached transcript text.
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        guard manager.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporaryURL) }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: url)
        }
    }

    /// The name of a recording's cached chunks. OpenRouter keeps the exact identity of earlier versions
    /// (configuration without a provider, no request size), so a meeting interrupted across an update
    /// resumes from its cached chunks instead of sending, and paying for, them again. Other providers add
    /// both, since their chunks differ in length.
    static func audioIdentity(samples: [Float], configuration: CloudTranscriptionConfiguration, wordTimings: Bool, maximumSamples: Int) throws -> String {
        var hash = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Version covers PCM format, chunking rules, and cache schema; bump if any changes.
        var version = "pcm-f32-16k-mono-chunks-v1-timed-\(wordTimings)"
        if configuration.providerID == CloudTranscriptionCatalog.openRouterID {
            hash.update(data: try encoder.encode(LegacyIdentity(configuration)))
        } else {
            hash.update(data: try encoder.encode(configuration))
            version += "-max-\(maximumSamples)"
        }
        hash.update(data: Data(version.utf8))
        samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The configuration as earlier versions encoded it, before it named its provider.
    private struct LegacyIdentity: Encodable {
        let modelID: String
        let languageCode: String?
        let audioDictation: CloudAudioDictationInstructions?
        let primaryLanguageCode: String?
        let secondaryLanguageCode: String?

        init(_ configuration: CloudTranscriptionConfiguration) {
            self.modelID = configuration.modelID
            self.languageCode = configuration.languageCode
            self.audioDictation = configuration.audioDictation
            self.primaryLanguageCode = configuration.primaryLanguageCode
            self.secondaryLanguageCode = configuration.secondaryLanguageCode
        }
    }

    private static func joinWords(_ words: [CloudTranscriptionWord]) -> String {
        var text = ""
        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let cjk = token.unicodeScalars.first.map(CloudTranscriptionWord.isWrittenWithoutSpaces) ?? false
            let previousCJK = text.unicodeScalars.last.map(CloudTranscriptionWord.isWrittenWithoutSpaces) ?? false
            let previousCJKPunctuation = text.last.map { "，。！？、；：「」『』（）".contains($0) } ?? false
            let punctuation = token.first.map { ",.!?;:，。！？、；：".contains($0) } ?? false
            if !text.isEmpty, !punctuation, !(cjk && (previousCJK || previousCJKPunctuation)) { text.append(" ") }
            text.append(token)
        }
        return text
    }
}
