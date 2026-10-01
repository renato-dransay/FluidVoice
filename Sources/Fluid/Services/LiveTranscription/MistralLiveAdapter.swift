import Foundation

/// Protocols §5. The server greets with `session.created`; the audio format must be set with
/// `session.update` before any audio, and `session.updated` opens the stream. Audio is base64
/// JSON. Text arrives as append-only deltas, and `transcription.done` carries the full text.
nonisolated struct MistralLiveAdapter: LiveTranscriptionAdapter {
    private var streamedText = ""

    var provider: LiveTranscriptionProviderID { .mistral }
    var waitsForReady: Bool { true }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        // EVIDENCE: Protocols §5.3, the realtime session takes no language hints, so neither a chosen
        // language nor the hints are sent.
        var components = URLComponents(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")
        components?.queryItems = [URLQueryItem(name: "model", value: configuration.modelID)]
        guard let url = components?.url else { throw LiveTranscriptionError.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func audioMessage(_ pcm16: Data) -> LiveTransportMessage {
        // The session's largest chunk is 32,000 bytes, well under the 262,144-byte limit per message.
        .text(#"{"audio":""# + pcm16.base64EncodedString() + #"","type":"input_audio.append"}"#)
    }

    func finishMessages() -> [LiveTransportMessage] {
        [.text(#"{"type":"input_audio.flush"}"#), .text(#"{"type":"input_audio.end"}"#)]
    }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        switch object["type"] as? String {
        case "session.created":
            // The default audio format is undocumented, so it is always set.
            return [.reply([.text(#"{"session":{"audio_format":{"encoding":"pcm_s16le","sample_rate":16000},"target_streaming_delay_ms":480},"type":"session.update"}"#)])]
        case "session.updated":
            return [.ready]
        case "transcription.text.delta":
            self.streamedText += object["text"] as? String ?? ""
            // No timings: a reconnect replays this connection whole, which the assembler handles.
            return [.segment(.init(id: "stream", text: self.streamedText, isFinal: false, audioEndMilliseconds: nil))]
        case "transcription.done":
            return [.replaceAll(object["text"] as? String ?? self.streamedText), .finished]
        case "error":
            return [.failure(Self.failure(code: LiveJSON.int((object["error"] as? [String: Any])?["code"]) ?? 0))]
        default:
            return []
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://api.mistral.ai/v1/models", headers: ["Authorization": "Bearer \(apiKey)"])
    }

    // JUDGMENT: Protocols §5.7 calls the error code internal and documents no values. Codes that read as
    // HTTP statuses map like one; any other code names itself.
    private static func failure(code: Int) -> LiveTranscriptionError {
        switch code {
        case 401, 402, 403, 429: LiveHTTPStatus.failure(for: code)
        default: .sessionClosed("error \(code)")
        }
    }
}
