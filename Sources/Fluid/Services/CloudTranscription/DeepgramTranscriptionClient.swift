import Foundation

/// Deepgram pre-recorded transcription: one request carries the whole chunk and returns the transcript.
///
/// EVIDENCE: https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded (checked 2026-10-02):
/// `POST https://api.deepgram.com/v1/listen` with the raw audio as the body and the options as query
/// parameters, authenticated with `Authorization: Token <key>`. The transcript is
/// `results.channels[0].alternatives[0].transcript`; its `words[]` carry `word`, `punctuated_word`,
/// `start` and `end` in seconds. The `model` default is an old base model, so `model` is always sent.
/// EVIDENCE: https://developers.deepgram.com/docs/language-detection (checked 2026-10-02): `detect_language=true`
/// works for pre-recorded audio with Nova-3. Listing candidate languages there restricts detection to
/// them, which is stronger than a hint, so the Primary and Secondary languages are not sent.
/// EVIDENCE: https://developers.deepgram.com/docs/errors (checked 2026-10-02): 402 `ASR_PAYMENT_REQUIRED` when the
/// project has no credits, 429 `TOO_MANY_REQUESTS`.
/// EVIDENCE: https://developers.deepgram.com/docs/models-languages-overview (checked 2026-10-02): `nova-3` is the
/// current general model for pre-recorded audio.
/// EVIDENCE: https://developers.deepgram.com/docs/the-deepgram-model-improvement-partnership-program (checked
/// 2026-10-02): requests take part in the Model Improvement Program unless they send `mip_opt_out=true`. Listed
/// rates assume participation, and a Deepgram staff answer (https://github.com/orgs/deepgram/discussions/1292,
/// 2025-06-18) says opting out "forgoes a 50% discount", so the app does not opt out (owner's decision,
/// 2026-10-02). The Live adapter does the same.
nonisolated struct DeepgramTranscriptionClient: CloudTranscriptionClient {
    static let id = "deepgram"
    static let name = "Deepgram"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "nova-3", name: "Nova-3", wordTimingSupport: .supported, languageHintProviderTags: []),
    ]
    static let shared = DeepgramTranscriptionClient()

    private static let listenEndpoint = "https://api.deepgram.com/v1/listen"
    /// The key check the Deepgram live adapter uses: the project list needs a valid key and no audio.
    private static let keyCheckURL = "https://api.deepgram.com/v1/projects"

    private let http: CloudVendorHTTP

    init(session: URLSession? = nil) {
        self.http = CloudVendorHTTP(providerID: Self.id, session: session ?? CloudVendorHTTP.makeSession())
    }

    var providerID: String { Self.id }
    var providerName: String { Self.name }
    var maximumRequestSeconds: Int { CloudVendorHTTP.maximumRequestSeconds }

    func checkKey(apiKey: String) async throws {
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        guard let url = URL(string: Self.keyCheckURL) else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, headers: ["Authorization": "Token \(key)"]), endpoint: "projects")
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        let audio = try CloudEncodedAudio.best(samples: samples)
        guard let url = Self.listenURL(configuration: configuration) else { throw CloudTranscriptionError.network }
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: ["Authorization": "Token \(key)", "Content-Type": audio.mimeType],
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: samples.count)
        )
        request.httpBody = audio.data
        let started = ProcessInfo.processInfo.systemUptime
        let (data, _) = try await self.http.send(
            request, endpoint: "listen", modelID: configuration.modelID, audioBytes: audio.data.count, audioSamples: samples.count
        )
        let decoded = try CloudVendorHTTP.decode(Response.self, from: data)
        guard let alternative = decoded.results.channels.first?.alternatives.first else { throw CloudTranscriptionError.malformedResponse }
        let result = CloudTranscriptionResult(
            text: alternative.transcript,
            words: wordTimings ? alternative.words?.map {
                CloudTranscriptionWord(word: $0.punctuatedWord ?? $0.word, start: $0.start, end: $0.end)
            } : nil,
            usage: nil,
            requestID: decoded.metadata?.requestID,
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
        if wordTimings { try result.validateTimings(duration: CloudVendorHTTP.audioSeconds(samples.count)) }
        try Task.checkCancellation()
        return result
    }

    /// The model always; the chosen language, otherwise automatic detection; punctuation and
    /// formatting so the words read as written text. No Model Improvement Program opt-out, which would forfeit
    /// Deepgram's discount.
    static func listenURL(configuration: CloudTranscriptionConfiguration) -> URL? {
        var components = URLComponents(string: self.listenEndpoint)
        var items = [
            URLQueryItem(name: "model", value: configuration.modelID),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        if let language = configuration.languageCode {
            items.append(URLQueryItem(name: "language", value: language))
        } else {
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        components?.queryItems = items
        return components?.url
    }

    private struct Response: Decodable {
        struct Metadata: Decodable {
            let requestID: String?
            private enum CodingKeys: String, CodingKey { case requestID = "request_id" }
        }
        struct Results: Decodable { let channels: [Channel] }
        struct Channel: Decodable { let alternatives: [Alternative] }
        struct Alternative: Decodable {
            let transcript: String
            // Missing timings and a successful empty transcript have different meanings.
            // swiftlint:disable:next discouraged_optional_collection
            let words: [Word]?
        }
        struct Word: Decodable {
            let word: String
            let punctuatedWord: String?
            let start: TimeInterval
            let end: TimeInterval
            private enum CodingKeys: String, CodingKey {
                case word, start, end
                case punctuatedWord = "punctuated_word"
            }
        }
        let metadata: Metadata?
        let results: Results
    }
}
