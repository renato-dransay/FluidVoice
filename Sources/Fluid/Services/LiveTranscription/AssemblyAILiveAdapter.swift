import Foundation

/// Protocols §2. Configuration in the query with JSON-encoded lists; binary PCM of 50 ms to 1 s;
/// each Turn replaces its turn; a turn is final when it ended and is formatted.
nonisolated struct AssemblyAILiveAdapter: LiveTranscriptionAdapter {
    var provider: LiveTranscriptionProviderID { .assemblyAI }
    var waitsForReady: Bool { true }
    // AssemblyAI throttles at 1.25x real time.
    var maximumReplaySpeed: Double? { 1.2 }

    // EVIDENCE: https://www.assemblyai.com/docs/streaming/api-spec/streaming-websocket (checked 2026-10-01):
    // `language_codes` is "Universal-3.6 Pro and Universal-3.5 Pro Streaming only" and accepts these codes;
    // Universal-3.5 Pro takes the same set minus af, yue, et, gl, ko, mr, nn, fa, ro, ru, ur, xh and zu.
    static let steerableLanguageCodes: Set<String> = [
        "af", "ar", "yue", "ca", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "he", "hi", "it", "ja",
        "ko", "zh", "mr", "no", "nn", "fa", "pt", "ro", "ru", "es", "sv", "tr", "ur", "vi", "xh", "zu",
    ]
    static let previousProSteerableLanguageCodes = steerableLanguageCodes.subtracting([
        "af", "yue", "et", "gl", "ko", "mr", "nn", "fa", "ro", "ru", "ur", "xh", "zu",
    ])

    // EVIDENCE: https://www.assemblyai.com/docs/streaming/select-the-speech-model and the `speech_model` enum in
    // https://www.assemblyai.com/docs/api-reference/specs/streaming.yaml (checked 2026-10-02): the streaming models
    // are `universal-3-6-pro` (the default), `universal-3-5-pro` (the previous flagship, still supported),
    // `universal-streaming-multilingual` (en, es, de, fr, pt, it, switching per turn) and
    // `universal-streaming-english`. Only the two Universal-3 models take `language_codes`; only the two
    // Universal-Streaming models take `format_turns`; `language_detection` only adds the detected language to
    // each turn and is not sent to the English model.
    static let multilingualLanguageCodes: Set<String> = ["en", "es", "de", "fr", "pt", "it"]
    static let englishModelID = "universal-streaming-english"

    /// The languages a Universal-3 model can be steered toward; nil for a model that takes no list.
    static func steerableLanguageCodes(for modelID: String) -> Set<String>? { // swiftlint:disable:this discouraged_optional_collection
        switch modelID {
        case "universal-3-5-pro": self.previousProSteerableLanguageCodes
        case let id where id.hasPrefix("universal-3"): self.steerableLanguageCodes
        default: nil
        }
    }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        let languages = configuration.languageCode.map { [$0] } ?? configuration.languageHints
        var items = [
            URLQueryItem(name: "speech_model", value: configuration.modelID),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: "16000"),
        ]
        // JUDGMENT: steering toward part of the user's languages would bias against the rest, so a list with
        // any code the model does not take is left out whole and the model code-switches on its own.
        if let steerable = Self.steerableLanguageCodes(for: configuration.modelID), !languages.isEmpty, languages.allSatisfy(steerable.contains),
           let json = try? JSONSerialization.data(withJSONObject: languages), let list = String(bytes: json, encoding: .utf8) {
            items.append(URLQueryItem(name: "language_codes", value: list))
        }
        if configuration.languageCode == nil, configuration.modelID != Self.englishModelID {
            items.append(URLQueryItem(name: "language_detection", value: "true"))
        }
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
        // The docs name 1008 for a bad key, too many sessions and account issues such as an insufficient
        // balance; only the reason tells them apart.
        // EVIDENCE: https://www.assemblyai.com/docs/streaming/common-session-errors-and-closures (checked 2026-10-01)
        if closeCode == 1008 {
            if reason?.localizedCaseInsensitiveContains("concurrent") == true { return .rateLimited }
            return reason?.localizedCaseInsensitiveContains("balance") == true ? .quotaExhausted : .authentication
        }
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
