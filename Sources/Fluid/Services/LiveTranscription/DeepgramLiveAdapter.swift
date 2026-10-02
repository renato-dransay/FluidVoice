import Foundation

/// Protocols §3. Configuration in the query, binary PCM, finals cover consecutive ranges.
/// A zero-length binary frame closes the stream, so the finish message is CloseStream only.
nonisolated struct DeepgramLiveAdapter: LiveTranscriptionAdapter {
    private var finalCount = 0

    var provider: LiveTranscriptionProviderID { .deepgram }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")
        components?.queryItems = [
            URLQueryItem(name: "model", value: configuration.modelID),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            // Code-switching works best with short endpointing (Deepgram multilingual guide).
            URLQueryItem(name: "endpointing", value: "100"),
            URLQueryItem(name: "language", value: try Self.language(for: configuration)),
            // No `mip_opt_out`: opting out of Deepgram's Model Improvement Program forfeits its discount.
        ]
        guard let url = components?.url else { throw LiveTranscriptionError.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // EVIDENCE: https://developers.deepgram.com/docs/multilingual-code-switching and
    // https://developers.deepgram.com/docs/models-languages-overview (checked 2026-10-02): streaming takes
    // `language=multi` for code-switching; streaming has no `detect_language`. Nova-3's `multi` covers ten
    // languages, Nova-2's only Spanish and English, and Nova-3 Medical is documented for English only.
    static let englishOnlyModelIDs: Set<String> = ["nova-3-medical"]
    static let olderModelID = "nova-2"
    static let olderModelLanguageCodes: Set<String> = [
        "bg", "ca", "zh", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hi", "hu", "id", "it", "ja",
        "ko", "lv", "lt", "ms", "no", "pl", "pt", "ro", "ru", "sk", "es", "sv", "th", "tr", "uk", "vi",
    ]

    /// The chosen language, otherwise `multi` (Nova-3) or the Primary language (Nova-2, whose `multi` covers
    /// only Spanish and English). An English-only model takes English, and refuses another chosen language
    /// before connecting rather than transcribing it as English.
    static func language(for configuration: LiveTranscriptionConfiguration) throws -> String {
        if self.englishOnlyModelIDs.contains(configuration.modelID) {
            if let language = configuration.languageCode, language != "en" {
                throw LiveTranscriptionError.unsupportedLanguage(Locale(identifier: "en_US").localizedString(forLanguageCode: language) ?? language)
            }
            return "en"
        }
        if let language = configuration.languageCode { return language }
        if configuration.modelID == self.olderModelID, let primary = configuration.languageHints.first { return primary }
        return "multi"
    }

    func finishMessages() -> [LiveTransportMessage] { [.text(#"{"type":"CloseStream"}"#)] }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        switch object["type"] as? String {
        case "Results":
            let channel = object["channel"] as? [String: Any]
            let transcript = ((channel?["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String) ?? ""
            guard object["is_final"] as? Bool == true else { return [.pending(transcript)] }
            guard !transcript.isEmpty else { return [.pending("")] }
            self.finalCount += 1
            let start = object["start"] as? Double ?? 0
            let duration = object["duration"] as? Double ?? 0
            return [
                .segment(.init(id: "f\(self.finalCount)", text: transcript, isFinal: true, audioEndMilliseconds: Int(((start + duration) * 1000).rounded()))),
                .pending(""),
            ]
        case "Metadata":
            return [.finished]
        default:
            return []
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://api.deepgram.com/v1/projects", headers: ["Authorization": "Token \(apiKey)"])
    }
}
