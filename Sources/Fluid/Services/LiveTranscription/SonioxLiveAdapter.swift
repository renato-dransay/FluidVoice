import Foundation

/// Protocols §1. The key goes in the first message; audio is binary PCM; final tokens are sent
/// once and never repeat, so each message's final tokens form one new segment.
nonisolated struct SonioxLiveAdapter: LiveTranscriptionAdapter {
    private var finalCount = 0
    private var lastFinal: LiveTranscriptSegment?

    var provider: LiveTranscriptionProviderID { .soniox }
    var trailingSilenceMilliseconds: Int { 200 }
    // Soniox asks for about real time and may drop bursts.
    var maximumReplaySpeed: Double? { 1.0 }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        try LiveHTTPStatus.request("wss://stt-rt.soniox.com/transcribe-websocket", headers: [:])
    }

    func openingMessages(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> [LiveTransportMessage] {
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": configuration.modelID,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_endpoint_detection": false,
        ]
        if let language = configuration.languageCode {
            config["language_hints"] = [language]
            config["language_hints_strict"] = true
        } else if !configuration.languageHints.isEmpty {
            config["language_hints"] = configuration.languageHints
        }
        return [try LiveJSON.text(config)]
    }

    func finishMessages() -> [LiveTransportMessage] {
        [.text(#"{"type":"finalize"}"#), .data(Data())]
    }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        if let type = object["error_type"] as? String { return [.failure(Self.failure(errorType: type))] }
        var finalText = ""
        var pendingText = ""
        var finalEnd: Int?
        for token in object["tokens"] as? [[String: Any]] ?? [] {
            guard let text = token["text"] as? String, text != "<fin>", text != "<end>" else { continue }
            if token["is_final"] as? Bool == true {
                finalText += text
                finalEnd = LiveJSON.int(token["end_ms"]) ?? finalEnd
            } else {
                pendingText += text
            }
        }
        var updates: [LiveTranscriptUpdate] = []
        if let first = finalText.first {
            // JUDGMENT: tokens are sub-words that carry their own spaces (Protocols §1: append final
            // token text as is). The assembler puts a space between segments that lack one, so a run
            // that continues the previous word extends that segment instead of starting a new one.
            let segment: LiveTranscriptSegment
            if let last = self.lastFinal, !first.isWhitespace {
                segment = .init(id: last.id, text: last.text + finalText, isFinal: true, audioEndMilliseconds: finalEnd ?? last.audioEndMilliseconds)
            } else {
                self.finalCount += 1
                segment = .init(id: "f\(self.finalCount)", text: finalText, isFinal: true, audioEndMilliseconds: finalEnd)
            }
            self.lastFinal = segment
            updates.append(.segment(segment))
        }
        updates.append(.pending(pendingText))
        if object["finished"] as? Bool == true { updates.append(.finished) }
        return updates
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://api.soniox.com/v1/models", headers: ["Authorization": "Bearer \(apiKey)"])
    }

    // EVIDENCE: https://soniox.com/docs/api-reference/errors (checked 2026-10-01): the two monthly budget caps
    // are HTTP 402 errors that surface on the STT WebSocket, next to an exhausted balance.
    private static func failure(errorType: String) -> LiveTranscriptionError {
        switch errorType {
        case "unauthenticated", "permission_denied": .authentication
        case "organization_balance_exhausted", "organization_monthly_budget_exhausted", "project_monthly_budget_exhausted": .quotaExhausted
        case "limit_exceeded": .rateLimited
        default: .sessionClosed(errorType)
        }
    }
}
