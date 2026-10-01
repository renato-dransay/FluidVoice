import Foundation

/// Protocols §2. Configuration in the query with JSON-encoded lists; binary PCM of 50 ms to 1 s;
/// each Turn replaces its turn; a turn is final when it ended and is formatted.
nonisolated struct AssemblyAILiveAdapter: LiveTranscriptionAdapter {
    var provider: LiveTranscriptionProviderID { .assemblyAI }
    var waitsForReady: Bool { true }
    // AssemblyAI throttles at 1.25x real time.
    var maximumReplaySpeed: Double? { 1.2 }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        let languages = configuration.languageCode.map { [$0] } ?? configuration.languageHints
        var items = [
            URLQueryItem(name: "speech_model", value: configuration.modelID),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
        ]
        if !languages.isEmpty, let json = try? JSONSerialization.data(withJSONObject: languages), let list = String(bytes: json, encoding: .utf8) {
            items.append(URLQueryItem(name: "language_codes", value: list))
        }
        if configuration.languageCode == nil { items.append(URLQueryItem(name: "language_detection", value: "true")) }
        if configuration.modelID.hasPrefix("universal-streaming") { items.append(URLQueryItem(name: "format_turns", value: "true")) }
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")
        components?.queryItems = items
        guard let url = components?.url else { throw LiveTranscriptionError.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    func finishMessages() -> [LiveTransportMessage] {
        [.text(#"{"type":"ForceEndpoint"}"#), .text(#"{"type":"Terminate"}"#)]
    }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        switch object["type"] as? String {
        case "Begin":
            return [.ready]
        case "Turn":
            guard let order = LiveJSON.int(object["turn_order"]) else { return [] }
            let text = object["transcript"] as? String ?? ""
            let isFinal = object["end_of_turn"] as? Bool == true && object["turn_is_formatted"] as? Bool == true
            let end = (object["words"] as? [[String: Any]])?.last.flatMap { LiveJSON.int($0["end"]) }
            return [.segment(.init(id: "turn-\(order)", text: text, isFinal: isFinal, audioEndMilliseconds: end))]
        case "Termination":
            return [.finished]
        case "Error":
            return [.failure(Self.failure(code: LiveJSON.int(object["error_code"]) ?? 0))]
        default:
            return []
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://streaming.assemblyai.com/v3/token?expires_in_seconds=60", headers: ["Authorization": apiKey])
    }

    func failure(closeCode: Int, reason: String?) -> LiveTranscriptionError {
        // The docs name 1008 for both a bad key and too many sessions; only the reason tells them apart.
        if closeCode == 1008 { return reason?.localizedCaseInsensitiveContains("concurrent") == true ? .rateLimited : .authentication }
        return Self.failure(code: closeCode)
    }

    private static func failure(code: Int) -> LiveTranscriptionError {
        switch code {
        case 1008: .authentication
        case 3009: .rateLimited
        case 1001, 1005, 1006, 1011, 3005: .connectionLost
        default: .sessionClosed("\(code)")
        }
    }
}
