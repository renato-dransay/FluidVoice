import Foundation

/// Protocols §8. Two steps: a REST session request with the key and the configuration returns a
/// WebSocket URL that carries its own token. Audio is binary PCM; finals arrive per utterance and
/// the post-processed full transcript replaces them before the session ends.
nonisolated struct GladiaLiveAdapter: LiveTranscriptionAdapter {
    private let session: URLSession
    private var finalCount = 0

    init(session: URLSession = .shared) {
        self.session = session
    }

    var provider: LiveTranscriptionProviderID { .gladia }

    /// Gladia's socket URL exists only after the session request; `prepareConnection` makes it.
    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        throw LiveTranscriptionError.connectionFailed
    }

    func sessionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        var body: [String: Any] = [
            "encoding": "wav/pcm",
            "bit_depth": 16,
            "sample_rate": 16_000,
            "channels": 1,
            "model": configuration.modelID,
            "messages_config": [
                "receive_partial_transcripts": true,
                "receive_final_transcripts": true,
                "receive_speech_events": false,
                "receive_pre_processing_events": false,
                "receive_realtime_processing_events": false,
                "receive_post_processing_events": true,
                "receive_acknowledgments": false,
                "receive_errors": true,
                "receive_lifecycle_events": true,
            ],
        ]
        if let language = configuration.languageCode {
            body["language_config"] = ["languages": [language], "code_switching": false] as [String: Any]
        } else if !configuration.languageHints.isEmpty {
            // EVIDENCE: Protocols §8.10, code-switching needs a language list; without hints Gladia detects alone.
            body["language_config"] = ["languages": configuration.languageHints, "code_switching": true] as [String: Any]
        }
        var request = try LiveHTTPStatus.request("https://api.gladia.io/v2/live", headers: ["x-gladia-key": apiKey, "Content-Type": "application/json"])
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    func prepareConnection(apiKey: String, configuration: LiveTranscriptionConfiguration) async throws -> URLRequest {
        let request = try self.sessionRequest(apiKey: apiKey, configuration: configuration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw LiveTranscriptionError.connectionFailed
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LiveTranscriptionError.connectionFailed }
        guard (200 ..< 300).contains(status) else {
            // A refused configuration (400, 422) fails the same way on retry; its body is server text and is not read.
            if status == 400 || status == 422 { throw LiveTranscriptionError.sessionClosed("http \(status)") }
            throw LiveHTTPStatus.failure(for: status)
        }
        // JUDGMENT: only a wss URL is opened, so a malformed answer never sends the stream elsewhere in clear text.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = (object["url"] as? String).flatMap(URL.init(string:)),
              url.scheme == "wss"
        else { throw LiveTranscriptionError.connectionFailed }
        var socketRequest = URLRequest(url: url)
        socketRequest.timeoutInterval = 15
        return socketRequest
    }

    func finishMessages() -> [LiveTransportMessage] { [.text(#"{"type":"stop_recording"}"#)] }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        if let error = object["error"] as? [String: Any] { return [.failure(Self.failure(error))] }
        let data = object["data"] as? [String: Any]
        switch object["type"] as? String {
        case "transcript":
            let utterance = data?["utterance"] as? [String: Any]
            let text = utterance?["text"] as? String ?? ""
            guard data?["is_final"] as? Bool == true else { return [.pending(text)] }
            guard !text.isEmpty else { return [.pending("")] }
            self.finalCount += 1
            let id = data?["id"] as? String ?? "f\(self.finalCount)"
            let end = (utterance?["end"] as? Double).map { Int(($0 * 1000).rounded()) }
            return [.segment(.init(id: id, text: text, isFinal: true, audioEndMilliseconds: end)), .pending("")]
        case "post_final_transcript":
            guard let full = (data?["transcription"] as? [String: Any])?["full_transcript"] as? String else { return [] }
            return [.replaceAll(full)]
        case "end_session":
            return [.finished]
        default:
            return []
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://api.gladia.io/v2/live?limit=1", headers: ["x-gladia-key": apiKey])
    }

    private static func failure(_ error: [String: Any]) -> LiveTranscriptionError {
        switch LiveJSON.int(error["status_code"]) {
        case 401, 402, 403, 429: LiveHTTPStatus.failure(for: LiveJSON.int(error["status_code"]) ?? 0)
        default: .sessionClosed(error["exception"] as? String ?? "error")
        }
    }
}
