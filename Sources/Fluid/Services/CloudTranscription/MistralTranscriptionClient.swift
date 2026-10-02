import Foundation

/// Mistral (Voxtral) transcription: one multipart request carries the whole chunk and returns the text.
///
/// EVIDENCE: https://docs.mistral.ai/api/endpoint/audio/transcriptions (checked 2026-10-02):
/// `POST https://api.mistral.ai/v1/audio/transcriptions`, `Authorization: Bearer <key>`, multipart fields
/// `file`, `model` (example `voxtral-mini-latest`) and optional `language`. The documented response has
/// `text`, `language` and `segments[]`; no word schema is documented.
/// EVIDENCE: https://docs.mistral.ai/studio/audio/speech_to_text/offline_transcription (checked 2026-10-02):
/// `timestamp_granularities` "is currently not compatible with `language`", so word timings would cost the
/// chosen language. With no documented word schema either, the catalog marks word timings unsupported.
/// EVIDENCE: https://docs.mistral.ai/resources/known-limitations (checked 2026-10-02): WAV, MP3, FLAC, OGG and
/// WEBM are accepted, up to 500 MB and 60 minutes, so FLAC with the WAV fallback is sent.
nonisolated struct MistralTranscriptionClient: CloudTranscriptionClient {
    static let id = "mistral"
    static let name = "Mistral"
    static let models: [CloudTranscriptionModel] = [
        .init(id: "voxtral-mini-latest", name: "Voxtral Mini", wordTimingSupport: .unsupported, languageHintProviderTags: []),
    ]
    static let shared = MistralTranscriptionClient()

    private static let transcriptionsEndpoint = "https://api.mistral.ai/v1/audio/transcriptions"
    /// The key check the Mistral live adapter uses.
    private static let keyCheckEndpoint = "https://api.mistral.ai/v1/models"

    private let http: CloudVendorHTTP

    init(session: URLSession? = nil) {
        self.http = CloudVendorHTTP(providerID: Self.id, session: session ?? CloudVendorHTTP.makeSession())
    }

    var providerID: String { Self.id }
    var providerName: String { Self.name }
    var maximumRequestSeconds: Int { CloudVendorHTTP.maximumRequestSeconds }

    func checkKey(apiKey: String) async throws {
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        guard let url = URL(string: Self.keyCheckEndpoint) else { throw CloudTranscriptionError.network }
        _ = try await self.http.send(CloudVendorHTTP.request(url, headers: ["Authorization": "Bearer \(key)"]), endpoint: "models")
    }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        try Task.checkCancellation()
        guard configuration.providerID == Self.id else { throw CloudTranscriptionError.unsupportedModel }
        try configuration.validate(wordTimings: wordTimings)
        let key = try CloudVendorHTTP.trimmedKey(apiKey)
        let audio = try CloudEncodedAudio.best(samples: samples)
        guard let url = URL(string: Self.transcriptionsEndpoint) else { throw CloudTranscriptionError.network }
        var form = CloudMultipartForm()
        form.append(field: "model", value: configuration.modelID)
        if let language = configuration.languageCode { form.append(field: "language", value: language) }
        form.append(audio: audio)
        var request = CloudVendorHTTP.request(
            url,
            method: "POST",
            headers: ["Authorization": "Bearer \(key)", "Content-Type": form.contentType],
            timeout: CloudVendorHTTP.singleRequestTimeout(audioSamples: samples.count)
        )
        request.httpBody = form.data
        let started = ProcessInfo.processInfo.systemUptime
        let (data, _) = try await self.http.send(
            request, endpoint: "audio/transcriptions", modelID: configuration.modelID, audioBytes: audio.data.count, audioSamples: samples.count
        )
        struct Response: Decodable { let text: String }
        let decoded = try CloudVendorHTTP.decode(Response.self, from: data)
        try Task.checkCancellation()
        return CloudTranscriptionResult(
            text: decoded.text,
            words: nil,
            usage: nil,
            requestID: nil,
            processingDuration: ProcessInfo.processInfo.systemUptime - started
        )
    }
}
