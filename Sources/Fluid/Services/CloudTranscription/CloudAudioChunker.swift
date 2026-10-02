import Foundation

nonisolated struct CloudAudioChunk: Sendable {
    let start: Int
    let end: Int
    let ownedStart: Int
    let ownedEnd: Int
}

nonisolated enum CloudAudioChunker {
    static let sampleRate = 16_000
    /// OpenRouter's request size. Other clients pass their own `maximumRequestSeconds`.
    static let maximumSamples = 120 * sampleRate

    static func chunks(samples: [Float], wordTimings: Bool, maximumSamples: Int = maximumSamples) -> [CloudAudioChunk] {
        guard !samples.isEmpty else { return [] }
        let overlap = wordTimings ? self.sampleRate : 0
        var ranges: [(start: Int, end: Int)] = []
        var start = 0
        while start < samples.count {
            let limit = min(start + maximumSamples, samples.count)
            let end = limit == samples.count ? limit : self.silenceBoundary(samples: samples, limit: limit)
            ranges.append((start, end))
            if end == samples.count { break }
            start = end - overlap
        }
        return ranges.enumerated().map { index, range in
            // Midpoint ownership keeps each overlapped instant in exactly one chunk.
            let ownedStart = index == 0 ? 0 : range.start + overlap / 2
            let ownedEnd = index == ranges.count - 1 ? samples.count : range.end - overlap / 2
            return CloudAudioChunk(start: range.start, end: range.end, ownedStart: ownedStart, ownedEnd: ownedEnd)
        }
    }

    private static func silenceBoundary(samples: [Float], limit: Int) -> Int {
        let window = self.sampleRate / 5
        let searchStart = max(0, limit - 5 * self.sampleRate)
        // Only pick a genuinely quiet 200 ms window; loud windows retain the hard limit.
        for end in stride(from: limit, through: searchStart + window, by: -window) {
            var energy: Float = 0
            for sample in samples[(end - window) ..< end] { energy += sample * sample }
            if energy / Float(window) < 0.000_025 { return end - window / 2 }
        }
        return limit
    }
}

nonisolated enum CloudWAVEncoder {
    static func encode(samples: [Float]) throws -> Data {
        guard samples.count <= (25_000_000 - 44) / 2 else { throw CloudTranscriptionError.oversizedAudio }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            guard sample.isFinite else { throw CloudTranscriptionError.invalidAudio }
            let clipped = min(1, max(-1, sample))
            var value = Int16(clipped < 0 ? clipped * 32_768 : clipped * 32_767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        self.append(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVEfmt ".utf8))
        self.append(UInt32(16), to: &wav)
        self.append(UInt16(1), to: &wav)
        self.append(UInt16(1), to: &wav)
        self.append(UInt32(16_000), to: &wav)
        self.append(UInt32(32_000), to: &wav)
        self.append(UInt16(2), to: &wav)
        self.append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        self.append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
