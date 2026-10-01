import Foundation

/// Protocols §7. One fixed language per session, set in `StartRecognition`; binary PCM frames that
/// the adapter counts, because `EndOfStream` must name the last one; each `AddTranscript` is final
/// and pre-formatted for concatenation.
nonisolated struct SpeechmaticsLiveAdapter: LiveTranscriptionAdapter {
    private var framesSent = 0
    private var finalCount = 0

    var provider: LiveTranscriptionProviderID { .speechmatics }
    var waitsForReady: Bool { true }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        try LiveHTTPStatus.request("wss://eu.rt.speechmatics.com/v2", headers: ["Authorization": "Bearer \(apiKey)"])
    }

    func openingMessages(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> [LiveTransportMessage] {
        // EVIDENCE: Protocols §7.10, realtime has no automatic detection. A language picked for this
        // recording wins; otherwise the Primary language, which the hints list first.
        guard let language = configuration.languageCode ?? configuration.languageHints.first else {
            throw LiveTranscriptionError.languageRequired
        }
        let start: [String: Any] = [
            "message": "StartRecognition",
            "audio_format": ["type": "raw", "encoding": "pcm_s16le", "sample_rate": 16_000],
            // EVIDENCE: Protocols §7.3 names the field `model` (`standard` or `enhanced`).
            "transcription_config": [
                "language": language,
                "model": configuration.modelID,
                "enable_partials": true,
                "max_delay": 0.7,
                "max_delay_mode": "flexible",
            ] as [String: Any],
        ]
        return [try LiveJSON.text(start)]
    }

    mutating func audioMessage(_ pcm16: Data) -> LiveTransportMessage {
        self.framesSent += 1
        return .data(pcm16)
    }

    func finishMessages() -> [LiveTransportMessage] {
        [.text(#"{"last_seq_no":\#(self.framesSent),"message":"EndOfStream"}"#)]
    }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        let metadata = object["metadata"] as? [String: Any]
        switch object["message"] as? String {
        case "RecognitionStarted":
            return [.ready]
        case "AddPartialTranscript":
            return [.pending(metadata?["transcript"] as? String ?? "")]
        case "AddTranscript":
            let text = metadata?["transcript"] as? String ?? ""
            guard !text.isEmpty else { return [.pending("")] }
            self.finalCount += 1
            let end = (metadata?["end_time"] as? Double).map { Int(($0 * 1000).rounded()) }
            return [.segment(.init(id: "f\(self.finalCount)", text: text, isFinal: true, audioEndMilliseconds: end)), .pending("")]
        case "EndOfTranscript":
            return [.finished]
        case "Error":
            return [.failure(Self.failure(type: object["type"] as? String ?? "error"))]
        default:
            return []
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://eu1.asr.api.speechmatics.com/v2/jobs?limit=1", headers: ["Authorization": "Bearer \(apiKey)"])
    }

    /// `URLSessionWebSocketTask` reports these codes as `.invalid`, so the error frame sent first is
    /// the usual source; the codes are mapped for a close that arrives without one.
    func failure(closeCode: Int, reason: String?) -> LiveTranscriptionError {
        switch closeCode {
        case 4001: .authentication
        case 4005: .rateLimited
        case 4006: .quotaExhausted
        case 1000, 1001, 1005, 1006, 1011: .connectionLost
        default: .sessionClosed("close \(closeCode)")
        }
    }

    // EVIDENCE: Protocols §7.7, `quota_exceeded` is the concurrency limit and `timelimit_exceeded` the
    // usage quota, so the first reads as rate limiting and only the second as an empty account.
    private static func failure(type: String) -> LiveTranscriptionError {
        switch type {
        case "not_authorised": .authentication
        case "timelimit_exceeded": .quotaExhausted
        case "quota_exceeded": .rateLimited
        // The adapter does not keep the configuration, and the error's reason is server text.
        case "invalid_language": .unsupportedLanguage("this language")
        default: .sessionClosed(type)
        }
    }
}
