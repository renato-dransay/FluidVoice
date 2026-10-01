import Foundation

/// One vendor's wire protocol: how to connect, what to send, and how to read what comes back.
/// Adapters hold no socket; `LiveTranscriptionSession` drives them through a transport.
nonisolated protocol LiveTranscriptionAdapter: Sendable {
    var provider: LiveTranscriptionProviderID { get }
    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest
    func openingMessages(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> [LiveTransportMessage]
    var waitsForReady: Bool { get }
    /// Mutating so adapters can keep per-connection audio state, such as a frame count or a resampler.
    mutating func audioMessage(_ pcm16: Data) -> LiveTransportMessage
    /// Mutating so adapters can note that the stream is finishing.
    mutating func finishMessages() -> [LiveTransportMessage]
    /// Silence appended before finishing, for providers that ask for it.
    var trailingSilenceMilliseconds: Int { get }
    /// Fastest replay the provider accepts, as a multiple of real time. Nil means no limit.
    var maximumReplaySpeed: Double? { get }
    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate]
    func keyCheckRequest(apiKey: String) throws -> URLRequest
    func failure(closeCode: Int, reason: String?) -> LiveTranscriptionError
}

nonisolated extension LiveTranscriptionAdapter {
    func openingMessages(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> [LiveTransportMessage] { [] }
    var waitsForReady: Bool { false }
    func audioMessage(_ pcm16: Data) -> LiveTransportMessage { .data(pcm16) }
    var trailingSilenceMilliseconds: Int { 0 }
    var maximumReplaySpeed: Double? { nil }
    /// Network-level closes read as a lost connection; any other code names itself.
    func failure(closeCode: Int, reason: String?) -> LiveTranscriptionError {
        [1000, 1001, 1005, 1006, 1011].contains(closeCode) ? .connectionLost : .sessionClosed("close \(closeCode)")
    }
}

nonisolated enum LiveTranscriptionAdapters {
    static func make(_ id: LiveTranscriptionProviderID) -> any LiveTranscriptionAdapter {
        switch id {
        case .soniox: SonioxLiveAdapter()
        case .deepgram: DeepgramLiveAdapter()
        case .assemblyAI: AssemblyAILiveAdapter()
        case .elevenLabs: ElevenLabsLiveAdapter()
        }
    }
}

nonisolated enum LivePCM16 {
    static let bytesPerMillisecond = 32

    /// 16 kHz mono float samples to signed 16-bit little-endian PCM, the format every provider accepts.
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clipped = sample.isFinite ? min(1, max(-1, sample)) : 0
                output[index] = Int16(clipped < 0 ? clipped * 32_768 : clipped * 32_767).littleEndian
            }
        }
        return data
    }
}

nonisolated enum LiveJSON {
    /// Nil when the message is binary or not a JSON object.
    static func object(_ message: LiveTransportMessage) -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        guard case .text(let text) = message else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func text(_ object: [String: Any]) throws -> LiveTransportMessage {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(bytes: data, encoding: .utf8) else { throw LiveTranscriptionError.connectionFailed }
        return .text(text)
    }

    static func int(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? Double).map { Int($0.rounded()) }
    }
}

nonisolated enum LiveHTTPStatus {
    static func failure(for status: Int) -> LiveTranscriptionError {
        switch status {
        case 401, 403: .authentication
        case 402: .quotaExhausted
        case 429: .rateLimited
        default: .connectionFailed
        }
    }

    static func request(_ string: String, headers: [String: String]) throws -> URLRequest {
        guard let url = URL(string: string) else { throw LiveTranscriptionError.connectionFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
